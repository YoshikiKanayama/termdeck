#!/bin/zsh
# termdeck のセットアップ（2026-08-03）
#
# やること:
#   1. 依存の確認（tmux / jq / fzf / claude）
#   2. ~/.zshrc に deck エイリアスを登録（マーカー付き。再実行しても重複しない）
#   3. Claude Code フックを ~/.claude/hooks へシンボリックリンク
#   4. ログイン時の自動復元（LaunchAgent）を登録
#
# オプション:
#   --no-launchd    ログイン時の自動復元を入れない
#   --with-tmux     ~/.tmux.conf から tmux/deck.conf を source する行を足す
#                   （既に mouse on 等を設定済みなら不要）
set -u

ROOT="${0:A:h}"
STATE="${DECK_STATE_DIR:-$HOME/.local/state/termdeck}"
DO_LAUNCHD=1
DO_TMUX=0
for a in "$@"; do
  case "$a" in
    --no-launchd) DO_LAUNCHD=0 ;;
    --with-tmux)  DO_TMUX=1 ;;
    *) print "不明なオプション: $a" >&2; exit 1 ;;
  esac
done

ng=0

print "── 依存の確認 ──"
for dep in tmux jq fzf; do
  if command -v "$dep" >/dev/null 2>&1; then
    print "  ✅ $dep"
  else
    print "  ✗ $dep がありません: brew install $dep"
    ng=1
  fi
done
if command -v claude >/dev/null 2>&1; then
  print "  ✅ claude"
else
  print "  ⚠️  claude がありません（無くても動くが、状態表示と履歴復元が効かない）"
  print "     導入: curl -fsSL https://claude.ai/install.sh | bash"
fi
(( ng )) && exit 1

mkdir -p "$STATE/terminals"

print "\n── エイリアス ──"
ZRC="$HOME/.zshrc"
MARK="# >>> termdeck >>>"
if grep -q "$MARK" "$ZRC" 2>/dev/null; then
  print "  = ~/.zshrc に登録済み。触らない"
else
  cat >> "$ZRC" <<EOF

$MARK
alias deck='zsh $ROOT/bin/deck'
# <<< termdeck <<<
EOF
  print "  ✅ ~/.zshrc に deck を追加"
fi

print "\n── Claude Code フック ──"
HOOK_DIR="$HOME/.claude/hooks"
mkdir -p "$HOOK_DIR"
if [[ -L "$HOOK_DIR/deck-claude-status.sh" ]]; then
  print "  = リンク済み。触らない"
else
  ln -sf "$ROOT/hooks/deck-claude-status.sh" "$HOOK_DIR/deck-claude-status.sh"
  print "  ✅ $HOOK_DIR/deck-claude-status.sh を張った"
fi
if grep -q "deck-claude-status" "$HOME/.claude/settings.json" 2>/dev/null; then
  print "  = settings.json に登録済み"
else
  print "  ⚠️  ~/.claude/settings.json への登録が必要です。hooks に以下のイベントを追加:"
  print '     SessionStart / UserPromptSubmit / Stop / SessionEnd / Notification に'
  print '     {"type":"command","command":"zsh ~/.claude/hooks/deck-claude-status.sh 2>/dev/null || true"}'
  print "     具体例は README の「フック登録」を参照"
fi

if (( DO_TMUX )); then
  print "\n── tmux 設定 ──"
  TCONF="$HOME/.tmux.conf"
  TMARK="# >>> termdeck >>>"
  if grep -q "$TMARK" "$TCONF" 2>/dev/null; then
    print "  = ~/.tmux.conf に登録済み。触らない"
  else
    cat >> "$TCONF" <<EOF

$TMARK
source-file $ROOT/tmux/deck.conf
# <<< termdeck <<<
EOF
    print "  ✅ ~/.tmux.conf から deck.conf を source"
  fi
fi

if (( DO_LAUNCHD )); then
  print "\n── ログイン時の自動復元（LaunchAgent）──"
  PLIST="$HOME/Library/LaunchAgents/com.termdeck.restore.plist"
  mkdir -p "${PLIST:h}"
  sed -e "s|__DECK_ROOT__|$ROOT|g" -e "s|__STATE__|$STATE|g" \
    "$ROOT/launchd/com.termdeck.restore.plist.tmpl" > "$PLIST"
  launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null
  if launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then
    print "  ✅ 登録した（次回ログインから有効。外す: install.sh --no-launchd 後に launchctl bootout）"
  else
    print "  ⚠️  launchctl への登録に失敗。手動で: launchctl bootstrap gui/\$(id -u) $PLIST"
  fi
fi

print "\n✅ セットアップ完了。新しいシェルで deck と打つと画面が開きます"
print "   （source ~/.zshrc でも可）"
