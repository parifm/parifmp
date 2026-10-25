#!/opt/homebrew/bin/bash
# cos periodic check-in: one line per cos-launched session, FLAG lines for anything cos should look at.
# Sessions: names in ~/claude/cos_sessions (one per line, # comments ok).
# Commitments: ~/claude/cos_watch.tsv  session<TAB>what it owes<TAB>due (YYYY-MM-DD HH:MM local, or -)
S=${TEAM_ROOT:-$HOME/claude}/cos_sessions W=${TEAM_ROOT:-$HOME/claude}/cos_watch.tsv
now=$(date +%s)
[ -f "$S" ] || { echo "FLAG no $S"; exit 1; }
while read -r n; do
  case $n in ''|\#*) continue ;; esac
  f=$(/usr/bin/grep -l "\"name\":\"$n\"" "$HOME"/.claude/sessions/*.json | head -1)
  if [ -z "$f" ]; then echo "FLAG $n: not running (no registry entry)"; continue; fi
  read -r st since pane < <(jq -r '[.status, ((.statusUpdatedAt // .updatedAt) / 1000 | floor), (.tmux // "" | sub(".*[.]"; ""))] | @tsv' "$f")
  mins=$(( (now - since) / 60 ))
  tail=$(tmux capture-pane -p -t "$pane" 2>&1 | sed '/^[[:space:]]*$/d' | tail -12)
  shells=$(printf '%s\n' "$tail" | /usr/bin/grep -oE '[0-9]+ shells?' | tail -1)
  ask=; printf '%s\n' "$tail" | /usr/bin/grep -qE 'Enter to select|Do you want to (proceed|make this edit|create)|❯ 1\. ' && ask=yes
  owes=$(awk -F'\t' -v n="$n" '$1 == n { print $2 " (due " $3 ")" }' "$W" 2>&1 | paste -sd';' -)
  line="$n: $st ${mins}m${shells:+, $shells}${owes:+, owes: $owes}"
  if [ -n "$ask" ]; then echo "FLAG $line, question/permission prompt waiting"
  elif [ -n "$owes" ] && [ "$st" = idle ] && [ -z "$shells" ]; then echo "FLAG $line, idle with nothing running"
  elif [ -n "$owes" ]; then
    late=$(awk -F'\t' -v n="$n" '$1 == n && $3 != "-" { print $3 }' "$W" | while read -r d; do
      e=$(date -j -f '%Y-%m-%d %H:%M' "$d" +%s 2>&1) && [ "$e" -lt "$now" ] && echo "$d"; done | head -1)
    if [ -n "$late" ]; then echo "FLAG $line, past due"; else echo "ok   $line"; fi
  else echo "ok   $line"; fi
done < "$S"
