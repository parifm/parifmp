#!/usr/bin/env bash
# Run a session's launch command in its pane and record the session's end.
# Usage: cos_sessrun.sh <session-name> <command...>    e.g.  cos_sessrun.sh myWkr claude --model … -n myWkr …
# When the command ends (exit, crash, closed pane or window) it removes <session-name> from cos_sessions and
# appends one line to cos_log.md. It writes to files only: after a closed pane there is no terminal.
# After a signal it waits WAIT seconds and looks in the session registry; a live session with that name means a
# restart in the pane (cos_respawn.sh), and the name stays.
# Why a wrapper and not "claude … && some-script": "&&" reports a clean exit only, never a closed pane.
# A session restarted by cos_respawn.sh or resumed by hand runs without this wrapper; mgr's tripwire reports its end.
n=${1:?usage: cos_sessrun.sh <session-name> <command...>}; shift
[ "$#" -gt 0 ] || { echo "usage: cos_sessrun.sh <session-name> <command...>" >&2; exit 2; }
[[ $n =~ ^[A-Za-z0-9]+$ ]] || { echo "cos_sessrun.sh: session name '$n' is not alphanumeric" >&2; exit 2; }
TR=${TEAM_ROOT:-$HOME/claude}
S=${COS_SESSIONS:-$TR/cos_sessions} L=${COS_LOG:-$TR/cos_log.md}
R=${COS_REG:-$HOME/.claude/sessions} WAIT=${COS_SESSRUN_WAIT:-10}
sig='' rc=''

name_live() {   # 0 when a registry entry with this name has a live pid
  local f p x
  for f in "$R"/*.json; do
    [ -f "$f" ] || continue
    p=$(jq -r --arg n "$n" 'select(.name == $n) | .pid // empty' "$f" 2>&1) || continue
    [[ $p =~ ^[0-9]+$ ]] || continue
    if x=$(kill -0 "$p" 2>&1); then return 0; fi
  done
  return 1
}

fin() {
  trap - EXIT
  trap '' HUP TERM INT   # the end steps run to completion
  local how what x i
  if [ -n "$sig" ]; then how="signal $sig, rc=${rc:-none}"; else how="exit rc=${rc:-none}"; fi
  if [ -n "$sig" ]; then
    sleep "$WAIT"
    if name_live; then
      printf '%s cos_sessrun: %s restarted in its pane (%s; the name is live in the registry). Kept in cos_sessions.\n' "$(date -u +%FT%H:%MZ)" "$n" "$how" >> "$L"
      return
    fi
  fi
  what="lock $S.lock busy for 20 s; NOT removed from cos_sessions"
  for ((i = 0; i < 40; i++)); do
    if x=$(mkdir "$S.lock" 2>&1); then
      if [ ! -f "$S" ]; then what="no file $S"
      elif ! /usr/bin/grep -q -x -F -- "$n" "$S"; then what="not in cos_sessions"
      elif x=$(awk -v n="$n" '$0 != n' "$S" > "$S.tmp.$$" && mv -- "$S.tmp.$$" "$S" 2>&1); then what="removed from cos_sessions"
      else what="cos_sessions NOT changed: $x"; fi
      x=$(rmdir "$S.lock" 2>&1)
      break
    fi
    sleep 0.5
  done
  printf '%s cos_sessrun: %s ended (%s); %s.\n' "$(date -u +%FT%H:%MZ)" "$n" "$how" "$what" >> "$L"
}

trap 'sig=HUP' HUP
trap 'sig=TERM' TERM
trap 'sig=INT' INT
trap fin EXIT
"$@"
rc=$?
exit "$rc"
