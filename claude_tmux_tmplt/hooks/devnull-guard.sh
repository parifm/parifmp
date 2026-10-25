#!/opt/homebrew/bin/bash
# PreToolUse guard: output sent to /dev/null is refused,
# in a Bash command or in code written by Write, Edit, MultiEdit or
# NotebookEdit. Prose (.md, .markdown, .txt) passes, and so does a mention
# (comment line, `quoted` token). Only NEW text counts; input from /dev/null
# is fine. The prompt quotes the match. See house_rules.md.
in=$(cat)
# \x1f, not a tab: read collapses adjacent tabs, so an empty file path would shift agent_type
IFS=$'\x1f' read -r tool fp agent < <(printf '%s' "$in" |
    jq -r '[.tool_name // "?", .tool_input.file_path // .tool_input.notebook_path // "", .agent_type // ""] | join("\u001f")')
# every caller is refused with how to fix it; the owner sees the reason as a
# systemMessage (deny, but show the denial)
decision=deny
case "$fp" in *.md|*.markdown|*.txt) exit 0 ;; esac
text=$(printf '%s' "$in" | jq -r '.tool_input | (.command // empty), (.content // empty),
    (.new_string // empty), (.edits[]?.new_string // empty), (.new_source // empty)') || exit 0
re='([0-9]*|&)>>?[[:space:]]*/dev/null|>&[[:space:]]*/dev/null|(^|[[:space:]])(-o|--output)[=[:space:]]+/dev/null'
# a mention is not a redirect: drop comment lines and a
# redirect written as a `quoted` or "quoted" token, e.g. Never `2>/dev/null`
text=$(printf '%s\n' "$text" | sed -E -e '/^[[:space:]]*#/d' \
    -e 's/`(([0-9]*|&)>>?|>&)[[:space:]]*\/dev\/null[^`]*`//g' \
    -e 's/"(([0-9]*|&)>>?|>&)[[:space:]]*\/dev\/null[^"]*"//g' \
    -e "s/'(([0-9]*|&)>>?|>&)[[:space:]]*\/dev\/null[^']*'//g")
# each match with up to 40 characters before it and 20 after, one per line
hits=$(printf '%s' "$text" | grep -Eo ".{0,40}($re).{0,20}"); rc=$?
[ "$rc" -ne 1 ] || exit 0
where=${fp##*/}; where=${where:-the command}
if [ "$rc" -ne 0 ]; then
    # a guard that cannot look must not pass silently
    reason="devnull-guard could not check $where (grep exit $rc)"
else
    hit=${hits%%$'\n'*}; hit=${hit#"${hit%%[![:space:]]*}"}
    more=${hits//[!$'\n']/}
    reason="devnull-guard: output to /dev/null in $where: \"$hit\""
    [ ${#more} -eq 0 ] || reason="$reason (+${#more} more)"
fi
short=$reason; reason="$reason. Never send output to /dev/null (>/dev/null, 2>/dev/null, &>/dev/null): capture it in a variable or a file under your working folder and show it on failure; for a quiet test use the exit status (grep -q, jq -e . file, test -s). Rewrite the command."
jq -nc --arg r "$reason" --arg s "$short" --arg d "$decision" '{systemMessage:$s,hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
# an audit line per decision: how often the guard fires, and on what
printf '%s %s %s%s %s\n' "$(date '+%F %T')" "$decision" "$tool" "${agent:+ ($agent)}" "$short" >> "$HOME/.claude/hooks/devnull-guard.log"
exit 0
