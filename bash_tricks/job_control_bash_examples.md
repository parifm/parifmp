# Job control

### Background and wait
```bash
sleep 0.2 &
wait
echo done
```

### Background PID
```bash
sleep 0.2 &
pid=$!
wait "$pid"
echo "exited $?"
```

### Wait for first job
```bash
sleep 0.3 &
sleep 0.1 &
wait -n
echo first-done
wait
```

### Bounded worker pool
```bash
for i in 1 2 3 4 5 6; do
  ( sleep "0.$((RANDOM % 3 + 1))"; echo "job $i" ) &
  while (( $(jobs -rp | wc -l) >= 3 )); do wait -n; done
done
wait
```

### Collect exit codes
```bash
pids=()
for c in 0 1 2; do
  ( exit "$c" ) &
  pids+=($!)
done
for p in "${pids[@]}"; do
  wait "$p"
  echo "status $?"
done
```

### Fan out via process substitution, fan in by file descriptor
```bash
declare -a fd
i=0
for n in a b c; do
  exec {fd[++i]}< <( sleep "0.$RANDOM"; echo "$n done" )
done
for f in "${fd[@]}"; do cat <&"$f"; exec {f}<&-; done
```

### Run a list in parallel
```bash
for f in a b c; do
  ( echo "$f" ) &
done
wait
```

### Background group
```bash
{ sleep 0.1; echo grouped; } &
wait
```

### Capture background output
```bash
( sleep 0.1; echo result ) > out.txt &
wait
cat out.txt
```

### Job table
```bash
sleep 1 &
jobs -l
kill %1
wait
```

### Wait by job spec
```bash
sleep 0.1 &
wait %1
```

### Detach from shell
```bash
sleep 1 &
disown
echo detached
```

### Survive logout
```bash
nohup sleep 1 > nohup.out 2>&1 &
echo started
```

### Stop a background job
```bash
sleep 30 &
pid=$!
kill "$pid"
wait "$pid"
echo $?
```

### Subshell process ID
```bash
( echo "$$ $BASHPID" )
```

### Parallel with xargs
```bash
printf '%s\n' 1 2 3 4 | xargs -P 2 -n 1 echo
```

### Placeholder in xargs
```bash
printf '%s\n' a b | xargs -I{} echo item-{}
```

### Null-delimited xargs
```bash
printf 'a b\0c\0' | xargs -0 -n 1 echo
```

### Shell per item
```bash
printf '%s\n' 'a b' c | xargs -I{} sh -c 'echo "item: $1"' _ {}
```

### Export function to xargs
```bash
show() { echo "got $1"; }
export -f show
printf '%s\n' a b | xargs -I{} bash -c 'show {}'
```

### Parallel compression
```bash
touch a.log b.log
find . -name '*.log' | xargs -P 2 -I{} gzip {}
ls
```

### GNU parallel
```bash
seq 3 | parallel echo job-{}
```

### Single instance with flock
```bash
exec 200> my.lock
flock -n 200 || { echo "already running"; exit 1; }
echo "lock held"
```

### Time limit
```bash
timeout 1 sleep 3
echo $?
```

### Read with timeout
```bash
read -t 0.2 -r answer < <(sleep 1) || echo "no input within 0.2 s"
```
