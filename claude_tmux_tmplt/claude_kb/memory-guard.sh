#!/usr/bin/env bash
# PreToolUse guard (optional, with claude_kb/kb): memories live in db kb, so a write into Claude Code's memory
# folder for the team root (~/.claude/projects/<team root, non-alphanumerics as "-">/memory/) is refused, except
# the pointer MEMORY.md and anything under memory/arxiv/. Covers Write/Edit/MultiEdit/NotebookEdit by file_path
# and Bash commands that name the dir together with a writing form (>, >>, tee, cp, mv, rm, sed -i, touch, ln).
R=${TEAM_ROOT:-$HOME/claude}
KB=$R/claude_kb/kb
MEM=${KB_MEMDIR:-$HOME/.claude/projects/${R//[^A-Za-z0-9]/-}}/memory
in=$(cat)
tool=$(printf '%s' "$in" | jq -r '.tool_name // empty') || exit 0
allowed() {   # $1: path -> 0 when the path is the pointer or under arxiv/
  case "$1" in "$MEM"/MEMORY.md|"$MEM"/arxiv/*) return 0 ;; esac
  return 1
}
case "$tool" in
  Write|Edit|MultiEdit|NotebookEdit)
    p=$(printf '%s' "$in" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
    [ -n "$p" ] || exit 0
    p=${p/#\~/$HOME}
    case "$p" in "$MEM"/*) allowed "$p" && exit 0 ;; *) exit 0 ;; esac ;;
  Bash)
    cmd=$(printf '%s' "$in" | jq -r '.tool_input.command // empty')
    [ -n "$cmd" ] || exit 0
    # expand ~ and $HOME spellings of the dir to one form, then look for a path in memory/ that is not allowed
    c=$(printf '%s' "$cmd" | sed -e "s#~/.claude/projects#$HOME/.claude/projects#g" -e "s#\\\$HOME/.claude/projects#$HOME/.claude/projects#g" -e "s#\\\${HOME}/.claude/projects#$HOME/.claude/projects#g")
    printf '%s' "$c" | grep -q "$MEM/" || exit 0
    printf '%s' "$c" | grep -Eq '(^|[^A-Za-z0-9_])(tee|cp|mv|rm|touch|ln|truncate|install)([^A-Za-z0-9_]|$)|>>?|sed[[:space:]]+(-[A-Za-z]*i|--in-place)' || exit 0
    hit=0
    while read -r p; do allowed "$p" || hit=1; done < <(printf '%s' "$c" | grep -oE "$MEM/[^[:space:]'\";|&)>]*")
    [ $hit -eq 1 ] || exit 0 ;;
  *) exit 0 ;;
esac
short="memory-guard: memories live in db kb, not in memory/*.md"
reason="$short. Save with $KB add <stem> <type> (body on stdin) or kb edit <stem>; recall with kb search, kb ask, kb show. Only MEMORY.md (the pointer) and memory/arxiv/ may be written here."
jq -nc --arg r "$reason" --arg s "$short" '{systemMessage:$s,hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
printf '%s deny %s %s\n' "$(date -u +%FT%TZ)" "$tool" "${p:-${cmd:0:100}}" >> "$HOME/.claude/hooks/memory-guard.log"
