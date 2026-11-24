#!/bin/bash
input=$(cat)

# Helper function with jq defaults
get() { echo "$input" | jq -r "$1 // empty"; }

# Extract values
MODEL=$(get '.model.display_name')
EFFORT=$(get '.effort.level')
CWD=$(get '.cwd')
SESSION_ID=$(get '.session_id')

# Peer name (claude-xx) - the address other local sessions use to message this one.
# Not in the statusline payload (.session_name is the conversation title), so it is
# read from the peer registry at ~/.claude/sessions/<pid>.json.
SESSION_NAME=""
SESSION_REG="$HOME/.claude/sessions"

# Fast path: this script's parent is the claude process itself, so its registry
# file is one deterministic read. Matched against session_id to survive PID reuse.
if [ -f "$SESSION_REG/$PPID.json" ]; then
  SESSION_NAME=$(jq -r --arg sid "$SESSION_ID" \
    'select($sid == "" or .sessionId == $sid) | .name // empty' "$SESSION_REG/$PPID.json")
fi

# Fallback: scan the registry for our session_id. One file per jq call on purpose -
# these are rewritten live, so a half-written file must not kill the whole scan.
if [ -z "$SESSION_NAME" ] && [ -n "$SESSION_ID" ]; then
  for f in "$SESSION_REG"/*.json; do
    [ -e "$f" ] || continue
    n=$(jq -r --arg sid "$SESSION_ID" 'select(.sessionId == $sid) | .name // empty' "$f") || continue
    [ -n "$n" ] && { SESSION_NAME="$n"; break; }
  done
fi

# Tokens (calculated from used_percentage to match /context)
USED_PCT=$(get '.context_window.used_percentage')
CTX_SIZE=$(get '.context_window.context_window_size')

# Calculate actual context tokens from used_percentage (matches /context)
USED_TOKENS=$(echo "$USED_PCT * $CTX_SIZE / 100" | bc | cut -d. -f1)

# Cost & stats
COST=$(get '.cost.total_cost_usd')
DURATION_MS=$(get '.cost.total_duration_ms')
LINES_ADD=$(get '.cost.total_lines_added')
LINES_DEL=$(get '.cost.total_lines_removed')

# Format tokens as Xk (rounded, no decimals - matches /context format)
TOKENS_K=$(printf "%.0f" "$(echo "$USED_TOKENS / 1000" | bc -l)")k
CTX_K=$((CTX_SIZE / 1000))k

# Format cost
COST_FMT=$(printf "%.2f" "$COST")

# Format duration (smart: only non-zero units)
DURATION_S=$((DURATION_MS / 1000))
DAYS=$((DURATION_S / 86400))
HOURS=$(((DURATION_S % 86400) / 3600))
MINS=$(((DURATION_S % 3600) / 60))
SECS=$((DURATION_S % 60))

DURATION_FMT=""
[ "$DAYS" -gt 0 ] && DURATION_FMT="${DAYS}d "
[ "$HOURS" -gt 0 ] && DURATION_FMT="${DURATION_FMT}${HOURS}h "
[ "$MINS" -gt 0 ] && DURATION_FMT="${DURATION_FMT}${MINS}m "
[ "$SECS" -gt 0 ] || [ -z "$DURATION_FMT" ] && DURATION_FMT="${DURATION_FMT}${SECS}s"
DURATION_FMT=$(echo "$DURATION_FMT" | xargs)  # trim whitespace

# Git branch
GIT_BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null)

# Full path from cwd
DIR="$CWD"

# Colors (soft palette)
R="\033[0m"
C_SESSION="\033[38;5;110m"  # soft blue
C_MODEL="\033[38;5;250m"    # light gray
C_EFFORT="\033[38;5;245m"   # muted gray
C_TOKENS="\033[38;5;73m"    # soft teal
C_COST="\033[38;5;179m"     # soft amber
C_TIME="\033[38;5;245m"     # muted gray
C_ADD="\033[38;5;108m"      # sage green
C_DEL="\033[38;5;174m"      # soft rose
C_GIT="\033[38;5;108m"      # sage green
C_DIR="\033[38;5;183m"      # lavender

# Output - segments are pipe-delimited with no padding; empty ones drop out entirely
[ -n "$SESSION_NAME" ] && printf "${C_SESSION}%s${R}|" "$SESSION_NAME"
printf "${C_MODEL}%s${R}" "$MODEL"
[ -n "$EFFORT" ] && printf "${C_EFFORT}:%s${R}" "$EFFORT"
printf "|"
printf "${C_TOKENS}%s/%s${R}|" "$TOKENS_K" "$CTX_K"
printf "${C_COST}\$%s${R}|" "$COST_FMT"
printf "${C_TIME}%s${R}|" "$DURATION_FMT"
printf "${C_ADD}+%s${R}/${C_DEL}-%s${R}|" "$LINES_ADD" "$LINES_DEL"
[ -n "$GIT_BRANCH" ] && printf "${C_GIT}%s${R}|" "$GIT_BRANCH"
printf "${C_DIR}%s${R}" "$DIR"
