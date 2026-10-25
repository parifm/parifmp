#!/opt/homebrew/bin/bash
# Append a statrep to ~/claude/cos_statrep and show it in a short pane under cos.
# Usage: cos_statrep.sh <window-name> < body   (body: "### <session>" sections, one per pane)
F=${TEAM_ROOT:-$HOME/claude}/cos_statrep
win=${1:?window name}
body=$(cat)
[ -n "$body" ] || { echo "empty body" >&2; exit 1; }
sess=$(printf "%s\n" "$body" | sed -n "s/^### *//p" | paste -sd, -)
printf "\n## %s | window %s | session %s\n%s\n" "$(date "+%Y-%m-%d %H:%M %Z")" "$win" "${sess:-?}" "$body" >> "$F"

# Reuse the statrep pane if it is open, else split one under the cos pane.
cos=$(jq -r '.tmux // "" | sub(".*[:.]";"")' "$(/usr/bin/grep -l '"name":"cos"' "$HOME"/.claude/sessions/*.json | head -1)")
view="clear; cat '$F'; read -r -p '--- press Enter to close ---' _"
p=$(tmux list-panes -a -F '#{pane_id} #{pane_title}' | awk '$2=="statrep"{print $1; exit}')
if [ -n "$p" ]; then
  tmux respawn-pane -k -t "$p" "$view"
else
  p=$(tmux split-window -v -d -l 12 -t "${cos:-%0}" -P -F '#{pane_id}' "$view")
  tmux select-pane -t "$p" -T statrep
fi
echo "statrep -> $p"
