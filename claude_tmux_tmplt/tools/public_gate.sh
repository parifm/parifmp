#!/usr/bin/env bash
# Public-repo leak gate: catches leaks before they are committed or pushed. Wire it into each clone of a PUBLIC repo:
#   .git/hooks/pre-commit: exec "$TEAM_ROOT/tools/public_gate.sh" pre-commit
#   .git/hooks/pre-push:   exec "$TEAM_ROOT/tools/public_gate.sh" pre-push
# Blocks on names in public_patterns.txt (yours: customers, hosts, projects; one per line, whole words), cloud OCIDs,
# private keys, or private IPs not in public_ip_baseline.txt. Log: $TEAM_ROOT/.cos_tripwire/public_gate.log
D=${TEAM_ROOT:-$HOME/claude}/.cos_tripwire
P=$D/public_patterns.txt
B=$D/public_ip_baseline.txt
L=$D/public_gate.log
for f in "$P" "$B"; do [ -f "$f" ] || { echo "public_gate: missing $f (an empty file is fine)" >&2; exit 1; }; done
RX_IP='(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})'
RX_HARD='ocid1[.][a-z]+[.]|PRIVATE KEY-{5}|BEGIN OPEN[S]SH'   # written so the gate never matches its own source
mode=$1
repo=$(git rev-parse --show-toplevel 2>&1)
case $mode in
  pre-commit)
    added=$(git diff --cached -U0 --no-color 2>&1 | grep -E '^\+[^+]|^\+$'; git diff --cached --name-only 2>&1 | sed 's/^/FILE /') ;;
  pre-push)
    added=""
    while read -r lref lsha rref rsha; do
      case $lsha in 0000000000000000000000000000000000000000|"") continue ;; esac
      added+=$(git log --no-color --format='COMMIT %h %s%n%b' -p "$lsha" --not --remotes=origin 2>&1 | grep -E '^(\+[^+]|COMMIT )')$'\n'
    done ;;
  *) echo "public_gate: unknown mode $mode" >&2; exit 1 ;;
esac
[ -z "$added" ] && exit 0
h1=$(printf '%s\n' "$added" | grep -n -w -F -f "$P")
h2=$(printf '%s\n' "$added" | grep -n -E "$RX_HARD")
h3=$(printf '%s\n' "$added" | grep -o -E "$RX_IP" | sort -u | grep -v -x -F -f "$B")
if [ -n "$h1$h2$h3" ]; then
  {
    echo "BLOCK $(date '+%F %T') $mode $repo"
    [ -n "$h1" ] && printf 'names:\n%s\n' "$h1"
    [ -n "$h2" ] && printf 'ocid/key:\n%s\n' "$h2"
    [ -n "$h3" ] && printf 'new private IPs:\n%s\n' "$h3"
  } | tee -a "$L" | head -40 >&2
  echo "public_gate: BLOCKED. This is a PUBLIC repo and the change carries customer or private data (above). Remove it; synthetic data only. Do not bypass with --no-verify; post a RISK line on your board." >&2
  exit 1
fi
echo "PASS $(date '+%F %T') $mode $repo" >> "$L"
exit 0
