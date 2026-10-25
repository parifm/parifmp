#!/opt/homebrew/bin/bash
# Watch sub-agent outputs or job logs; exit (waking the parent) on the first stale file (2), all done (0) or timeout (3).
# Usage: agent_watch.sh [-s stale_sec=900] [-t timeout_sec=4500] [-i interval_sec=60] [-d done_suffix=.done] FILE...
# Done: FILE<done_suffix> exists, or the Claude transcript ended (end_turn or SubagentHandback).
set -u
usage() { echo "usage: agent_watch.sh [-s stale_sec=900] [-t timeout_sec=4500] [-i interval_sec=60] [-d done_suffix=.done] FILE..." >&2; exit 64; }
stale=900 tmo=4500 ivl=60 sfx=.done
while getopts ":s:t:i:d:" o; do
  case $o in s) stale=$OPTARG ;; t) tmo=$OPTARG ;; i) ivl=$OPTARG ;; d) sfx=$OPTARG ;; *) usage ;; esac
done
shift $((OPTIND - 1))
(( $# > 0 )) || usage
for n in "$stale" "$tmo" "$ivl"; do [[ $n =~ ^[0-9]+$ ]] || usage; done
(( ivl > 0 )) && [[ -n $sfx ]] || usage

# Transcript ended: the last user/assistant record (a partial last line is skipped) is an
# assistant end_turn, or the tool_result of a successful SubagentHandback call.
JQ='[inputs | fromjson? | select(.type == "assistant" or .type == "user")] as $r
| ([$r[] | select(.type == "assistant") | .message.content[]? | select(.type? == "tool_use" and .name == "SubagentHandback") | .id]) as $hb
| ($r | length) > 0 and (
    ($r[-1].type == "assistant" and $r[-1].message.stop_reason == "end_turn")
    or ($r[-1].type == "user" and any($r[-1].message.content[]?; .type? == "tool_result" and .is_error != true and (.tool_use_id as $i | $hb | index($i)) != null)))'

is_done() {
  [[ -e $1$sfx ]] && return 0
  [[ -r $1 ]] || return 1
  local r; r=$(tail -n 8 -- "$1" | jq -nR "$JQ")
  [[ $r == true ]]
}

start=$(date +%s) end=$(( start + tmo ))
while :; do
  now=$(date +%s) left=()
  for f in "$@"; do is_done "$f" || left+=("$f"); done
  (( ${#left[@]} == 0 )) && { echo "WATCH $(date +%H:%M) ALL DONE"; exit 0; }
  for f in "${left[@]}"; do
    m=$start   # a file missing at start is aged from the watcher's start
    [[ -e $f ]] && m=$(stat -L -f %m -- "$f")   # -L: task .output files are symlinks
    age=$(( now - m ))
    (( age > stale )) && { echo "WATCH $(date +%H:%M) STALE $f ${age}s"; exit 2; }
  done
  (( now >= end )) && { echo "WATCH TIMEOUT; not done: ${left[*]}"; exit 3; }
  nap=$(( end - now < ivl ? end - now : ivl ))
  sleep "$nap"
done
