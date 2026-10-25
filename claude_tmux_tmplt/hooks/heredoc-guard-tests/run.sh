#!/opt/homebrew/bin/bash
# Feeds each fixture to heredoc-guard.sh and checks the outcome named by its file name:
#   deny-<rules>-*.json  denied, and the reason lists exactly those rules (e.g. deny-abd-)
#   pass-*.json          no output at all
#   err-*.json           allowed with a systemMessage that says the guard could not check
# The guard logs to a scratch file here, not to the live heredoc-guard.log.
here=$(cd "$(dirname "$0")" && pwd)
hook=$here/../heredoc-guard.sh
export HEREDOC_GUARD_LOG=$here/test.log
: > "$HEREDOC_GUARD_LOG"
pass=0 fail=0
for f in "$here"/*.json; do
    name=${f##*/}; name=${name%.json}
    out=$("$hook" < "$f"); rc=$?
    dec=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>&1)
    case $name in
    deny-*)
        want=${name#deny-}; want=${want%%-*}
        want=$(printf '%s' "$want" | fold -w1 | sort -u | paste -sd, -)
        got=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' | sed -nE 's/^heredoc-guard \(rule ([a-e,]+)\).*/\1/p')
        if [ "$rc" -eq 0 ] && [ "$dec" = deny ] && [ "$got" = "$want" ]; then ok=1; else ok=0; fi
        detail="decision=${dec:-none} rules=${got:-none} want=$want" ;;
    pass-*)
        if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok=1; else ok=0; fi
        detail="output=${out:-none}" ;;
    err-*)
        msg=$(printf '%s' "$out" | jq -r '.systemMessage // ""' 2>&1)
        if [ "$rc" -eq 0 ] && [ -z "$dec" ] && [[ $msg == *"could not check"* ]]; then ok=1; else ok=0; fi
        detail="decision=${dec:-none} systemMessage=${msg:-none}" ;;
    *) ok=0; detail="unknown fixture prefix" ;;
    esac
    if (( ok )); then pass=$((pass+1)); printf 'PASS %-40s %s\n' "$name" "$detail"
    else fail=$((fail+1)); printf 'FAIL %-40s %s rc=%s\n' "$name" "$detail" "$rc"; fi
done
# speed: a 150 KB single-line command (quotes, $(...), rm) must finish in under 5 s;
# this hook runs on every Bash call, and bash substrings/extglob trims went quadratic
long=$(printf 'echo "a$(x) b"; rm -rf ./a; %.0s' $(seq 5000))
t0=$EPOCHREALTIME
out=$(jq -nc --arg c "$long" '{tool_name:"Bash",tool_input:{command:$c}}' | "$hook"); rc=$?
ms=$(( (${EPOCHREALTIME/./} - ${t0/./}) / 1000 ))
if [ "$rc" -eq 0 ] && [ -z "$out" ] && (( ms < 5000 )); then pass=$((pass+1)); printf 'PASS %-40s %s\n' perf-150KB-line "${ms} ms, ${#long} chars"
else fail=$((fail+1)); printf 'FAIL %-40s %s\n' perf-150KB-line "${ms} ms rc=$rc output=${out:0:80}"; fi
printf '%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
