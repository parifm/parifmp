#!/opt/homebrew/bin/bash
# Review sweep (run by wtchr_sweeps.sh every 15 min: the regular model at :00/:30/:45, the deep model at :15).
# Reviews EVERYTHING each worker and its sub-agents did since this model's last sweep: nothing is
# dropped; oversized input is split into batches reviewed in parallel. The deep model covers the whole hour.
# Usage: cos_sweep.sh MODEL EFFORT. Exit 0 = FINDINGS (printed), 1 = CLEAN, 2 = nothing new, 3 = failed.
R=${TEAM_ROOT:-$HOME/claude}
D=${SWEEP_D:-$R/.cos_tripwire} P=$R/tools/cos_sweep_prompt.md HR=$R/house_rules.md L=$D/risk.log
MODEL=${1:-claude-opus-5-5} EFFORT=${2:-medium} BUDGET=${BUDGET:-350000}
T=${MODEL#claude-}; T=${T%%-*}   # each model family keeps its own offsets (off.<family>.*)
mkdir -p "$D/sweep"; now0=$(date +%s)
condense() { jq -rR '
  def cut($x; $n): if ($x | length) > $n then $x[0:($n / 2)] + " … " + $x[-($n / 2):] else $x end;
  fromjson? | ((.timestamp // "")[11:19]) as $t
  | if .type == "queue-operation" then (if .operation == "enqueue" then "\($t) Q: \(cut(.content | tostring; 2000))" else empty end)
    elif .type != "user" and .type != "assistant" then empty
    else (if .type == "user" then "U" else "A" end) as $r | .message.content as $c
  | if ($c | type) == "string" then "\($t) \($r): \(cut($c; 2000))"
    else $c[] | if .type == "text" then "\($t) \($r): \(cut(.text; 2000))"
      elif .type == "tool_use" then "\($t) T \(.name): \(cut(.input | tostring; 1500))"
      elif .type == "tool_result" then ((.content | if type == "string" then . else (map(.text? // "") | join(" ")) end)) as $x
        | "\($t) R: \(if ($x | test("answered|user said|rejected|denied"; "i")) then cut($x; 4000) else cut($x; 1200) end)"
      else empty end end end
  | gsub("\n"; " ⏎ ")' | tr -d '\000'; }
units=() offs=()
last=$(cat "$D/off.$T.time" 2>&1); [[ $last =~ ^[0-9]+$ ]] || last=$(( $(date +%s) - 1800 ))
cut=$(date -u -r "$last" +%Y-%m-%dT%H:%M:%S)
brief() {   # $1 session name, $2 jsonl: its persona (if any) plus its launch prompt, so scope and approvals are judged right
  local p=$R/personas/$1.md
  { [ -f "$p" ] && head -c 9000 "$p"
    printf '\n[launch prompt] '
    jq -rR 'fromjson? | select(.type == "user" and (.message.content | type) == "string") | .message.content' "$2" | head -c 3000; } | tr -d '\000'
}
add_unit() {   # $1 label, $2 jsonl, $3 offset key, $4 optional brief (persona + launch prompt)
  local tot off delta
  tot=$(wc -l < "$2" | tr -d ' ')
  off=$(cat "$D/off.$T.$3" 2>&1)
  if ! [[ $off =~ ^[0-9]+$ ]]; then   # first sight: start at the first line stamped at or after this model's last sweep
    off=$(awk -v c="$cut" 'match($0, /"timestamp":"[^"]+"/) { if (substr($0, RSTART + 13, RLENGTH - 14) >= c) { print NR - 1; f = 1; exit } }
      END { if (!f) print NR }' "$2")
    (( off > tot )) && off=$tot
  fi
  offs+=("$3 $tot")
  (( tot > off )) || return
  delta=$(sed -n "$((off + 1)),${tot}p" "$2" | condense)
  [ -n "$delta" ] && units+=("=== $1 ===${4:+
--- brief (persona + launch prompt; scope and standing rules) ---
$4
--- activity ---}
$delta
")
}
for f in "$HOME"/.claude/sessions/*.json; do
  IFS=$'\t' read -r n sid cwd < <(jq -r 'select(.entrypoint == "cli") | [.name // "", .sessionId // "", .cwd // ""] | @tsv' "$f")
  [ -z "$n" ] || [ -z "$sid" ] && continue   # cos included: the sweeps check up on cos as well
  pd=$HOME/.claude/projects/$(printf '%s' "$cwd" | sed 's/[^a-zA-Z0-9]/-/g')
  [ -f "$pd/$sid.jsonl" ] && add_unit "session $n" "$pd/$sid.jsonl" "$sid" "$(brief "$n" "$pd/$sid.jsonl")"
  for s in "$pd/$sid"/subagents/*.jsonl; do
    [ -f "$s" ] && add_unit "session $n / sub-agent $(basename "$s" .jsonl)" "$s" "$sid.$(basename "$s" .jsonl)"
  done
done
rtot=0; [ -f "$L" ] && rtot=$(wc -l < "$L" | tr -d ' '); [[ $rtot =~ ^[0-9]+$ ]] || rtot=0
roff=$(cat "$D/off.$T.risk" 2>&1); [[ $roff =~ ^[0-9]+$ ]] || roff=0
risk=; (( rtot > roff )) && risk=$(sed -n "$((roff + 1)),${rtot}p" "$L")
save() { for o in "${offs[@]}"; do echo "${o#* }" > "$D/off.$T.${o%% *}"; done; echo "$rtot" > "$D/off.$T.risk"; echo "$now0" > "$D/off.$T.time"; }
if (( ${#units[@]} == 0 )) && [ -z "$risk" ]; then
  printf '%s\nNOTHING NEW\n\n' "--- $(date '+%F %T') ($MODEL/$EFFORT, 0 batches)" >> "$D/review.log"; save; exit 2; fi
# Pack units into batches of <= BUDGET bytes; a unit larger than BUDGET is split by lines.
batches=() cur=
for u in "${units[@]}"; do
  if (( ${#u} > BUDGET )); then
    hdr=${u%%$'\n'*}
    while IFS= read -r -d $'\x1e' piece; do batches+=("$hdr (part)
$piece"); done < <(printf '%s\n' "${u#*$'\n'}" | awk -v b="$BUDGET" '{ if (n + length($0) > b) { printf "%s\x1e", s; s = ""; n = 0 } s = s $0 "\n"; n += length($0) + 1 } END { if (s != "") printf "%s\x1e", s }')
  elif (( ${#cur} + ${#u} > BUDGET )); then batches+=("$cur"); cur=$u
  else cur+=$u; fi
done
[ -n "$cur" ] && batches+=("$cur"); (( ${#batches[@]} )) || batches+=("")
seen=$(/usr/bin/grep -E '^- \[' "$D/review.log" 2>&1 | tail -40)
run=$D/sweep/run.$$; mkdir -p "$run"; i=0
for b in "${batches[@]}"; do
  i=$((i + 1)); r='(in batch 1)'; [ $i -eq 1 ] && r=${risk:-(none)}
  printf '%s\n\n## House rules (every session is bound by these)\n%s\n\n## Already reported (do not repeat these)\n%s\n\n## Transcript deltas (batch %d of %d)\n%s\n\n## New risk-log lines (time, session, id, tool, command)\n%s\n' \
    "$(cat "$P")" "$(cat "$HR" 2>&1)" "${seen:-(none)}" "$i" "${#batches[@]}" "${b:-(none)}" "$r" > "$run/in.$i"
  ( cd "$D/sweep" && env -u TMUX -u TMUX_PANE gtimeout 840 claude -p --model "$MODEL" --effort "$EFFORT" --tools "" \
      --strict-mcp-config --disable-slash-commands --no-session-persistence < "$run/in.$i" > "$run/out.$i" 2>&1
    echo $? > "$run/rc.$i" ) &
done
wait
fail= finds= bytes=0
for ((k = 1; k <= i; k++)); do
  bytes=$(( bytes + $(wc -c < "$run/in.$k") )); o=$(cat "$run/out.$k")
  if [ "$(cat "$run/rc.$k")" != 0 ] || [ -z "$o" ]; then fail+="batch $k rc=$(cat "$run/rc.$k"): ${o:0:200}; "
  elif [[ $o == FINDINGS* ]]; then finds+=${o#FINDINGS}$'\n'; fi
done
status=CLEAN; [ -n "$finds" ] && status=FINDINGS$finds; [ -n "$fail" ] && status="FAILED: $fail"$'\n'$status
printf '%s\n%s\n\n' "--- $(date '+%F %T') ($MODEL/$EFFORT, $i batch(es), $bytes bytes in)" "$status" >> "$D/review.log"
for ((k = 1; k <= i; k++)); do rm -f -- "$run/in.$k" "$run/out.$k" "$run/rc.$k"; done; rmdir -- "$run"
[ -n "$fail" ] && { echo "sweep failed: $fail"; exit 3; }
save
[ -n "$finds" ] && { printf 'FINDINGS%s' "$finds" | sed '/^$/d'; exit 0; }
exit 1
