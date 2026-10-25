#!/opt/homebrew/bin/bash
# Rebuild tmux session $TMUX_SESSION (default 0) from $TEAM_ROOT/restore/manifest.jsonl after a reboot; run by hand,
# no auto-start. Usage: cos_restore.sh [--go] [--manifest FILE] [--skip name,name]
# Without --go it only prints the plan. Refuses if the tmux session exists or any session in the manifest is running.
# Each Claude pane resumes its conversation with the flags it last ran with, plus a post-reboot prompt.
# --manifest also takes an older tab-separated .tsv manifest.
TR=${TEAM_ROOT:-$HOME/claude}
R=${RESTORE_D:-$TR/restore} S=${TMUX_SESSION:-0}
go= man=$R/manifest.jsonl skip=,
while (( $# )); do
  case $1 in
    --go) go=1 ;; --manifest) man=$2; shift ;; --skip) skip=,$2,; shift ;;
    *) echo "usage: cos_restore.sh [--go] [--manifest FILE] [--skip name,name]"; exit 2 ;;
  esac; shift
done
T=(tmux); [ -n "$TMUX_SOCKET" ] && T=(tmux -L "$TMUX_SOCKET")   # TMUX_SOCKET: rehearse on a separate tmux server
[ -f "$man" ] || { echo "no manifest at $man"; exit 1; }
when=$(cat "$R/last_snapshot" 2>&1)
rows() {   # one line per pane, fields joined by \037 (tab is IFS whitespace and would collapse empty fields), sorted by window, pane
  if [[ $man == *.tsv ]]; then
    jq -Rc 'select(startswith("#") | not) | split("\t") | {win: .[0], win_name: .[1], layout: .[2], pane: .[3], kind: .[4], name: .[5],
      session_id: .[6], cwd: .[7], model: .[8], effort: .[9], persona: .[10], settings: .[11]}' "$man"
  else cat "$man"; fi | jq -sr 'sort_by((.win | tonumber), (.pane | tonumber))[]
    | [.win, .win_name, .layout, .pane, .kind, .name, .session_id, .cwd, .model, .effort, .persona, .settings] | map(. // "") | join("\u001f")'
}
all=$(rows) || { echo "manifest $man is not valid; try one from $R/history/"; exit 1; }
[ -n "$all" ] || { echo "manifest $man has no panes"; exit 1; }
refuse() { if [ -n "$go" ]; then echo "REFUSED: $*"; exit 1; else echo "WOULD REFUSE with --go: $*"; fi; }
if out=$("${T[@]}" has-session -t "=$S" 2>&1); then refuse "tmux session $S already exists; restore is for an empty tmux."; fi
live=
while IFS=$'\037' read -r _ _ _ _ kind name sid _; do
  [ "$kind" = claude ] || continue
  [ -n "$(pgrep -f -- "$sid")" ] && live+="$name (resumed process) "
  for f in "$HOME"/.claude/sessions/*.json; do
    p=$(jq -r --arg s "$sid" 'select(.sessionId == $s) | .pid' "$f")
    [ -n "$p" ] && ps -o args= -p "$p" | /usr/bin/grep -q claude && live+="$name (pid $p) "
  done
done <<< "$all"
[ -n "$live" ] && refuse "still running: $live (two processes resuming one conversation would corrupt it)"

prompt() {   # $1 session name: the post-reboot message it resumes with
  local m="The Mac restarted. cos_restore.sh resumed you at $(date '+%F %H:%M') from the snapshot of ${when:-unknown}. Your background jobs, watchers, Monitors, crons that didn't survive, and ssh-driven loops are gone, and anything mid-turn was interrupted."
  case $1 in
    cos) m+=" Run your On start steps, compare against $man, and give the owner one table: who is back, who is missing, and which labs kept billing while the Mac was down." ;;
    mgr) m+=" Relaunch your background jobs (check pgrep first), run CronList and re-create only what is missing, then run a check-in now." ;;
    *) m+=" Before acting, check the real state of your work (hosts, files, git, cloud). Don't redo an outward or paid action until you have confirmed it didn't already happen. Relaunch your watchers, then tell cos your state in three lines." ;;
  esac
  printf '%s' "$m"
}
cmd_for() {   # fields of a manifest row -> the pane's command ("" = plain shell)
  local name=$1 sid=$2 cwd=$3 m=$4 e=$5 p=$6 s=$7
  [[ $skip == *",$name,"* ]] && { echo "  skip: $name (--skip), plain shell" >&2; return; }
  if [ -n "$p" ] && [ ! -f "$p" ]; then echo "  WARN $name: persona $p missing; not resuming it, plain shell" >&2; return; fi
  if [ -n "$s" ] && [ ! -f "$s" ]; then echo "  WARN $name: settings $s missing; resuming without them" >&2; s=; fi
  local -a a=(claude --resume "$sid" -n "$name")
  [ -n "$m" ] && a+=(--model "$m"); [ -n "$e" ] && a+=(--effort "$e")
  a+=(--system-prompt-snapshot off)
  [ -n "$p" ] && a+=(--append-system-prompt-file "$p"); [ -n "$s" ] && a+=(--settings "$s")
  a+=("$(prompt "$name")")
  printf 'cd %q && exec' "$cwd"; printf ' %q' "${a[@]}"
}
run() { if [ -n "$go" ]; then "${T[@]}" "$@" || { echo "FAILED: tmux $*"; exit 1; }; else { printf '  tmux'; printf ' %q' "$@"; echo; } | cut -c1-200; fi; }

echo "Restore plan from $man (snapshot ${when:-unknown})$([ -z "$go" ] && echo ', DRY RUN: add --go to execute')"
prev= lays=()
while IFS=$'\037' read -r w wn lay pi kind name sid cwd m e p s; do
  [ -d "$cwd" ] || cwd=$TR
  c=; [ "$kind" = claude ] && c=$(cmd_for "$name" "$sid" "$cwd" "$m" "$e" "$p" "$s")
  echo "window $w ($wn) pane $pi: ${name:-shell}"
  if [ "$w" != "$prev" ]; then
    if [ -z "$prev" ]; then   # tmux 3.8 layouts are JSON; older ones are "csum,WxH,..."
      if [[ $lay == '{'* ]]; then dims=$(jq -r '"\(.L.w)x\(.L.h)"' <<< "$lay"); else dims=${lay#*,}; dims=${dims%%,*}; fi
      run new-session -d -s "$S" -x "${dims%x*}" -y "${dims#*x}" -n "$wn" -c "$cwd" ${c:+"$c"}
      [ "$w" != 0 ] && run move-window -s "$S:0" -t "$S:$w"
    else run new-window -d -t "$S:$w" -n "$wn" -c "$cwd" ${c:+"$c"}; fi
    lays+=("$w"$'\t'"$lay"); prev=$w
  else run split-window -d -t "$S:$w" -c "$cwd" ${c:+"$c"}; fi
  [ -n "$name" ] && run select-pane -t "$S:$w.$pi" -T "$name"
done <<< "$all"
for x in "${lays[@]}"; do run select-layout -t "$S:${x%%$'\t'*}" "${x#*$'\t'}"; done
echo "Paid resources keep billing while the Mac is down. Rows in cos_watch.tsv with a \$ figure:"
if paid=$(/usr/bin/grep -E '\$[0-9]' "$TR/cos_watch.tsv"); then cut -c1-160 <<< "$paid"; else echo "  (none matched '\$<digit>'; cos checks the labs after restore)"; fi
[ -n "$go" ] && echo "Done. Attach with: tmux attach -t $S"
