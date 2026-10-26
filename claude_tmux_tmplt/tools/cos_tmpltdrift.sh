#!/opt/homebrew/bin/bash
# Template-drift tripwire for owners who keep a shared copy of this kit. Zero tokens: hashes every file in the
# team's core dirs (personas/, tools/, the plugin, hooks, CLAUDE.md, settings.json hooks+env) and exits, waking cos,
# when any differs from the last reviewed baseline. The baseline is the last reviewed live state, not the kit: a change
# accepted before the kit has it goes in $P, one line each, until the kit is pushed with it; "clean" is never said
# while $P has lines. ONCE=1 checks once: exit 0 clean, 1 drift, 3 no new drift but the kit still lacks $P's changes.
R=${TEAM_ROOT:-$HOME/claude}
B=${DRIFT_BASE:-$R/.drift_baseline.sha} INTERVAL=${INTERVAL:-300}
P=${DRIFT_PENDING:-$R/drift_pending.txt}
pending() { local n=0; [ -s "$P" ] && n=$(grep -c -v -e '^#' -e '^$' "$P"); echo "$n"; }   # grep -c exits 1 on 0
core() {   # whole dirs, not a fixed list: a new persona, tool or hook shows up as a new entry
  { find "$R/personas" -maxdepth 1 -type f
    find "$HOME/.claude/hooks" -type f ! -name '*.log'
    find "$R/tools" -maxdepth 1 -type f ! -name '*.log' ! -name cos_tmpltdrift.sh
    find "$R/tools/oversight_plugin" -type f ! -path '*/.claude-plugin/types/*'   # types/ is regenerated on reload
    printf '%s\n' "$HOME/.claude/CLAUDE.md" "$R/CLAUDE.md"; } | sort -u
}
hashes() {
  local f
  while read -r f; do
    if [ -e "$f" ]; then shasum -a 256 "$f"; else echo "MISSING  $f"; fi
  done < <(core)
  printf '%s  settings.json:.hooks+.env\n' "$(jq -S '{hooks, env}' "$HOME/.claude/settings.json" | shasum -a 256 | cut -d' ' -f1)"
}
if [ "${1:-}" = --accept ]; then
  hashes > "$B.tmp" && mv "$B.tmp" "$B" && echo "baseline: $(wc -l < "$B") entries, $(date '+%F %T'); kit still lacks: $(pending) (see $P)"; exit 0
fi
[ -s "$B" ] || { echo "no baseline at $B; run $0 --accept after a review"; exit 2; }
while :; do
  d=$(diff "$B" <(hashes))
  if [ -n "$d" ]; then
    echo "$(date '+%F %T') template drift candidates (< baseline, > live):"; echo "$d"; exit 1
  fi
  if [ -n "${ONCE:-}" ]; then
    n=$(pending)
    if [ "$n" -gt 0 ]; then
      echo "no new drift $(date '+%F %T'), but the kit still lacks $n reviewed change(s):"; grep -v -e '^#' -e '^$' "$P"; exit 3
    fi
    echo "clean $(date '+%F %T')"; exit 0
  fi
  sleep "$INTERVAL"
done
