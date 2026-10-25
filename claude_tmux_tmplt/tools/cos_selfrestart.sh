#!/opt/homebrew/bin/bash
# Restart cos in its own pane (resume, same model/effort/persona, + the oversight plugin's settings) once cos is
# idle and the owner isn't viewing cos's window. Run detached by cos itself: nohup cos_selfrestart.sh "<why>" &
# Log: $TEAM_ROOT/.cos_selfrestart.log (cos redirects there). Gives up after TRIES. DRY=1 prints the command only.
R=${TEAM_ROOT:-$HOME/claude} TRIES=${TRIES:-20}
why=${1:-a restart}
f=$(/usr/bin/grep -l '"name":"cos"' "$HOME"/.claude/sessions/*.json | head -1)
[ -n "$f" ] || { echo "cos: no registry entry"; exit 1; }
read -r SID PID PANE < <(jq -r '[.sessionId, (.pid | tostring), (.tmux // "" | sub(".*[.]"; ""))] | @tsv' "$f")
[ -n "$PANE" ] || { echo "cos: no tmux pane"; exit 1; }
# Keep the live model and effort (read from cos's argv), default opus/high. The first occurrence wins: the launch
# prompt comes last and may itself mention "--model …".
read -r -a a <<< "$(ps -o args= -p "$PID")"
m= e=
for ((i = 0; i < ${#a[@]}; i++)); do
  case ${a[i]} in --model) [ -n "$m" ] || m=${a[i + 1]} ;; --effort) [ -n "$e" ] || e=${a[i + 1]} ;; esac
done
m=${m:-opus} e=${e:-high}
win=$(tmux display-message -p -t "$PANE" '#{window_index}')
prompt="cos: you restarted yourself at $(date +%H:%M) for $why. Your background jobs are gone.
1. Relaunch $R/tools/cos_mgrwatch.sh in the background (pgrep first).
2. Run CronList; re-create only what is missing.
Say nothing to the owner unless something failed."
cmd=(claude --resume "$SID" -n cos --model "$m" --effort "$e" --system-prompt-snapshot off
     --append-system-prompt-file "$R/personas/cos.md" --settings "$R/tools/oversight_plugin/settings.json" "$prompt")
line="cd $(printf '%q' "$R") && exec$(printf ' %q' "${cmd[@]}")"
[ -n "$DRY" ] && { printf '%s\n' "$line"; exit 0; }
for ((i = 1; i <= TRIES; i++)); do
  sleep 30
  v=$(tmux list-clients -F '#{window_index}' | head -1)
  st=$(jq -r --arg s "$SID" 'select(.sessionId == $s) | .status' "$HOME"/.claude/sessions/*.json | head -1)
  echo "$(date +%T) try $i viewing=$v status=$st"
  # "shell" = idle with a background shell running (cos always has cos_mgrwatch.sh); "busy" = mid-turn
  if [ "$v" != "$win" ] && { [ "$st" = idle ] || [ "$st" = shell ]; }; then
    tmux respawn-pane -k -t "$PANE" "$line"; echo "$(date +%T) respawned rc=$?"; exit 0
  fi
done
echo "$(date +%T) gave up after $TRIES tries"
