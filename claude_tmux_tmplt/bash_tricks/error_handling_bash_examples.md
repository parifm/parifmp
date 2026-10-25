# Error handling

### Strict mode
```bash
( set -euo pipefail; echo ok )
```

### Tab and newline word splitting
```bash
IFS=$'\n\t'
printf '%s' "$IFS" | od -c | head -n 1
```
Caution: tab is IFS whitespace, so `IFS=$'\t' read` collapses empty fields and shifts the rest left. See `our_bugs_bash_examples.md`.

### Cleanup on exit
```bash
tmp=$(mktemp -d)
trap 'rm -r -- "${tmp:?}"' EXIT
touch "$tmp/work"
echo "cleanup scheduled for $tmp"
```

### Report exit status
```bash
( trap 'echo "exit status was $?"' EXIT; exit 3 )
echo "subshell returned $?"
```

### Cleanup keeps exit code
```bash
cleanup() { local rc=$?; echo "cleaning up"; exit "$rc"; }
( trap cleanup EXIT; exit 5 )
echo "got $?"
```

### Error trap with line number
```bash
( set -eE; trap 'echo "failed at line $LINENO"' ERR; false ) || echo "subshell failed"
```

### Run on function return
```bash
f() { trap 'echo leaving' RETURN; echo inside; }
f
```

### Signal handler
```bash
trap 'echo interrupted; exit 130' INT TERM
trap -p INT
```

### One handler for several events
```bash
trap 'echo bye' EXIT INT TERM
trap - EXIT INT TERM
```

### Ignore a signal
```bash
trap '' HUP
trap -p HUP
```

### Step trace
```bash
trap 'echo "about to run: $BASH_COMMAND"' DEBUG
true
trap - DEBUG
```

### Stack frame
```bash
f() { caller 0; }
f
```

### Die helper
```bash
die() { printf '%s\n' "$*" >&2; exit 1; }
( die "boom" ) || echo "died"
```

### Require a command
```bash
need() { local p; p=$(command -v "$1") || { echo "missing: $1" >&2; return 1; }; }
need bash && echo ok
```

### Retry
```bash
retry() {
  local tries=$1 n=0
  shift
  until "$@"; do
    (( ++n >= tries )) && return 1
    sleep 0.1
  done
}
retry 3 false || echo gave up
```

### Tolerate a failure
```bash
( set -e; false || true; echo continued )
```

### Handle a failure explicitly
```bash
( set -e; if ! false; then echo handled; fi )
```

### Capture status
```bash
out=$(sh -c 'echo partial; exit 4')
rc=$?
echo "$rc $out"
```

### Unset variable fallback
```bash
( set -u; echo "${undefined:-fallback}" )
```

### Assertion
```bash
assert() { [[ $1 == "$2" ]] || { echo "assert failed: '$1' != '$2'" >&2; return 1; }; }
assert 4 4 && echo passed
```

### Lock with a file
```bash
( set -C; echo $$ > lock.pid ) && echo acquired
( set -C; echo $$ > lock.pid ) || echo busy
```

### Lock with a directory
```bash
mkdir lock.d && echo acquired
mkdir lock.d || echo busy
```

### Background job status
```bash
sh -c 'exit 5' &
wait $!
echo $?
```

### Function status
```bash
f() { return 3; }
f
echo $?
```

### Named exit codes
```bash
readonly EX_USAGE=64
( exit "$EX_USAGE" )
echo $?
```

### Kill children on exit
```bash
trap 'for p in $(jobs -p); do kill "$p"; done' EXIT
sleep 30 &
echo started
```
