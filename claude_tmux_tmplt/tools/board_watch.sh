#!/usr/bin/env bash
# mgr's zero-token board watch (hive mode: teams don't message cos and mgr; this watcher flags RISK/PUSHED/BLOCKED
# lines). Run by mgr with run_in_background; exits (waking mgr) only when a board line of type RISK,
# PUSHED or BLOCKED lands on any $BOARD_ROOT/*/BOARD.md after its start offset, or a board shrinks (boards are append-only).
# Start offsets come from $OFFSETS when it exists (written at each exit, so a line landing between a wake and the relaunch
# is still caught), else from each board's length at start. ONCE=1 prints the boards and their offsets and exits 0.
if (( BASH_VERSINFO[0] < 4 )); then echo "board_watch.sh needs bash 4+ (associative arrays); run it with /opt/homebrew/bin/bash" >&2; exit 2; fi
BOARD_ROOT=${BOARD_ROOT:-${TEAM_ROOT:-$HOME/claude}} INTERVAL=${INTERVAL:-30}
OFFSETS=${OFFSETS:-$BOARD_ROOT/.cos_tripwire/board_watch.offsets}
shopt -s nullglob
declare -A seen   # board path -> lines already looked at

lines() { local n; n=$(wc -l < "$1") || n=0; echo $((n + 0)); }
boards() { printf '%s\n' "$BOARD_ROOT"/*/BOARD.md; }
save() {   # offsets for the next start: one "<lines>\t<path>" row per board, written to a new file then moved
  local b
  mkdir -p "${OFFSETS%/*}" || return
  for b in "${!seen[@]}"; do printf '%s\t%s\n' "${seen[$b]}" "$b"; done > "$OFFSETS.tmp" && mv "$OFFSETS.tmp" "$OFFSETS"
}

if [ -s "$OFFSETS" ]; then
  while IFS=$'\t' read -r n b; do [ -n "$b" ] && seen[$b]=$n; done < "$OFFSETS"
fi
while read -r b; do
  [ -n "$b" ] && [ -z "${seen[$b]+x}" ] && seen[$b]=$(lines "$b")
done < <(boards)

if [ -n "$ONCE" ]; then
  echo "board watch $(date -u +%Y-%m-%dT%H:%MZ): ${#seen[@]} board(s) under $BOARD_ROOT"
  for b in "${!seen[@]}"; do echo "  ${seen[$b]} lines  $b"; done
  save; exit 0
fi

while :; do
  hits=
  while read -r b; do
    [ -n "$b" ] || continue
    base=${seen[$b]:-0} now=$(lines "$b")   # a board that appeared after start begins at 0 (its header never matches)
    if (( now < base )); then
      hits+="$b: SHRANK from $base to $now lines (boards are append-only; written outside board.sh?)"$'\n'
    elif (( now > base )); then
      hits+=$(awk -v base="$base" -v now="$now" -v p="${b#"$BOARD_ROOT"/}" \
        'NR > base && NR <= now && $3 ~ /^(RISK|PUSHED|BLOCKED)$/ { print p ": " $0 }' "$b")
      [ -n "${hits}" ] && [ "${hits: -1}" != $'\n' ] && hits+=$'\n'
    fi
    seen[$b]=$now
  done < <(boards)
  if [ -n "$hits" ]; then
    save
    printf 'BOARD WATCH %s: new RISK/PUSHED/BLOCKED line(s)\n%s' "$(date -u +%Y-%m-%dT%H:%MZ)" "$hits"
    exit 0
  fi
  # a killed sleep (e.g. another session running `pkill -x sleep`) only shortens this wait; waiting on a background sleep
  # keeps bash from printing "Terminated" into the wake output
  sleep "$INTERVAL" & wait "$!" || :
done
