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

print ""
print "結果: ✅ $pass / ✗ $fail"
(( fail == 0 ))
