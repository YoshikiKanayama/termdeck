#!/bin/zsh
# MRU 玉突き（deck open）と kill の自動テスト（2026-08-03）
#
# 使い捨ての tmux サーバ（-L）と状態ディレクトリで実行するため、
# 本物の deck / deck-stash セッションや ~/.local/state には一切触れない。
set -u

ROOT="${0:A:h:h}"
DECK="$ROOT/bin/deck"

export DECK_TMUX_SOCKET="decktest$$"
export DECK_STATE_DIR="$(mktemp -d)"
export DECK_SRC="$(mktemp -d)"
export TMUX_TMPDIR="${TMPDIR:-/tmp}"

pass=0 fail=0
ok() { print "  ✅ $1"; ((pass++)) }
ng() { print "  ✗ $1"; ((fail++)) }
assert_eq() {  # <説明> <実際> <期待>
  if [[ "$2" == "$3" ]]; then ok "$1"; else ng "$1（actual='$2' expected='$3'）"; fi
}

cleanup() {
  tmux -L "$DECK_TMUX_SOCKET" kill-server 2>/dev/null
  rm -rf "$DECK_STATE_DIR" "$DECK_SRC"
}
trap cleanup EXIT INT TERM

tt() { tmux -L "$DECK_TMUX_SOCKET" "$@" }
slot() { jq -r --arg k "$1" '.[$k]' "$DECK_STATE_DIR/slots.json" }
tpane() { jq -r '.pane_id' "$DECK_STATE_DIR/terminals/$1.json" }
pane_count() { tt list-panes -t deck:main 2>/dev/null | wc -l | tr -d ' ' }
in_main() { tt list-panes -t deck:main -F '#{pane_id}' 2>/dev/null | grep -cx -- "$1" }

# 疑似リポジトリ
for r in alpha bravo charlie delta; do mkdir -p "$DECK_SRC/$r"; done

print "── 画面構築（restore = 接続なしで組み立て）──"
zsh "$DECK" restore >/dev/null
assert_eq "ペインが4枚できる" "$(pane_count)" "4"

print "── deck new ×3（空きペインを順に置き換える）──"
zsh "$DECK" new alpha >/dev/null
zsh "$DECK" new bravo >/dev/null
zsh "$DECK" new charlie >/dev/null
assert_eq "s1 = charlie（最後に作ったもの）" "$(slot s1)" "$(tpane 3)"
assert_eq "s2 = bravo" "$(slot s2)" "$(tpane 2)"
assert_eq "s3 = alpha" "$(slot s3)" "$(tpane 1)"
assert_eq "ペインは4枚のまま" "$(pane_count)" "4"

print "── 4本目で一番古いものが非表示になる ──"
zsh "$DECK" new delta >/dev/null
assert_eq "s1 = delta" "$(slot s1)" "$(tpane 4)"
assert_eq "s2 = charlie" "$(slot s2)" "$(tpane 3)"
assert_eq "s3 = bravo" "$(slot s3)" "$(tpane 2)"
assert_eq "ペインは4枚のまま" "$(pane_count)" "4"
assert_eq "右上の枠番号は 1" "$(tt display -p -t "$(slot s1)" '#{@deck_slot}')" "1"
assert_eq "右下の枠番号は 2" "$(tt display -p -t "$(slot s2)" '#{@deck_slot}')" "2"
assert_eq "左下の枠番号は 3" "$(tt display -p -t "$(slot s3)" '#{@deck_slot}')" "3"
alpha_pane=$(tpane 1)
assert_eq "alpha は画面から消える" "$(in_main "$alpha_pane")" "0"
assert_eq "alpha は stash で生きている" \
  "$(tt display -p -t "$alpha_pane" '#{pane_id}' 2>/dev/null)" "$alpha_pane"

print "── 表示中（左下 s3）を選ぶと右上へ ──"
zsh "$DECK" open 2 >/dev/null   # bravo は s3 にいる
assert_eq "s1 = bravo" "$(slot s1)" "$(tpane 2)"
assert_eq "s2 = delta" "$(slot s2)" "$(tpane 4)"
assert_eq "s3 = charlie" "$(slot s3)" "$(tpane 3)"

print "── 非表示を選ぶと玉突きで戻る ──"
zsh "$DECK" open 1 >/dev/null   # alpha は stash にいる
assert_eq "s1 = alpha" "$(slot s1)" "$(tpane 1)"
assert_eq "s2 = bravo" "$(slot s2)" "$(tpane 2)"
assert_eq "s3 = delta" "$(slot s3)" "$(tpane 4)"
assert_eq "ペインは4枚のまま" "$(pane_count)" "4"
assert_eq "charlie が非表示になる" "$(in_main "$(tpane 3)")" "0"

print "── リサイズした配置が玉突き後も保たれる ──"
tt resize-pane -t "$(slot s1)" -x 91
zsh "$DECK" save-layout
w_before=$(tt display -p -t "$(slot s1)" '#{pane_width}')
zsh "$DECK" open 3 >/dev/null   # 非表示の charlie → join/break の経路
w_after=$(tt display -p -t "$(slot s1)" '#{pane_width}')
assert_eq "右上の幅が維持される" "$w_after" "$w_before"
assert_eq "ペインは4枚のまま" "$(pane_count)" "4"

print "── 既に右上のものを選んでも壊れない ──"
zsh "$DECK" open 3 >/dev/null
assert_eq "s1 = charlie のまま" "$(slot s1)" "$(tpane 3)"
assert_eq "ペインは4枚のまま" "$(pane_count)" "4"

print "── 表示中のターミナルを kill しても4分割が保たれる ──"
zsh "$DECK" kill -y 3 >/dev/null
assert_eq "ペインは4枚のまま" "$(pane_count)" "4"
assert_eq "記録が消えている" "$([[ -f "$DECK_STATE_DIR/terminals/3.json" ]] && print ある || print ない)" "ない"

print "── MRU 順が記録されている ──"
assert_eq "mru の先頭は alpha(1)" "$(head -1 "$DECK_STATE_DIR/mru")" "1"

print "── exit してもペインが残って新しいシェルが入る ──"
s1p=$(slot s1)
tt send-keys -t "$s1p" " exit" C-m
sleep 1.5
assert_eq "exit したペインが生きている" "$(tt display -p -t "$s1p" '#{pane_id}' 2>/dev/null)" "$s1p"
assert_eq "死んだままではなく新しいシェルが入っている" "$(tt display -p -t "$s1p" '#{pane_dead}')" "0"
assert_eq "ペインは4枚のまま" "$(pane_count)" "4"

print "── kill-pane で壊れても開き直しで組み直る ──"
tt kill-pane -t "$(slot s2)"
zsh "$DECK" open 1 >/dev/null
assert_eq "ペインが4枚に戻る" "$(pane_count)" "4"
assert_eq "s1 = alpha（復活して右上）" "$(slot s1)" "$(tpane 1)"
assert_eq "枠番号 1/2/3 が揃っている" \
  "$(tt display -p -t "$(slot s1)" '#{@deck_slot}')$(tt display -p -t "$(slot s2)" '#{@deck_slot}')$(tt display -p -t "$(slot s3)" '#{@deck_slot}')" "123"

print "── 状態は「フックの記録」より「ペインの表示」を優先する ──"
# フックはイベントの瞬間しか書けないので、承認に答えて作業が再開した、のような
# 遷移を取りこぼして needs_input が貼り付く。画面を読んでそれを打ち消せること
set_status() {  # <id> <status>
  local f="$DECK_STATE_DIR/terminals/$1.json"
  jq --arg s "$2" '.status=$s' "$f" > "$f.t" && mv "$f.t" "$f"
}
state_of() { zsh "$DECK" status 2>/dev/null | awk -v id="$1" '$1==id {print $3}' }
show() {  # <pane> <画面に出す行>...  ※clear で前の行を残さない
  # ペインの中で動くのは tmux の default-shell（CI では bash や sh のこともある）。
  # zsh 専用の print ではなく printf を使う
  local pane="$1" cmd="clear" l
  shift
  for l in "$@"; do cmd+=" && printf '%s\\n' ${(q)l}"; done
  tt send-keys -t "$pane" "$cmd" C-m
  sleep 1
}
p1=$(tpane 1)
set_status 1 needs_input
assert_eq "画面から読めなければフックの記録どおり" "$(state_of 1)" "要入力"
show "$p1" '⏵⏵ auto mode on (shift+tab to cycle) · esc to interrupt · ← 1 agent'
assert_eq "実行中の画面なら作業中（記録は needs_input のまま）" "$(state_of 1)" "作業中"
show "$p1" '⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent'
assert_eq "プロンプトだけなら入力待ち（貼り付いた needs_input を打ち消す）" "$(state_of 1)" "入力待ち"
show "$p1" '⏸ manual mode on · ? for shortcuts · ← 1 agent'
assert_eq "モード行の案内が変わっても入力待ち" "$(state_of 1)" "入力待ち"

print "── 止まっている理由を「承認待ち」と「質問」に分ける ──"
# 実物の文言（2.1.220 で採取）をそのまま画面に出して判定させる
show "$p1" 'Enter to select · Tab/Arrow keys to navigate · Esc to cancel'
assert_eq "AskUserQuestion のフッターなら質問" "$(state_of 1)" "質問"
show "$p1" '  4. Type something.'
assert_eq "「Type something.」があれば質問" "$(state_of 1)" "質問"
show "$p1" ' Do you want to create memo.txt?' ' ❯ 1. Yes' '   3. No' ' Esc to cancel · Tab to amend'
assert_eq "ツール承認なら承認待ち" "$(state_of 1)" "承認待ち"
show "$p1" ' Claude has written up a plan and is ready to execute. Would you like to proceed?' \
           ' ❯ 1. Yes, and use auto mode' '     shift+tab to approve with this feedback'
assert_eq "プラン確認なら承認待ち" "$(state_of 1)" "承認待ち"

# ctrl+t のタスク一覧はダイアログのフッターより下に描かれる（実機で確認済み）
show "$p1" '  5. Chat about this' 'Enter to select · ↑/↓ to navigate · Esc to cancel' \
           '  6 tasks (5 done, 1 in progress, 0 open)' '  ◼ PR1 の品質チェックを通してPRを作成' \
           '  ✔ featureブランチとステアリング文書を作成' '  ✔ 純関数を実装' \
           '  ✔ ルートを新設' '  ✔ パス分類とクエリ保持を修正' '   … +1 completed'
assert_eq "タスク一覧が下に出ていても質問と分かる" "$(state_of 1)" "質問"

# 本文に承認っぽい文字列があっても、モード行が見えていれば止まっていない
show "$p1" '  Do you want to proceed? と聞かれたら Yes を押してください' \
           '⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent'
assert_eq "本文の文言に釣られない（モード行が優先）" "$(state_of 1)" "入力待ち"

print "── copy-mode 中のペインには ^R を送らない ──"
# 送ると tmux が ^R を横取りして検索プロンプト（画面下の黄色い帯 "(search up)"）を開く
idle_check() {  # <pane> → yes/no
  ( DECK_ROOT="$ROOT" source "$ROOT/lib/core.zsh"; pane_idle "$1" && print yes || print no )
}
listp=$(slot list)
assert_eq "素のペインには送ってよい" "$(idle_check "$listp")" "yes"
tt copy-mode -t "$listp"
assert_eq "copy-mode 中は送らない" "$(idle_check "$listp")" "no"
tt send-keys -X -t "$listp" cancel
assert_eq "抜ければまた送る" "$(idle_check "$listp")" "yes"

print ""
print "結果: ✅ $pass / ✗ $fail"
(( fail == 0 ))
