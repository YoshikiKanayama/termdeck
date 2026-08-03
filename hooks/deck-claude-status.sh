#!/bin/zsh
# Claude Code フック → termdeck の状態ファイル更新（2026-08-03）
#
# 対象イベント: SessionStart / UserPromptSubmit / Stop / SessionEnd / Notification
# termdeck 管理下のペイン（@deck_term 付き）で動く claude だけが対象。
# それ以外（claude --bg、tmux 外の端末など）では何もせず 0 で抜ける。
# フックはどんな失敗でも claude の動作を妨げないこと（常に exit 0）。
set -u

input=$(cat)
[[ -n "${TMUX_PANE:-}" ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v tmux >/dev/null 2>&1 || exit 0

STATE="${DECK_STATE_DIR:-$HOME/.local/state/termdeck}"
tid=$(tmux display -p -t "$TMUX_PANE" '#{@deck_term}' 2>/dev/null)
[[ -n "$tid" ]] || exit 0
f="$STATE/terminals/$tid.json"
[[ -f "$f" ]] || exit 0

event=$(print -r -- "$input" | jq -r '.hook_event_name // ""')

upd() {  # <key> <value> [<key> <value>...]
  local tmp="$f.tmp.$$" prog='.updated_at=($now|tonumber)' i=1
  local -a args=(--arg now "$(date +%s)")
  while (( $# >= 2 )); do
    prog+=" | .[\$k$i]=\$v$i"
    args+=(--arg "k$i" "$1" --arg "v$i" "$2")
    shift 2; ((i++))
  done
  jq "${args[@]}" "$prog" "$f" > "$tmp" 2>/dev/null && mv "$tmp" "$f"
}

oneline() { tr '\n\t' '  ' | tr -d '\000-\010\013-\037' | cut -c1-200 | sed 's/[[:space:]]*$//' }

case "$event" in
  SessionStart)
    sid=$(print -r -- "$input" | jq -r '.session_id // ""')
    [[ -n "$sid" ]] && upd claude_session_id "$sid" status waiting
    ;;
  UserPromptSubmit)
    p=$(print -r -- "$input" | jq -r '.prompt // ""' | oneline)
    upd last_prompt "$p" status working
    ;;
  Stop)
    # 結果サマリ = transcript の最後のアシスタント応答の冒頭。
    # transcript は書き込みが遅れることがあるため、取れなければ前回値を残す
    tp=$(print -r -- "$input" | jq -r '.transcript_path // ""')
    s=""
    if [[ -n "$tp" && -r "$tp" ]]; then
      s=$(tail -n 300 "$tp" 2>/dev/null \
        | jq -r 'select(.type? == "assistant")
                 | [.message.content[]? | select(.type? == "text") | .text]
                 | join(" ")' 2>/dev/null \
        | grep -v '^[[:space:]]*$' | tail -n 1 | oneline)
    fi
    if [[ -n "$s" ]]; then
      upd status waiting summary "$s"
    else
      upd status waiting
    fi
    ;;
  SessionEnd)
    upd status ended
    ;;
  Notification)
    nt=$(print -r -- "$input" | jq -r '.notification_type // ""')
    case "$nt" in
      permission_prompt|elicitation_dialog) upd status needs_input ;;
      idle_prompt)                          upd status waiting ;;
    esac
    ;;
esac

# 一覧をその場で更新（リストペインの fzf に ctrl-r = reload を送る）
lp=$(jq -r '.list // ""' "$STATE/slots.json" 2>/dev/null)
[[ -n "$lp" ]] && tmux send-keys -t "$lp" C-r 2>/dev/null

exit 0
