#!/opt/homebrew/bin/bash
# Reboot insurance (no auto-start: after a reboot the owner runs cos_restore.sh by hand).
# Records every tmux pane in session 0 with what cos_restore.sh needs to rebuild it: window, layout, and for
# Claude panes the session name, id, cwd and launch flags (read from the live process). Writes
# ~/claude/restore/manifest.jsonl only when it changes, keeping the last KEEP versions in history/.
# One JSON object per pane (JSONL, so empty or new fields never shift the others):
#   win win_name layout pane kind(claude|shell) name session_id cwd model effort persona settings
# Run by mgr in the background. ONCE=1 takes one snapshot and exits (for tests).
R=${RESTORE_D:-${TEAM_ROOT:-$HOME/claude}/restore} S=${TMUX_SESSION:-0}
INTERVAL=${INTERVAL:-60} KEEP=${KEEP:-20}
mkdir -p "$R/history"
flags() {   # $1 pid: {model, effort, persona, settings} from its argv (paths under $TEAM_ROOT have no spaces)
  # The first occurrence of each flag wins: a launch prompt comes last and may itself mention "--settings …".
  local -a a; read -r -a a <<< "$(ps -o args= -p "$1")"
  local m= e= p= s= i
  for ((i = 0; i < ${#a[@]}; i++)); do
    case ${a[i]} in
      --model) [ -n "$m" ] || m=${a[i + 1]} ;; --effort) [ -n "$e" ] || e=${a[i + 1]} ;;
      --append-system-prompt-file) [ -n "$p" ] || p=${a[i + 1]/#\~/$HOME} ;; --settings) [ -n "$s" ] || s=${a[i + 1]/#\~/$HOME} ;;
    esac
  done
  jq -cn --arg model "$m" --arg effort "$e" --arg persona "$p" --arg settings "$s" '{$model, $effort, $persona, $settings}'
}
snap() {
  declare -A reg=()
  local f row
  for f in "$HOME"/.claude/sessions/*.json; do
    row=$(jq -c 'select(.entrypoint == "cli" and .tmux != null) | {pane_id: (.tmux | sub(".*[.]"; "")), name: (.name // ""), session_id: .sessionId, pid: (.pid | tostring), cwd}' "$f")
    [ -n "$row" ] && reg[$(jq -r .pane_id <<< "$row")]=$row
  done
  local w wn lay pi pn path
  while IFS=$'\037' read -r w wn lay pi pn path; do   # \037, not tab: tab is IFS whitespace and collapses empty fields
    if [ -n "${reg[$pn]}" ]; then
      jq -cn --arg win "$w" --arg win_name "$wn" --arg layout "$lay" --arg pane "$pi" --argjson r "${reg[$pn]}" \
        --argjson f "$(flags "$(jq -r .pid <<< "${reg[$pn]}")")" \
        '{$win, $win_name, $layout, $pane, kind: "claude", name: $r.name, session_id: $r.session_id, cwd: $r.cwd} + $f'
    else
      jq -cn --arg win "$w" --arg win_name "$wn" --arg layout "$lay" --arg pane "$pi" --arg cwd "$path" \
        '{$win, $win_name, $layout, $pane, kind: "shell", name: "", session_id: "", $cwd, model: "", effort: "", persona: "", settings: ""}'
    fi
  done < <(tmux list-panes -s -t "$S" -F $'#{window_index}\037#{window_name}\037#{window_layout}\037#{pane_index}\037#{pane_id}\037#{pane_current_path}')
}
while :; do
  new=$(snap)
  if [ -n "$new" ] && [ "$new" != "$(cat "$R/manifest.jsonl" 2>&1)" ]; then
    printf '%s\n' "$new" > "$R/manifest.jsonl.tmp" && mv "$R/manifest.jsonl.tmp" "$R/manifest.jsonl"
    cp "$R/manifest.jsonl" "$R/history/manifest.$(date +%Y%m%d-%H%M%S).jsonl"
    ls -t "$R"/history/manifest.*.jsonl | tail -n +$((KEEP + 1)) | while read -r old; do rm -f -- "$old"; done
  fi
  date '+%F %T' > "$R/last_snapshot"
  [ -n "$ONCE" ] && exit 0
  sleep "$INTERVAL"
done
