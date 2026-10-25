#!/opt/homebrew/bin/bash
# Show a cos note in a short pane just below the pane it is about; also log it.
# Usage: cos_note.sh <pane-id> < body
F=${TEAM_ROOT:-$HOME/claude}/cos_notes
t=${1:?target pane id}
body=$(cat)
[ -n "$body" ] || { echo "empty body" >&2; exit 1; }
win=$(tmux display -p -t "$t" '#{window_name}')
sess=$(jq -r --arg p "$t" 'select((.tmux // "") | endswith("." + $p)) | .name' "$HOME"/.claude/sessions/*.json | head -1)
n=$(mktemp "${TMPDIR:-/tmp}/cosnote.XXXXXX")
printf '## %s | window %s | session %s\n%s\n' "$(date '+%Y-%m-%d %H:%M %Z')" "$win" "${sess:-?}" "$body" | tee -a "$F" > "$n"
printf '\n' >> "$F"
h=$(( $(wc -l < "$n") + 3 )); [ "$h" -gt 20 ] && h=20
p=$(tmux split-window -v -d -l "$h" -t "$t" -P -F '#{pane_id}' "clear; cat '$n'; rm -f '$n'; read -r -p '--- press Enter to close ---' _")
tmux select-pane -t "$p" -T cosNote
echo "note -> $p (under $t)"
