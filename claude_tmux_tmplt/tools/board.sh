#!/usr/bin/env bash
# Team board writer (hive mode: teams share one board instead of messaging each other status). Appends one stamped line
# to $BOARD_ROOT/<project>/BOARD.md, the team's shared state. The script, not the model, appends and stamps the UTC time,
# so no Read-before-Edit and no typed timestamps. It is the one sanctioned exception to "Edit tool for existing files".
# Usage: board.sh [-s <session>] <project-dir-name> <TYPE> <text…>   TYPE: DONE BLOCKED Q RISK PUSHED DECISION NOTE
# Session: -s, else $CLAUDE_SESSION_NAME, else the registry entry ~/.claude/sessions/$CLAUDE_PID.json (.name).
# Exit 0 = appended (the line is printed), 2 = bad usage or input; nothing is written on a non-zero exit.
BOARD_ROOT=${BOARD_ROOT:-${TEAM_ROOT:-$HOME/claude}} MAX=${BOARD_MAX:-200}
TYPES='DONE BLOCKED Q RISK PUSHED DECISION NOTE'
die() { echo "board.sh: $*" >&2; exit 2; }
usage="usage: board.sh [-s <session>] <project-dir-name> <TYPE> <text…> (TYPE: $TYPES)"

sess=
if [ "$1" = -s ]; then
  [ -n "$2" ] || die "-s needs a session name; $usage"
  sess=$2; shift 2
fi
[ $# -ge 3 ] || die "$usage"
proj=$1 type=$2; shift 2
text="$*"

# session: explicit flag, then env, then the Claude session registry (a sub-agent resolves to its parent session)
if [ -z "$sess" ] && [ -n "$CLAUDE_SESSION_NAME" ]; then sess=$CLAUDE_SESSION_NAME; fi
if [ -z "$sess" ] && [ -n "$CLAUDE_PID" ] && [ -f "$HOME/.claude/sessions/$CLAUDE_PID.json" ]; then
  sess=$(jq -r '.name // empty' "$HOME/.claude/sessions/$CLAUDE_PID.json")
fi
[ -n "$sess" ] || die "no session name: pass -s <session> (CLAUDE_SESSION_NAME unset, no registry entry for CLAUDE_PID)"
[[ $sess =~ ^[A-Za-z0-9_-]+$ ]] || die "session name '$sess' is not alphanumeric"

# project: one existing directory name directly under $BOARD_ROOT
[[ $proj =~ ^[A-Za-z0-9._-]+$ && $proj != . && $proj != .. ]] || die "project '$proj' must be a single directory name under $BOARD_ROOT"
[ -d "$BOARD_ROOT/$proj" ] || die "no project directory $BOARD_ROOT/$proj"

case " $TYPES " in *" $type "*) ;; *) die "TYPE '$type' is not one of: $TYPES" ;; esac

# text: one line, not empty, at most $MAX characters (a pointer, never pasted output)
nl=$'\n' cr=$'\r'
[[ $text == *"$nl"* || $text == *"$cr"* ]] && die "text must be one line (give a pointer to a file, never pasted output)"
[[ $text =~ [^[:space:]] ]] || die "text is empty"
(( ${#text} <= MAX )) || die "text is ${#text} characters, over $MAX: give a pointer (sha, rc file, path), not the proof"

f=$BOARD_ROOT/$proj/BOARD.md
if [ ! -e "$f" ]; then   # noclobber create: if two writers race, only one header lands; the loser's message is kept, not shown
  err=$( { set -C; printf '# BOARD %s: one line per entry, appended only by tools/board.sh: <UTC> <session> <TYPE> <text> [pointer]\n' "$proj" > "$f"; } 2>&1 )
  [ -e "$f" ] || die "could not create $f: $err"
fi
line="$(date -u +%Y-%m-%dT%H:%MZ) $sess $type $text"
printf '%s\n' "$line" >> "$f" || die "append to $f failed"
echo "$line"
