# Debugging and testing

### Trace commands
```bash
set -x
echo traced
set +x
```

### Informative trace prefix
```bash
PS4='+ ${BASH_SOURCE##*/}:${LINENO}: ${FUNCNAME[0]:-main}() '
set -x
true
set +x
```

### Trace timestamps
```bash
PS4='+ $EPOCHREALTIME '
set -x
true
set +x
```

### Trace to a file
```bash
exec 19> trace.log
BASH_XTRACEFD=19
set -x
echo traced
set +x
cat trace.log
```

### Trace on demand
```bash
[[ ${DEBUG:-0} == 1 ]] && set -x
echo maybe traced
```

### Echo input lines
```bash
set -v
echo shown
set +v
```

### Syntax check only
```bash
printf 'echo ok\nif true; then\n' > bad.sh
bash -n bad.sh || echo "syntax error found"
```

### Show variables
```bash
x=1
arr=(a b)
declare -p x arr
```

### Subshell depth
```bash
echo "$BASH_SUBSHELL"
( echo "$BASH_SUBSHELL" )
```

### Call stack
```bash
inner() { printf '%s\n' "${FUNCNAME[@]}"; }
outer() { inner; }
outer
```

### Dry-run wrapper
```bash
run() {
  if [[ ${DRY_RUN:-0} == 1 ]]; then
    printf 'would run:'
    printf ' %q' "$@"
    echo
  else
    "$@"
  fi
}
DRY_RUN=1 run ls -l /tmp
```

### Log helper
```bash
log() { printf '[%s] %s\n' "$(date +%T)" "$*" >&2; }
log starting
```

### Step through
```bash
trap 'echo "line $LINENO: $BASH_COMMAND"' DEBUG
a=1
b=2
trap - DEBUG
```

### Elapsed seconds
```bash
SECONDS=0
sleep 1
echo "took ${SECONDS}s"
```

### High-resolution timing
```bash
start=$EPOCHREALTIME
sleep 0.1
end=$EPOCHREALTIME
awk -v s="$start" -v e="$end" 'BEGIN { printf "%.2f\n", e - s }'
```

### Check bash version
```bash
(( BASH_VERSINFO[0] >= 4 )) || echo "old bash"
echo "$BASH_VERSION"
```

### Assertion helper
```bash
assert_eq() {
  [[ $1 == "$2" ]] || { echo "FAIL: '$1' != '$2'"; return 1; }
  echo ok
}
assert_eq "$(echo hi)" hi
```

### Mock a command
```bash
curl() { echo "mocked: $*"; }
curl -s http://example.com
```

### Stub for child shells
```bash
git() { echo "stub git $*"; }
export -f git
bash -c 'git status'
```

### Bats test
```bash
@test "addition" {
  result=$(( 2 + 2 ))
  [ "$result" -eq 4 ]
}
```

### shunit2 test
```bash
testEquality() {
  assertEquals 1 1
}
. shunit2
```

### Static analysis
```bash
shellcheck -s bash script.sh
```

### Run with tracing
```bash
bash -x script.sh
```
