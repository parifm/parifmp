#!/opt/homebrew/bin/bash
# cos's zero-token check on mgr. Run by cos with run_in_background; exits (waking cos) only when a problem has
# held for FAILS checks in a row: mgr's process gone, a job not running exactly once, or a stale snapshot.
# ONCE=1 checks once and prints the result.
INTERVAL=${INTERVAL:-60} FAILS=${FAILS:-3} STALE=${STALE:-300}
R=${TEAM_ROOT:-$HOME/claude} BASH5=${BASH5:-/opt/homebrew/bin/bash}
instances() {   # $1 script: running copies, not counting the sweep runner's subshell children (same argv, parent is a copy)
  local p pp n=0
  for p in $(pgrep -f "^$BASH5 $R/tools/$1\$"); do
    pp=$(ps -o ppid= -p "$p" | tr -d ' ')
    [[ $(ps -o args= -p "$pp") == "$BASH5 $R/tools/$1" ]] || n=$((n + 1))
  done
  echo "$n"
}
check() {   # prints problems, one per line; empty means healthy
  local f pid=
  for f in "$HOME"/.claude/sessions/*.json; do
    [ "$(jq -r .name "$f")" = mgr ] && pid=$(jq -r .pid "$f")
  done
  if [ -z "$pid" ]; then echo "mgr: no registry entry"
  elif [[ $(ps -o args= -p "$pid") != claude* ]]; then echo "mgr: pid $pid is not running claude"; fi
  for s in cos_tripwire.sh wtchr_sweeps.sh cos_snapshot.sh; do
    n=$(instances "$s"); [ "$n" = 1 ] || echo "$s: $n instances"
  done
  if [ -f "$R/restore/last_snapshot" ]; then
    local age=$(( $(date +%s) - $(stat -f %m "$R/restore/last_snapshot") ))
    (( age <= STALE )) || echo "last_snapshot is ${age}s old"
  else echo "no $R/restore/last_snapshot yet"; fi
}
bad=0
while :; do
  out=$(check)
  if [ -n "$out" ]; then bad=$((bad + 1)); else bad=0; fi
  if (( bad >= FAILS )); then printf 'MGR CHECK FAILED (%d checks in a row) at %s\n%s\n' "$bad" "$(date '+%F %T')" "$out"; exit 0; fi
  [ -n "$ONCE" ] && { echo "${out:-healthy}"; exit 0; }
  sleep "$INTERVAL"
done
