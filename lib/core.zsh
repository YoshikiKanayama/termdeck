# termdeck の本体ロジック（2026-08-03）
# bin/deck から source される。単体では実行しない。
#
# モデル:
#   tmux セッション "deck" の 4 ペイン = 左上:リスト / 右上:s1 / 右下:s2 / 左下:s3
#   非表示のターミナルは、デタッチ済みセッション "deck-stash" のウィンドウとして生き続ける
#   ターミナルの正体はただの zsh。中で claude を対話的に使う
#
# 状態（$DECK_STATE_DIR）:
#   terminals/<id>.json  各ターミナルの記録（pane_id / cwd / claude_session_id / 状態 ...）
#   slots.json           いま画面のどの位置にどのペインがいるか
#   mru                  最近開いた順（1行1ID）。再起動復元で上位3つを画面に戻す
#   layout               ユーザーがリサイズした配置（tmux の window_layout 文字列）

# ── 設定（環境変数で上書き可。テストは使い捨ての値を渡して本物と分離する）──
: ${DECK_STATE_DIR:="$HOME/.local/state/termdeck"}
: ${DECK_SRC:="$HOME/src"}
: ${DECK_SESSION:=deck}
: ${DECK_STASH:=deck-stash}
STATE="$DECK_STATE_DIR"

# tmux ラッパー。DECK_TMUX_SOCKET があれば専用サーバに向ける（テスト用）
t() {
  if [[ -n "${DECK_TMUX_SOCKET:-}" ]]; then
    command tmux -L "$DECK_TMUX_SOCKET" "$@"
  else
    command tmux "$@"
  fi
}

die() { print -r -- "deck: $*" >&2; exit 1 }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 が必要です（brew install $1）" }

state_init() { mkdir -p "$STATE/terminals" }
term_file() { print -r -- "$STATE/terminals/$1.json" }

# ─────────────────────────────────────────────────────────────
# ターミナル状態の読み書き
# ─────────────────────────────────────────────────────────────

term_field() {  # <id> <key>
  jq -r --arg k "$2" '.[$k] // ""' "$(term_file "$1")" 2>/dev/null
}

term_update() {  # <id> <key> <value> [<key> <value>...]  ※updated_at も更新する
  local f=$(term_file "$1") tmp prog i=1
  shift
  [[ -f "$f" ]] || return 1
  tmp="${f}.tmp.$$"
  prog='.updated_at=($now|tonumber)'
  local -a args=(--arg now "$(date +%s)")
  while (( $# >= 2 )); do
    prog+=" | .[\$k$i]=\$v$i"
    args+=(--arg "k$i" "$1" --arg "v$i" "$2")
    shift 2; ((i++))
  done
  jq "${args[@]}" "$prog" "$f" > "$tmp" 2>/dev/null && mv "$tmp" "$f"
}

term_create() {  # <id> <cwd> <pane_id>
  jq -n --arg id "$1" --arg cwd "$2" --arg pane "$3" \
        --arg repo "${2:t}" --arg now "$(date +%s)" '
    { term_id: $id, pane_id: $pane, cwd: $cwd, repo: $repo,
      claude_session_id: "", status: "shell", last_prompt: "", summary: "",
      resume: "true", updated_at: ($now|tonumber) }' > "$(term_file "$1")"
}

next_id() {
  local max=0 f n
  for f in "$STATE"/terminals/*.json(N); do
    n=${${f:t}%.json}
    [[ "$n" == <-> ]] && (( n > max )) && max=$n
  done
  print $(( max + 1 ))
}

all_ids() {  # 番号順
  local f
  local -a ids=()
  for f in "$STATE"/terminals/*.json(N); do ids+=("${${f:t}%.json}"); done
  (( ${#ids} )) && print -l -- ${(n)ids}
  return 0
}

# ─────────────────────────────────────────────────────────────
# スロット（画面位置 → ペインID）と MRU
# ─────────────────────────────────────────────────────────────

slot_get() { jq -r --arg k "$1" '.[$k] // ""' "$STATE/slots.json" 2>/dev/null }

slots_write() {  # <list> <s1> <s2> <s3>
  jq -n --arg l "$1" --arg a "$2" --arg b "$3" --arg c "$4" \
    '{list: $l, s1: $a, s2: $b, s3: $c}' > "$STATE/slots.json"
}

mru_touch() {
  local tmp="$STATE/mru.tmp.$$"
  { print -r -- "$1"; [[ -f "$STATE/mru" ]] && grep -vx -- "$1" "$STATE/mru" } > "$tmp" 2>/dev/null
  mv "$tmp" "$STATE/mru"
}

mru_remove() {
  [[ -f "$STATE/mru" ]] || return 0
  local tmp="$STATE/mru.tmp.$$"
  grep -vx -- "$1" "$STATE/mru" > "$tmp" 2>/dev/null
  mv "$tmp" "$STATE/mru"
}

mru_list() { [[ -f "$STATE/mru" ]] && cat "$STATE/mru"; return 0 }

# ─────────────────────────────────────────────────────────────
# ペイン・セッション
# ─────────────────────────────────────────────────────────────

pane_alive() { [[ -n "$1" && "$(t display -p -t "$1" '#{pane_id}' 2>/dev/null)" == "$1" ]] }
pane_term() { t display -p -t "$1" '#{@deck_term}' 2>/dev/null }

session_exists() { t has-session -t "=$1" 2>/dev/null }

# exit してもペインの枠を残す。pane-died フックがすぐ新しいシェル（または元のコマンド）を
# 入れ直すので、画面が崩れない。ターミナルを消す操作は deck kill（^K）に一本化する
keep_alive() { t set -w -t "$1" remain-on-exit on 2>/dev/null }

ensure_stash() {
  session_exists "$DECK_STASH" && return 0
  # 番兵ウィンドウ "keep" を残す。全ターミナルを画面に出してもセッションが消えないように
  t new-session -d -s "$DECK_STASH" -n keep -c "$DECK_SRC"
  keep_alive "=$DECK_STASH:keep"
  # set-hook は "=名前" の完全一致指定を受け付けない（素の名前で渡す）
  t set-hook -t "$DECK_STASH" pane-died "respawn-pane -k"
}

# 死んだターミナルを stash に立て直す。claude のセッションが記録されていれば履歴ごと復活させる
term_revive() {  # <id> → 新しい pane_id を stdout
  local id="$1" cwd=$(term_field "$1" cwd) sid=$(term_field "$1" claude_session_id) pane
  [[ -d "$cwd" ]] || cwd="$HOME"
  ensure_stash
  pane=$(t new-window -d -P -F '#{pane_id}' -t "=$DECK_STASH:" -c "$cwd" -n "${cwd:t}") || return 1
  t set -p -t "$pane" @deck_term "$id"
  keep_alive "$pane"
  if [[ "$(term_field "$id" resume)" == "true" && -n "$sid" ]]; then
    t send-keys -t "$pane" "claude --resume ${(q)sid}" C-m
    term_update "$id" pane_id "$pane" status waiting
  else
    term_update "$id" pane_id "$pane" status shell
  fi
  print -r -- "$pane"
}

# ─────────────────────────────────────────────────────────────
# レイアウトの保存・適用
# 玉突きで join/break してもユーザーがリサイズした寸法を保てるように、
# 4ペインが揃っている瞬間の window_layout を常に控えておき、操作後に再適用する
# ─────────────────────────────────────────────────────────────

layout_save() {
  [[ -f "$STATE/.rotating" ]] && return 0   # 玉突きの途中の崩れた形は保存しない
  session_exists "$DECK_SESSION" || return 0
  local n=$(t list-panes -t "=$DECK_SESSION:main" 2>/dev/null | wc -l | tr -d ' ')
  [[ "$n" == 4 ]] || return 0
  t display -p -t "=$DECK_SESSION:main" '#{window_layout}' > "$STATE/layout" 2>/dev/null
  return 0
}

layout_apply() {
  [[ -s "$STATE/layout" ]] || return 0
  t select-layout -t "=$DECK_SESSION:main" "$(cat "$STATE/layout")" 2>/dev/null
  return 0
}

# スロットのペインが消えていたら（kill-pane された等）、標準の4分割を組み直す。
# 生き残っている表示中ターミナルはいったん stash に退避する（リストから開き直せる）。
# 通常は remain-on-exit + pane-died フックがペインの死そのものを防ぐので、ここは保険
slots_heal() {
  local list=$(slot_get list) s1=$(slot_get s1) s2=$(slot_get s2) s3=$(slot_get s3)
  pane_alive "$list" || die "リストのペインが見つかりません。tmux kill-session -t $DECK_SESSION してから deck をやり直してください"
  pane_alive "$s1" && pane_alive "$s2" && pane_alive "$s3" && return 0

  touch "$STATE/.rotating"
  {
    local p
    for p in $(t list-panes -t "=$DECK_SESSION:main" -F '#{pane_id}'); do
      [[ "$p" == "$list" ]] && continue
      if [[ -n "$(pane_term "$p")" ]]; then
        ensure_stash
        t break-pane -d -s "$p" -t "=$DECK_STASH:"
        keep_alive "$p"
      else
        t kill-pane -t "$p"
      fi
    done
    s1=$(t split-window -d -P -F '#{pane_id}' -h -t "$list" -c "$DECK_SRC")
    s2=$(t split-window -d -P -F '#{pane_id}' -v -t "$s1" -c "$DECK_SRC")
    s3=$(t split-window -d -P -F '#{pane_id}' -v -t "$list" -c "$DECK_SRC")
    slots_write "$list" "$s1" "$s2" "$s3"
    layout_apply
    deck_retitle
  } always { rm -f "$STATE/.rotating" }
}

# ペインの見出しを更新する。番号はスロット番号（右上=1 / 右下=2 / 左下=3）。
# 番号は @deck_slot に持たせて枠線側で表示する。タイトル（リポジトリ名）は
# 中のプログラムが書き換えることがあるが、番号はそれに巻き込まれない
deck_retitle() {
  local -A num=(s1 1 s2 2 s3 3)
  local slot p id
  for slot in s1 s2 s3; do
    p=$(slot_get "$slot")
    pane_alive "$p" || continue
    t set -p -t "$p" @deck_slot "${num[$slot]}"
    id=$(pane_term "$p")
    if [[ -n "$id" ]]; then
      t select-pane -t "$p" -T "$(term_field "$id" repo)"
    else
      t select-pane -t "$p" -T "空き"
    fi
  done
}

# 一覧の再描画を促す（fzf の ctrl-r = reload を送る）
list_refresh() {
  local lp=$(slot_get list)
  [[ -n "$lp" ]] && t send-keys -t "$lp" C-r 2>/dev/null
  return 0
}

# ─────────────────────────────────────────────────────────────
# deck open — MRU 玉突き
# 選んだターミナルを右上(s1)へ。s1→s2、s2→s3、s3 は非表示(stash)へ
# ─────────────────────────────────────────────────────────────

cmd_open() {
  local id="${1:-}"
  [[ -n "$id" && -f "$(term_file "$id")" ]] || die "ターミナル ${id:-?} が見つかりません（一覧: deck status）"
  session_exists "$DECK_SESSION" || die "deck の画面がありません。先に deck を実行してください"

  local pane=$(term_field "$id" pane_id)
  if ! pane_alive "$pane" || [[ "$(pane_term "$pane")" != "$id" ]]; then
    pane=$(term_revive "$id") || die "ターミナル $id を再作成できませんでした"
  fi

  slots_heal
  local list=$(slot_get list) s1=$(slot_get s1) s2=$(slot_get s2) s3=$(slot_get s3)

  touch "$STATE/.rotating"
  {
    if [[ "$pane" == "$s1" ]]; then
      :  # 既に右上にいる
    elif [[ "$pane" == "$s2" ]]; then
      t swap-pane -d -s "$pane" -t "$s1"
      slots_write "$list" "$pane" "$s1" "$s3"
    elif [[ "$pane" == "$s3" ]]; then
      t swap-pane -d -s "$pane" -t "$s1"   # 選択 → 右上（旧s1 が左下位置へ）
      t swap-pane -d -s "$s1" -t "$s2"     # 旧s1 → 右下（旧s2 が左下位置へ）
      slots_write "$list" "$pane" "$s1" "$s2"
    else
      # 非表示 → リスト下に一時ペインとして繋ぎ、位置を玉突きしてから旧s3を退避する
      layout_save
      t join-pane -d -v -l 3 -s "$pane" -t "$list"
      t swap-pane -d -s "$pane" -t "$s1"   # 選択 → 右上（旧s1 が一時位置へ）
      t swap-pane -d -s "$s1" -t "$s2"     # 旧s1 → 右下（旧s2 が一時位置へ）
      t swap-pane -d -s "$s2" -t "$s3"     # 旧s2 → 左下（旧s3 が一時位置へ）
      if [[ -n "$(pane_term "$s3")" ]]; then
        ensure_stash
        t break-pane -d -s "$s3" -t "=$DECK_STASH:"   # 登録済みターミナルは stash へ帰す
        keep_alive "$s3"
      else
        t kill-pane -t "$s3"                          # 空きペインは使い捨て
      fi
      layout_apply
      slots_write "$list" "$pane" "$s1" "$s2"
    fi
  } always {
    rm -f "$STATE/.rotating"
  }

  mru_touch "$id"
  deck_retitle
  t select-pane -t "$pane"
  list_refresh
}

# ─────────────────────────────────────────────────────────────
# deck new — ターミナルを作る（stash に生まれ、画面があれば即表示）
# ─────────────────────────────────────────────────────────────

cmd_new() {
  local dir="" arg="${1:-}"
  if [[ -n "$arg" ]]; then
    if [[ -d "$arg" ]]; then dir="${arg:A}"
    elif [[ -d "$DECK_SRC/$arg" ]]; then dir="$DECK_SRC/$arg"
    else die "ディレクトリが見つかりません: $arg"
    fi
  else
    need fzf
    local -a cands=("$DECK_SRC"/*(N/:t))
    (( ${#cands} )) || die "$DECK_SRC 配下にディレクトリがありません"
    dir=$(print -l -- $cands | fzf --prompt='どのリポジトリで開く? > ' --height=60% --layout=reverse) || true
    [[ -z "$dir" ]] && { print "中止しました"; return 0 }
    dir="$DECK_SRC/$dir"
  fi

  state_init
  local id=$(next_id) pane
  ensure_stash
  pane=$(t new-window -d -P -F '#{pane_id}' -t "=$DECK_STASH:" -c "$dir" -n "${dir:t}") \
    || die "tmux ウィンドウを作れませんでした"
  t set -p -t "$pane" @deck_term "$id"
  keep_alive "$pane"
  term_create "$id" "$dir" "$pane"
  mru_touch "$id"

  if session_exists "$DECK_SESSION"; then
    cmd_open "$id"
  else
    print "ターミナル $id (${dir:t}) を作りました。deck で画面を開くと表示されます"
  fi
}

# ─────────────────────────────────────────────────────────────
# deck attach / restore — 画面の組み立てと復元
# ─────────────────────────────────────────────────────────────

deck_build() {
  local list s1 s2 s3
  # リストペインはシェルではなく deck-list そのものを走らせる。
  # こうすると pane-died フックの respawn-pane が「元のコマンド」= deck-list を
  # 再起動するので、リストが落ちても勝手に復活する
  local -a envopts=(-e "DECK_STATE_DIR=$STATE" -e "DECK_SRC=$DECK_SRC")
  [[ -n "${DECK_TMUX_SOCKET:-}" ]] && envopts+=(-e "DECK_TMUX_SOCKET=$DECK_TMUX_SOCKET")
  t new-session -d -s "$DECK_SESSION" -n main -c "$DECK_SRC" -x 220 -y 60 \
    "${envopts[@]}" "zsh '$DECK_ROOT/bin/deck-list'"
  list=$(t display -p -t "=$DECK_SESSION:main" '#{pane_id}')
  s1=$(t split-window -d -P -F '#{pane_id}' -h -t "$list" -c "$DECK_SRC")
  s2=$(t split-window -d -P -F '#{pane_id}' -v -t "$s1" -c "$DECK_SRC")
  s3=$(t split-window -d -P -F '#{pane_id}' -v -t "$list" -c "$DECK_SRC")
  slots_write "$list" "$s1" "$s2" "$s3"

  # exit ではペインを閉じさせない（枠が崩れないように）。消すのは deck kill だけ。
  # set-hook は "=名前" の完全一致指定を受け付けない（素の名前で渡す）
  keep_alive "=$DECK_SESSION:main"
  t set-hook -t "$DECK_SESSION" pane-died "respawn-pane -k"

  t resize-pane -t "$list" -x '30%'
  t select-pane -t "$list" -T "termdeck"
  # 枠線の番号はスロット番号を出す（右上=1 / 右下=2 / 左下=3）。
  # tmux の pane_index は位置と対応しないため、このウィンドウだけ表示を上書きする
  t set -w -t "=$DECK_SESSION:main" pane-border-status top
  t set -w -t "=$DECK_SESSION:main" pane-border-format \
    " #{?pane_active,#[fg=colour39],#[fg=colour245]}#{?@deck_slot,#{@deck_slot}: ,}#{pane_title} "
  layout_save

  # リサイズしたら常に配置を控える（マウスドラッグも window_layout の変化として拾える）
  local hookcmd="DECK_STATE_DIR='$STATE' zsh '$DECK_ROOT/bin/deck' save-layout"
  [[ -n "${DECK_TMUX_SOCKET:-}" ]] && hookcmd="DECK_TMUX_SOCKET='$DECK_TMUX_SOCKET' $hookcmd"
  t set-hook -t "=$DECK_SESSION" window-layout-changed "run-shell \"$hookcmd\"" 2>/dev/null

  deck_populate
  deck_retitle
  t select-pane -t "$list"
}

# 復元対象のターミナルを stash に立て直し、直近の3つを画面に配置する
deck_populate() {
  local id p
  for id in $(all_ids); do
    [[ "$(term_field "$id" resume)" == "true" ]] || continue
    p=$(term_field "$id" pane_id)
    pane_alive "$p" && [[ "$(pane_term "$p")" == "$id" ]] && continue
    term_revive "$id" >/dev/null || print -r -- "deck: ターミナル $id の復元に失敗" >&2
  done
  local -a top=($(mru_list | head -3))
  local i
  for (( i=${#top}; i >= 1; i-- )); do
    ( cmd_open "${top[$i]}" ) || true   # 3番目→1番目の順に開くと最新が右上に来る
  done
  layout_apply
}

cmd_attach() {
  state_init
  if session_exists "$DECK_SESSION"; then
    # 壊れた画面にそのまま入らない。接続前に直す
    local list=$(slot_get list)
    if pane_alive "$list"; then
      slots_heal
      deck_retitle
    else
      # リストごと失われている → 組み立て直す（ターミナルは state から復元される）
      t kill-session -t "=$DECK_SESSION" 2>/dev/null
      deck_build
    fi
  else
    deck_build
  fi

  # t はシェル関数なので exec できない。実コマンドの配列を組んで exec する
  local -a tcmd=(tmux)
  [[ -n "${DECK_TMUX_SOCKET:-}" ]] && tcmd+=(-L "$DECK_TMUX_SOCKET")
  if [[ -n "${TMUX:-}" ]]; then
    # tmux の中から呼ばれたら attach ではなく画面の切り替え（nested attach は失敗する）
    exec "${tcmd[@]}" switch-client -t "=$DECK_SESSION"
  elif [[ -t 0 ]]; then
    exec "${tcmd[@]}" attach -t "=$DECK_SESSION"
  else
    print "セッション $DECK_SESSION を用意しました（接続: deck）"
  fi
}

cmd_restore() {
  state_init
  if session_exists "$DECK_SESSION"; then
    print "deck は既に起動しています（接続: deck）"
    return 0
  fi
  deck_build
  print "復元しました（接続: deck）"
}

# ─────────────────────────────────────────────────────────────
# deck stop / keep / kill
# ─────────────────────────────────────────────────────────────

cmd_stop() {
  local id="${1:-}"
  [[ -n "$id" && -f "$(term_file "$id")" ]] || die "ターミナル ${id:-?} が見つかりません"
  term_update "$id" resume false
  print "ターミナル $id は再起動後に復元されません（戻す: deck keep $id）"
  list_refresh
}

cmd_keep() {
  local id="${1:-}"
  [[ -n "$id" && -f "$(term_file "$id")" ]] || die "ターミナル ${id:-?} が見つかりません"
  term_update "$id" resume true
  print "ターミナル $id は再起動後に復元されます"
  list_refresh
}

cmd_kill() {
  local yes=0 id
  [[ "${1:-}" == "-y" ]] && { yes=1; shift }
  id="${1:-}"
  [[ -n "$id" && -f "$(term_file "$id")" ]] || die "ターミナル ${id:-?} が見つかりません"

  if (( ! yes )); then
    printf "ターミナル %s (%s) を終了して記録も削除します。よろしいですか？ [y/N] > " \
      "$id" "$(term_field "$id" repo)"
    local a; read -r a
    [[ "$a" == [yY] ]] || { print "中止しました"; return 0 }
  fi

  local pane=$(term_field "$id" pane_id)
  if pane_alive "$pane" && [[ "$(pane_term "$pane")" == "$id" ]]; then
    local list=$(slot_get list) s1=$(slot_get s1) s2=$(slot_get s2) s3=$(slot_get s3)
    if [[ "$pane" == "$s1" || "$pane" == "$s2" || "$pane" == "$s3" ]]; then
      # 表示中なら空きペインと入れ替えてから消す（4分割の形を保つ）
      touch "$STATE/.rotating"
      {
        local ph=$(t split-window -d -P -F '#{pane_id}' -v -l 3 -t "$list" -c "$DECK_SRC")
        t swap-pane -d -s "$ph" -t "$pane"
        t kill-pane -t "$pane"
        case "$pane" in
          "$s1") slots_write "$list" "$ph" "$s2" "$s3" ;;
          "$s2") slots_write "$list" "$s1" "$ph" "$s3" ;;
          "$s3") slots_write "$list" "$s1" "$s2" "$ph" ;;
        esac
        layout_apply
      } always { rm -f "$STATE/.rotating" }
    else
      t kill-pane -t "$pane"
    fi
  fi

  rm -f "$(term_file "$id")"
  mru_remove "$id"
  deck_retitle
  list_refresh
  print "ターミナル $id を削除しました"
}

# ─────────────────────────────────────────────────────────────
# deck status / ls — 表示系
# ─────────────────────────────────────────────────────────────

status_label() {
  case "$1" in
    working)     print "🟢 作業中" ;;
    needs_input) print "🔴 要入力" ;;
    waiting)     print "🟡 入力待ち" ;;
    shell)       print "⚪ シェル" ;;
    ended)       print "⚫ 終了" ;;
    *)           print "・ $1" ;;
  esac
}

term_detail() {  # fzf のプレビューに出す詳細
  local id="$1" f=$(term_file "$1")
  [[ -f "$f" ]] || { print "（記録なし）"; return 0 }
  local pane=$(term_field "$id" pane_id) live="いいえ（開くと復活）"
  pane_alive "$pane" && [[ "$(pane_term "$pane")" == "$id" ]] && live="はい"
  print -r -- "■ $(term_field "$id" repo)   $(status_label "$(term_field "$id" status)")"
  print -r -- "  場所      $(term_field "$id" cwd)"
  print -r -- "  生存      $live"
  print -r -- "  再起動後  $([[ $(term_field "$id" resume) == true ]] && print 復元する || print 復元しない)"
  print ""
  print -r -- "▼ 頼んだこと"
  print -r -- "  ${$(term_field "$id" last_prompt):-（まだない）}"
  print ""
  print -r -- "▼ 結果サマリ（最後の応答の冒頭）"
  print -r -- "  ${$(term_field "$id" summary):-（まだない）}"
}

cmd_status() {
  case "${1:-}" in
    --term)        term_detail "${2:-}"; return 0 ;;
    --resume-flag) term_field "${2:-}" resume; return 0 ;;
  esac
  local id
  for id in $(all_ids); do
    printf "%3s  %-14s %-24s %s\n" "$id" "$(status_label "$(term_field "$id" status)")" \
      "$(term_field "$id" repo)" "$(term_field "$id" last_prompt | cut -c1-60)"
  done
}

# fzf に食わせる行: "<id>\t<表示>"。MRU 順 → 残りは番号順
cmd_ls() {
  local s1=$(slot_get s1) s2=$(slot_get s2) s3=$(slot_get s3)
  local -a order=($(mru_list))
  local id seen p mark icon prompt
  for id in $(all_ids); do
    (( ${order[(Ie)$id]} )) || order+=("$id")
  done
  for id in $order; do
    [[ -f "$(term_file "$id")" ]] || continue
    p=$(term_field "$id" pane_id)
    case "$p" in
      "$s1") mark="▶1" ;;
      "$s2") mark=" 2" ;;
      "$s3") mark=" 3" ;;
      *) if pane_alive "$p" && [[ "$(pane_term "$p")" == "$id" ]]; then mark="  "; else mark=" ×"; fi ;;
    esac
    icon=$(status_label "$(term_field "$id" status)")
    prompt=$(term_field "$id" last_prompt | tr -d '\000-\037' | cut -c1-80)
    printf "%s\t%s %s  \033[1m%s\033[0m  \033[2m%s\033[0m\n" \
      "$id" "$mark" "$icon" "$(term_field "$id" repo)" "$prompt"
  done
}

usage() {
  cat <<'EOF'
deck — 独立したターミナルを1つの tmux 画面に集める

  deck              画面を開く（無ければ組み立て、再起動後は自動復元してから接続）
  deck new [repo]   新しいターミナルを作る（引数なしなら一覧から選ぶ）
  deck open <番号>  そのターミナルを右上に出す（右上→右下→左下→非表示の玉突き）
  deck stop <番号>  再起動後の復元対象から外す
  deck keep <番号>  復元対象に戻す
  deck kill <番号>  ターミナルを終了して記録も消す（確認あり）
  deck status       一覧を表示
  deck restore      画面を組み立てるだけ（接続しない。ログイン時の自動実行用）
EOF
}
