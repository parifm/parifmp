#!/opt/homebrew/bin/bash
# Start the two coordinators in a new tmux session: window 0 "cos", cos on the left and mgr on the right.
# macOS + Homebrew only (see README "Platform"). Run after install.sh --go. Usage: ./start_team.sh
# COS_MODEL/COS_EFFORT (default opus/high), MGR_MODEL/MGR_EFFORT (default opus/medium), TMUX_SESSION (default 0).
set -u
[ "$(uname -s)" = Darwin ] && [ -x /opt/homebrew/bin/bash ] || { echo "REFUSED: macOS with Homebrew's bash 5 at /opt/homebrew/bin/bash only; see README \"Platform\"."; exit 1; }
R=${TEAM_ROOT:-$HOME/claude} S=${TMUX_SESSION:-0}
P=$R/personas ST=$R/tools/oversight_plugin/settings.json
for f in "$P/cos.md" "$P/mgr.md" "$ST"; do [ -f "$f" ] || { echo "REFUSED: $f missing; run ./install.sh --go first"; exit 1; }; done
if /usr/bin/grep -q '<OWNER' "$P/cos.md" "$P/mgr.md"; then echo "REFUSED: replace <OWNER> and <OWNER_ROLE_ONE_LINE> in $P/cos.md and mgr.md first"; exit 1; fi
if out=$(tmux has-session -t "=$S" 2>&1); then echo "REFUSED: tmux session $S already exists"; exit 1; fi
launch() {   # $1 name $2 model $3 effort $4 opening prompt
  printf 'cd %q && exec claude -n %q --model %q --effort %q --append-system-prompt-file %q --settings %q %q' \
    "$R" "$1" "$2" "$3" "$P/$1.md" "$ST" "$4"
}
cosp="cos: you were just started by start_team.sh. Run your On start steps."
mgrp="mgr: you were just started by start_team.sh. Start your background jobs (pgrep first, one each), run CronList and create your hourly check-in, then stay quiet."
tmux new-session -d -s "$S" -n cos -c "$R" "$(launch cos "${COS_MODEL:-opus}" "${COS_EFFORT:-high}" "$cosp")" || exit 1
tmux select-pane -t "$S:0.0" -T cos
tmux split-window -h -d -t "$S:0" -c "$R" "$(launch mgr "${MGR_MODEL:-opus}" "${MGR_EFFORT:-medium}" "$mgrp")" || exit 1
tmux select-pane -t "$S:0.1" -T mgr
echo "Started. Attach with: tmux attach -t $S"
