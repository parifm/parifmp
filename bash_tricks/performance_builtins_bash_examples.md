# Performance and builtins

### Time any command
```bash
bench() {
  local s=$EPOCHREALTIME
  "$@"
  local e=$EPOCHREALTIME
  awk -v s="$s" -v e="$e" 'BEGIN { printf "%.3fs\n", e - s }'
}
bench sleep 0.1
```

### Cost of command substitution
```bash
time for i in {1..300}; do x=$(echo hi); done
```

### Same loop with builtins
```bash
time for i in {1..300}; do x=hi; done
```

### Group in current shell
```bash
{ x=1; }
echo "$x"
```

### Group in subshell
```bash
( y=1 )
echo "${y:-unset}"
```

### Replace the shell process
```bash
bash -c 'exec echo replaced'
```

### Split without cut
```bash
IFS=: read -r a b _ <<< "x:y:z"
echo "$b"
```

### Read all of stdin
```bash
IFS= read -r -d '' all <<< $'one\ntwo'
echo "${#all}"
```

### Timestamp without date
```bash
printf -v now '%(%s)T' -1
echo "$now"
```
