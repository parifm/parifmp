#!/opt/homebrew/bin/bash
# mgr's sweep runner. Runs cos_sweep.sh on the quarter hour (the deep model at :15, the regular model at :00/:30/:45);
# exits, waking mgr, on a RISK finding or a failed sweep; other findings are held in sweep.held and released once
# an hour at :20 (fewer wakes). CLEAN / NOTHING NEW sweeps are only counted. No tokens between sweeps.
# Models: SWEEP_MODEL/SWEEP_EFFORT (regular) and SWEEP_DEEP_MODEL/SWEEP_DEEP_EFFORT (:15).
D=${SWEEP_D:-${TEAM_ROOT:-$HOME/claude}/.cos_tripwire}; mkdir -p "$D"; H=$D/sweep.held
TOOLS=${TEAM_ROOT:-$HOME/claude}/tools
RM=${SWEEP_MODEL:-claude-opus-5-5} RE=${SWEEP_EFFORT:-medium}
DM=${SWEEP_DEEP_MODEL:-claude-fable-5-1} DE=${SWEEP_DEEP_EFFORT:-high}
quiet=0
flush() { cat "$H"; rm -f "$H"; date +%Y%m%d%H > "$D/sweep.flushed"; exit 0; }
while :; do
  m=$(date +%M); slot=$(date +%Y%m%d%H)$(( 10#$m / 15 ))
  [ -s "$H" ] && (( 10#$m >= 20 )) && [ "$(date +%Y%m%d%H)" != "$(cat "$D/sweep.flushed" 2>&1)" ] && flush
  [ -n "$(find "$D" -maxdepth 1 -name sweep.lock -mmin +16)" ] && rmdir "$D/sweep.lock"
  if [ "$slot" != "$(cat "$D/sweep.slot" 2>&1)" ] && lk=$(mkdir "$D/sweep.lock" 2>&1); then
    echo "$slot" > "$D/sweep.slot"
    if (( 10#$m / 15 == 1 )); then sm=$DM se=$DE; else sm=$RM se=$RE; fi
    out=$("$TOOLS/cos_sweep.sh" "$sm" "$se" 2>&1); rc=$?; rmdir "$D/sweep.lock"
    case $rc in
      0) printf 'SWEEP %s/%s at %s (quiet sweeps before it: %d)\n%s\n' "$sm" "$se" "$(date +%H:%M)" "$quiet" "$out" >> "$H"; quiet=0
         if printf '%s\n' "$out" | /usr/bin/grep -qE '^\[[^]]*\] RISK:'; then flush; fi ;;
      1|2) quiet=$(( quiet + 1 )) ;;
      *) printf 'SWEEP FAILED %s/%s at %s, rc=%s: %s\n' "$sm" "$se" "$(date +%H:%M)" "$rc" "${out:0:300}"; exit 0 ;;
    esac
  fi
  sleep 30
done
