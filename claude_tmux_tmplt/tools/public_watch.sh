#!/usr/bin/env bash
# mgr's public-exposure watch: catches private or customer data that reached a public repo anyway. Polls the public
# repos' branch heads (PUBLIC_REPOS="owner/repo …", GitHub over ssh); on a change, scans the added lines of the new
# commits (and their messages) with the same lists as public_gate.sh. Exits, waking mgr, on a hit (PUBLIC HIT), or when
# git ls-remote or git fetch has failed FAILS times in a row for one repo (PUBLIC WATCH BLIND: no ssh key after a
# restart, no network). A failure is never read as "no change". Log times are UTC.
if (( BASH_VERSINFO[0] < 4 )); then echo "public_watch.sh needs bash 4+ (declare -A); run it with /opt/homebrew/bin/bash" >&2; exit 2; fi
D=${TEAM_ROOT:-$HOME/claude}/.cos_tripwire
M=$D/pubmirror
P=$D/public_patterns.txt          # customer and cluster names, case-sensitive whole words
B=$D/public_ip_baseline.txt       # private IPs already in the public trees (doc examples)
L=$D/public_watch.log
RX_IP='(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})'
RX_HARD='ocid1[.][a-z]+[.]|PRIVATE KEY-{5}|BEGIN OPEN[S]SH'   # written so the gate never matches its own source
REPOS=${PUBLIC_REPOS:?set PUBLIC_REPOS to the public repos to watch, e.g. "you/repo1 you/repo2"}
mkdir -p "$M"
for r in $REPOS; do
  g=$M/${r//\//__}.git
  [ -d "$g" ] || git clone -q --mirror "git@github.com:$r.git" "$g" >> "$L" 2>&1
done
FAILS=${FAILS:-3}   # ls-remote or fetch failures in a row, per repo, before the watch exits to say it is blind
heads() {   # $1 mirror: the remote's branch heads, sorted. On failure: prints git's error text and returns 1.
  local o
  if o=$(git -C "$1" ls-remote --heads origin 2>&1); then sort <<< "$o"; else printf '%s' "${o//$'\n'/ }"; return 1; fi
}
echo "public watch start $(date -u +%FT%TZ)" >> "$L"
declare -A last nf
for r in $REPOS; do g=$M/${r//\//__}.git; nf[$r]=0
  if ! last[$r]=$(heads "$g"); then
    # No answer from the remote at start: take the mirror's own heads as the baseline (same "sha<TAB>ref" form), so
    # the first good poll scans everything pushed since the mirror's last fetch.
    echo "$(date -u +%FT%TZ) $r ls-remote FAILED at start: ${last[$r]}" >> "$L"; nf[$r]=1
    last[$r]=$(git -C "$g" for-each-ref --format='%(objectname)%09%(refname)' refs/heads 2>&1 | sort)
  fi
done
failed() {   # $1 repo, $2 what failed, $3 error text: log it; after FAILS in a row exit, waking mgr, because the watch is blind
  nf[$1]=$(( ${nf[$1]} + 1 )); echo "$(date -u +%FT%TZ) $1 $2 FAILED (${nf[$1]} in a row): $3" >> "$L"
  (( ${nf[$1]} >= FAILS )) || return 0
  printf 'PUBLIC WATCH BLIND %s: git %s failed %d times in a row for %s, so new public commits are not scanned. Last error: %s\n' "$(date -u +%FT%TZ)" "$2" "${nf[$1]}" "$1" "${3:0:300}"; exit 0
}
while :; do
  for r in $REPOS; do
    g=$M/${r//\//__}.git
    # An error text is never compared with the heads: the same error at each poll would look like "no change".
    if ! now=$(heads "$g"); then failed "$r" ls-remote "$now"; continue; fi
    if [ "$now" = "${last[$r]}" ]; then
      (( ${nf[$r]} > 0 )) && { echo "$(date -u +%FT%TZ) $r works again" >> "$L"; nf[$r]=0; }
      continue
    fi
    old_shas=$(printf '%s\n' "${last[$r]}" | awk '{print $1}')
    # The baseline moves only after a good fetch, so commits that could not be fetched are scanned at the next poll.
    if ! out=$(git -C "$g" fetch -q --prune origin '+refs/heads/*:refs/heads/*' 2>&1); then failed "$r" fetch "${out//$'\n'/ }"; continue; fi
    (( ${nf[$r]} > 0 )) && { echo "$(date -u +%FT%TZ) $r works again" >> "$L"; nf[$r]=0; }
    hits=""
    while read -r sha ref; do
      [ -z "$sha" ] && continue
      excl=$(for o in $old_shas; do git -C "$g" cat-file -e "$o" 2>&1 | grep -q . || printf '^%s ' "$o"; done)
      added=$(git -C "$g" log --format='COMMIT %h %an <%ae> %s%n%b' -p $excl "$sha" -- 2>&1 | grep -E '^(\+[^+]|COMMIT )')
      [ -z "$added" ] && continue
      h1=$(printf '%s\n' "$added" | grep -n -w -F -f "$P")
      h2=$(printf '%s\n' "$added" | grep -n -E "$RX_HARD")
      h3=$(printf '%s\n' "$added" | grep -o -E "$RX_IP" | sort -u | grep -v -x -F -f "$B")
      [ -n "$h1$h2$h3" ] && hits+="== $r $ref -> ${sha:0:7}"$'\n'"${h1:+names:$'\n'$h1$'\n'}${h2:+ocid/key:$'\n'$h2$'\n'}${h3:+new private IPs:$'\n'$h3$'\n'}"
    done <<< "$now"
    echo "$(date -u +%FT%TZ) $r heads changed; hits=$([ -n "$hits" ] && echo yes || echo no)" >> "$L"
    last[$r]=$now
    if [ -n "$hits" ]; then printf 'PUBLIC HIT %s\n%s' "$(date -u +%FT%TZ)" "$hits" | head -60; exit 0; fi
  done
  sleep "${INTERVAL:-120}"
done
