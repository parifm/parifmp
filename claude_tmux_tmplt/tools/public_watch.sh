#!/usr/bin/env bash
# mgr's public-exposure watch: catches private or customer data that reached a public repo anyway. Polls the public
# repos' branch heads (PUBLIC_REPOS="owner/repo …", GitHub over ssh); on a change, scans the added lines of the new
# commits (and their messages) with the same lists as public_gate.sh. Exits, waking mgr, only on a hit.
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
heads() { git -C "$1" ls-remote --heads origin 2>&1 | sort; }
echo "public watch start $(date +%T)" >> "$L"
declare -A last
for r in $REPOS; do g=$M/${r//\//__}.git; last[$r]=$(heads "$g"); done
while :; do
  for r in $REPOS; do
    g=$M/${r//\//__}.git
    now=$(heads "$g")
    [ "$now" = "${last[$r]}" ] && continue
    old_shas=$(printf '%s\n' "${last[$r]}" | awk '{print $1}')
    git -C "$g" fetch -q --prune origin '+refs/heads/*:refs/heads/*' >> "$L" 2>&1
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
    echo "$(date +%T) $r heads changed; hits=$([ -n "$hits" ] && echo yes || echo no)" >> "$L"
    last[$r]=$now
    if [ -n "$hits" ]; then printf 'PUBLIC HIT %s\n%s' "$(date +%T)" "$hits" | head -60; exit 0; fi
  done
  sleep 120
done
