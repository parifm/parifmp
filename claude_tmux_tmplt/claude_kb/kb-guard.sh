#!/usr/bin/env bash
# PreToolUse guard (optional, with claude_kb/kb): the kb database is reached only through the kb script,
# so every session reads and writes memories the same way. A Bash command that names psql,
# createdb, dropdb or pg_dump together with the kb database is refused with the reason.
# The kb script's own psql calls run inside the script, not as tool calls, so the hook never sees them.
DB=${KB_DB:-kb}; [[ $DB =~ ^[A-Za-z0-9_]+$ ]] || DB=kb
KB=${TEAM_ROOT:-$HOME/claude}/claude_kb/kb
in=$(cat)
cmd=$(printf '%s' "$in" | jq -r '.tool_input.command // empty') || exit 0
[ -n "$cmd" ] || exit 0
hits() {   # $1: command text -> 0 when it names a psql-family tool together with the kb database
  printf '%s' "$1" | grep -Eq '(^|[^A-Za-z0-9_/.-])(psql|createdb|dropdb|pg_dump|pg_restore)([^A-Za-z0-9_]|$)' || return 1
  # the database named as -d kb, --dbname kb, dbname=kb, a bare positional kb, or .../kb in a URI
  printf '%s' "$1" | grep -Eq "(^|[[:space:]=/])$DB([[:space:]'\"]|\$)"
}
hits "$cmd" || exit 0
# when the kb script is the command, its arguments are memory text that may well say "psql" or "kb";
# judge only what follows a command separator (another command chained after it)
case "$cmd" in */claude_kb/kb\ *|kb\ *)
  rest=$(printf '%s' "$cmd" | sed -E -e "s/\"([^\"\\\\]|\\\\.)*\"//g" -e "s/'[^']*'//g")
  [[ $rest == *'<<'* ]] && rest=${rest%%$'\n'*}
  rest=$(printf '%s' "$rest" | sed -E 's/^[^;&|]*//')
  hits "$rest" || exit 0 ;;
esac
short="kb-guard: direct access to the kb database"
reason="$short. Memories are read and written only through $KB (search, ask, show, list, add, edit, retire), so every session handles them the same way. Use the script instead."
jq -nc --arg r "$reason" --arg s "$short" '{systemMessage:$s,hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
printf '%s deny %s\n' "$(date -u +%FT%TZ)" "${cmd:0:120}" >> "$HOME/.claude/hooks/kb-guard.log"
