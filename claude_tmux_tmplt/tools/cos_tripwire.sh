#!/opt/homebrew/bin/bash
# Tripwire: zero-token watcher for every named tmux Claude session except cos and mgr (mgr runs it).
# Polls each 30 s; exits (waking mgr) only on a NEW permission prompt/question, a stall or a vanished session.
# Run in background; relaunch after handling. Review sweeps run separately in mgr (wtchr_sweeps.sh).
# Quiet events (STALL while a background agent/job runs) go to tripwire.log only.
STALL_MIN=${STALL_MIN:-15} ASK_MIN=${ASK_MIN:-5} CAP_H=${CAP_H:-24}
D=${TEAM_ROOT:-$HOME/claude}/.cos_tripwire; mkdir -p "$D"; L=$D/tripwire.log
end=$(( $(date +%s) + CAP_H * 3600 ))
declare -A seen
while :; do
  now=$(date +%s); hits=()
  declare -A live=()
  for f in "$HOME"/.claude/sessions/*.json; do
    read -r n st pane < <(jq -r 'select(.entrypoint == "cli") | [.name // "", .status // "", (.tmux // "" | sub(".*[.]"; ""))] | @tsv' "$f")
    [ -z "$n" ] || [ -z "$pane" ] || [ "$n" = cos ] || [ "$n" = mgr ] && continue
    live[$n]=1; seen[$n]=1
    cap=$(tmux capture-pane -p -t "$pane" 2>&1 | sed '/^[[:space:]]*$/d')
    tail=$(printf '%s\n' "$cap" | tail -12)
    if printf '%s\n' "$tail" | /usr/bin/grep -qE 'Enter to select|Do you want to (proceed|make this edit|create)|❯ 1\. '; then
      h=$(printf '%s\n' "$tail" | shasum | cut -c1-12)
      # Flag only after ASK_MIN unanswered, and never in the pane the owner is looking at.
      [ -f "$D/ask.$n.$h" ] || echo "$now" > "$D/ask.$n.$h"
      viewing=$(tmux display-message -p -t "$pane" '#{&&:#{session_attached},#{&&:#{window_active},#{pane_active}}}' 2>&1)
      if [ ! -f "$D/flagged.$n.$h" ] && [ "$viewing" != 1 ] && (( now - $(cat "$D/ask.$n.$h") >= ASK_MIN * 60 )); then : > "$D/flagged.$n.$h"; hits+=("ASK $n ($pane): $(printf '%s\n' "$cap" | tail -30 | /usr/bin/grep -E 'Do you want|\?' | tail -1 | cut -c1-120)"); fi
    fi
    body=$(printf '%s\n' "$cap" | awk '{a[NR]=$0} END {for (i = 1; i <= NR - 8; i++) print a[i]}' | shasum | cut -c1-12)
    if [ "$(cat "$D/body.$n" 2>&1)" != "$body" ]; then printf '%s\n' "$body" > "$D/body.$n"; echo "$now" > "$D/since.$n"; rm -f "$D/stall.$n"
    elif [ "$st" = busy ] && [ ! -f "$D/stall.$n" ] && (( now - $(cat "$D/since.$n") >= STALL_MIN * 60 )); then
      : > "$D/stall.$n"
      if printf '%s\n' "$tail" | /usr/bin/grep -qE 'Waiting for [0-9]+ background'; then echo "$(date +%T) STALL $n ($pane): quiet, background work running" >> "$L"
      else hits+=("STALL $n ($pane): busy, pane unchanged ${STALL_MIN}+ min"); fi
    fi
  done
  for n in "${!seen[@]}"; do
    [ -n "${live[$n]}" ] && continue
    unset "seen[$n]"
    hits+=("GONE $n: registry entry vanished")
  done
  if (( ${#hits[@]} )); then printf '%s\n' "${hits[@]}"; exit 0; fi
  (( now >= end )) && { echo "CAP ${CAP_H}h reached, no triggers; relaunch"; exit 0; }
  sleep 30
done
