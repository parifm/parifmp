#!/opt/homebrew/bin/bash
# Install the team kit into $TEAM_ROOT (default ~/claude) and its hooks into ~/.claude/hooks.
# macOS + Homebrew only (see README "Platform"). Usage: ./install.sh [--go]
# Without --go it only prints the plan. It never overwrites an existing file and never edits
# ~/.claude/settings.json: it prints the hooks block for you to merge.
set -u
go=; [ "${1:-}" = --go ] && go=1
[ $# -le 1 ] && { [ $# -eq 0 ] || [ -n "$go" ]; } || { echo "usage: ./install.sh [--go]"; exit 2; }

# Platform gate: these scripts use bash 5 at /opt/homebrew/bin/bash and BSD date/stat flags.
if [ "$(uname -s)" != Darwin ]; then
  echo "REFUSED: this kit runs on macOS only (found $(uname -s)). Its scripts use macOS (BSD) date/stat flags; see README \"Platform\"."; exit 1
fi
if [ ! -x /opt/homebrew/bin/bash ] || ! /opt/homebrew/bin/bash -c '(( BASH_VERSINFO[0] >= 5 ))'; then
  echo "REFUSED: needs Homebrew's bash 5 at /opt/homebrew/bin/bash (macOS /bin/bash is 3.2). Install it: brew install bash"; exit 1
fi
miss=
for c in tmux jq claude gtimeout shasum; do p=$(command -v "$c") || miss+=" $c"; done
[ -n "$miss" ] && { echo "REFUSED: missing commands:$miss  (brew install tmux jq coreutils; Claude Code for claude)"; exit 1; }

K=$(cd "$(dirname "$0")" && pwd)
R=${TEAM_ROOT:-$HOME/claude}
H=$HOME/.claude/hooks
run() { if [ -n "$go" ]; then "$@" || { echo "FAILED: $*"; exit 1; }; else printf '  would run:'; printf ' %q' "$@"; echo; fi; }

kept=0 added=0
put() {   # $1 source file, $2 destination path: copy only if the destination doesn't exist (macOS cp -n exits 1 on a skip)
  if [ -e "$2" ]; then kept=$((kept + 1)); return; fi
  run mkdir -p "${2%/*}"; run cp -p "$1" "$2"; added=$((added + 1))
}
tree() {   # $1 source dir, $2 destination dir
  local f
  while IFS= read -r -d '' f; do put "$f" "$2/${f#"$1"/}"; done < <(find "$1" -type f ! -name test.log -print0)
}

echo "Kit: $K"; echo "Team root: $R"; echo "Hooks: $H"; [ -z "$go" ] && echo "DRY RUN: add --go to install"
run mkdir -p "$R/.cos_tripwire" "$R/restore/history" "$R/.oversight" "$H"
tree "$K/tools" "$R/tools"
tree "$K/oversight_plugin" "$R/tools/oversight_plugin"
tree "$K/personas" "$R/personas"
tree "$K/bash_tricks" "$R/bash_tricks"
tree "$K/templates" "$R"
put "$K/house_rules.md" "$R/house_rules.md"
tree "$K/hooks" "$H"
echo "  files: $added new, $kept kept (existing files are never overwritten)"
run chmod +x "$R"/tools/*.sh "$H"/risk-log.sh "$H"/heredoc-guard.sh "$H"/devnull-guard.sh "$H"/heredoc-guard-tests/run.sh

# Every session launches with --settings tools/oversight_plugin/settings.json: it loads the plugin and passes TEAM_ROOT.
S=$R/tools/oversight_plugin/settings.json
if [ -e "$S" ]; then echo "  keep: $S exists"
elif [ -n "$go" ]; then jq -n --arg p "$R/tools/oversight_plugin" --arg r "$R" '{env: {CLAUDE_CODE_PLUGIN_DIRS: $p, TEAM_ROOT: $r}}' > "$S"; echo "  wrote $S"
else echo "  would write $S"; fi

cat <<HOOKS

Next 1: merge this "hooks" block into ~/.claude/settings.json (global; every session):
$(jq -n --arg h "$H" '{hooks: {PreToolUse: [
  {matcher: "Bash|mcp__.*", hooks: [{type: "command", command: "\($h)/risk-log.sh"}]},
  {matcher: "Bash", hooks: [{type: "command", command: "\($h)/heredoc-guard.sh"}]},
  {matcher: "Bash|Write|Edit|MultiEdit|NotebookEdit", hooks: [{type: "command", command: "\($h)/devnull-guard.sh"}]}]}}')
Next 2: replace <OWNER> and <OWNER_ROLE_ONE_LINE> in $R/personas/cos.md and mgr.md, and review $R/house_rules.md.
Next 3: test the hooks: $H/heredoc-guard-tests/run.sh
Next 4: start the team: $K/start_team.sh
HOOKS
