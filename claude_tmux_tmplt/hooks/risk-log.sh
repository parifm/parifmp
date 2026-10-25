#!/opt/homebrew/bin/bash
# PreToolUse risk logger: log-only, never blocks, prints nothing.
# Appends outward or destructive tool calls to $TEAM_ROOT/.cos_tripwire/risk.log for the review sweeps.
# Extend the patterns below with your own outward CLIs.
export LC_ALL=C
LOG=${TEAM_ROOT:-$HOME/claude}/.cos_tripwire/risk.log
[ -d "${LOG%/*}" ] || exit 0
in=$(cat)
j=$(type -P jq) || exit 0
tool=$(printf '%s' "$in" | jq -r '.tool_name // ""' 2>&1) || exit 0
sid=$(printf '%s' "$in" | jq -r '.session_id // ""' 2>&1)
case $tool in
  Bash)
    s=$(printf '%s' "$in" | jq -r '.tool_input.command // ""' 2>&1)
    re='git[^|;&]*[[:space:]]push|gh[[:space:]]+(pr|issue|release|repo|gist)[[:space:]]+(create|merge|close|edit|comment|delete|reopen)|gh[[:space:]]+api[^|;&]*-X[[:space:]]*(POST|PATCH|PUT|DELETE)'
    re+='|oci[^|;&]*[[:space:]](launch|terminate|delete|create|update|attach|detach|action)([[:space:]]|$)|sf[[:space:]][^|;&]*(create|update|delete|upsert)'
    re+='|acli[^|;&]*[[:space:]](create|edit|transition|comment|delete|assign)|curl[^|;&]*(-X[[:space:]]*(POST|PUT|PATCH|DELETE)|--data|[[:space:]]-d[[:space:]])'
    re+='|(^|[;&|[:space:]])rm[[:space:]]+-[a-zA-Z]*[rR]|(^|[;&|[:space:]])(pkill|killall|kill)[[:space:]]|reboot|shutdown|systemctl[[:space:]]+(stop|restart|disable)'
    re+='|launchctl|tmux[[:space:]]+(kill|send-keys)'
    [[ $s =~ $re ]] || exit 0 ;;
  mcp__*)
    [[ $tool =~ (send|create|update|edit|delete|transition|add|post|schedule|trash|share|move|upload|reply|forward|label|respond) ]] || exit 0
    s=$(printf '%s' "$in" | jq -c '.tool_input // {}' 2>&1) ;;
  *) exit 0 ;;
esac
name=$(/usr/bin/grep -l "\"sessionId\":\"$sid\"" "$HOME"/.claude/sessions/*.json 2>&1 | head -1)
[ -f "$name" ] && name=$(jq -r '.name // "?"' "$name" 2>&1) || name='?'
s=${s//$'\n'/ ⏎ }
printf '%s\t%s\t%s\t%s\t%s\n' "$(date '+%F %T')" "$name" "$sid" "$tool" "${s:0:600}" >> "$LOG"
exit 0
