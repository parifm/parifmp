#!/usr/bin/env bash
# Print the UTC stamp and text of the owner's last typed record in a session's transcript, so a go is quoted with the
# transcript's own UTC time and never with a local time converted by hand.
# Usage: owner_said.sh <session-name> [regex] [count]
# Reads typed user messages and queued (mid-turn) commands; peer messages, wakes and tool results are skipped.
# The transcript's first typed record is the launch prompt (cos's brief, not the owner's words) and is skipped too.
# A brief pasted into a pane by tmux looks typed and can't be told apart: check any go against the pane.
n=${1:?session name} rx=${2:-.} k=${3:-1}
f=$(grep -l "\"name\":\"$n\"" "$HOME"/.claude/sessions/*.json 2>&1 | grep '\.json$' | head -1)
[ -n "$f" ] || { echo "$n: no registry entry" >&2; exit 1; }
sid=$(jq -r .sessionId "$f")
# Claude Code keeps a transcript under the launch folder's path, with each non-alphanumeric character as "-".
t=$HOME/.claude/projects/$(jq -r '.cwd // ""' "$f" | sed 's/[^a-zA-Z0-9]/-/g')/$sid.jsonl
[ -f "$t" ] || { echo "$n: no transcript $t" >&2; exit 1; }
first=$(jq -r 'select(.type=="user" and (.message.content|type)=="string" and .promptSource=="typed") | .uuid' "$t" | head -1)
jq -r --arg rx "$rx" --arg first "$first" '
  select(.uuid != $first)
  | ( if .type=="user" and (.message.content|type)=="string" then .message.content
    elif .attachment.type?=="queued_command" then (.attachment.prompt|tostring)
    else empty end ) as $m
  | select($m|test("^(Another Claude session sent a message|This session is being continued|<(cross-session-message|task-notification|system-reminder|local-command|command-))")|not)
  | select($m|test($rx; "i"))
  | .timestamp + "  " + ($m|gsub("\n";" ")|.[0:200])' "$t" | tail -n "$k"
