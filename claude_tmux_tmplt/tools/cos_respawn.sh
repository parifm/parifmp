#!/opt/homebrew/bin/bash
# Restart a Claude session in its own tmux pane with a fresh process (fresh env, current plugins), keeping its conversation.
# Usage: cos_respawn.sh <session-name> <model> <effort> [persona-file] [settings-file]
# Refuses unless the session is idle. The pane gets tmux's current environment (e.g. a live SSH_AUTH_SOCK).
set -euo pipefail
R=${TEAM_ROOT:-$HOME/claude} OV=${TEAM_ROOT:-$HOME/claude}/tools/oversight_plugin/settings.json
n=${1:?session name} m=${2:?model} e=${3:?effort} persona=${4:-} settings=${5:-}
f=$(/usr/bin/grep -l "\"name\":\"$n\"" "$HOME"/.claude/sessions/*.json | head -1)
[ -n "$f" ] || { echo "$n: no registry entry" >&2; exit 1; }
read -r sid st pane < <(jq -r '[.sessionId, .status, (.tmux // "" | sub(".*[.]"; ""))] | @tsv' "$f")
[ "$st" = idle ] || { echo "$n: status $st, not idle; not restarting" >&2; exit 3; }
[ -n "$pane" ] || { echo "$n: no tmux pane" >&2; exit 1; }
cmd="cd $(printf '%q' "$R") && exec claude --resume $sid -n $n --model $m --effort $e --system-prompt-snapshot off"
[ -n "$persona" ] && cmd="$cmd --append-system-prompt-file $persona"
# Lab/spending workers: attach personas/<name>.settings.json when it exists. An explicit settings file replaces it.
# With neither, every session gets the oversight plugin's settings. A worker's own settings file must carry
# {"env":{"CLAUDE_CODE_PLUGIN_DIRS":…}} too.
s=${settings:-$R/personas/$n.settings.json}
[ -f "$s" ] || s=$OV
if [ "$s" != "$OV" ] && ! /usr/bin/grep -q CLAUDE_CODE_PLUGIN_DIRS "$s"; then echo "$n: WARN $s lacks the oversight plugin env; merge it in" >&2; fi
if [ -n "$settings" ] && [ ! -f "$settings" ]; then echo "$n: settings $settings missing; not restarting" >&2; exit 1; fi
[ -f "$s" ] && cmd="$cmd --settings $s"
tmux respawn-pane -k -t "$pane" "$cmd"
tmux select-pane -t "$pane" -T "$n"
echo "$n: restarted in $pane (session $sid)"
