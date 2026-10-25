# Redirection and pipes

### Stdout and stderr to file
```bash
{ echo out; echo err >&2; } > both.txt 2>&1
cat both.txt
```

### Combined shorthand
```bash
{ echo out; echo err >&2; } &> both.txt
cat both.txt
```

### Append
```bash
echo a >> log.txt
echo b >> log.txt
cat log.txt
```

### Stderr to file
```bash
{ echo oops >&2; } 2> err.txt
cat err.txt
```

### Stderr into a pipe
```bash
{ echo oops >&2; } 2>&1 | grep -c oops
```

### Pipe both streams
```bash
{ echo out; echo err >&2; } |& tr a-z A-Z
```

### Swap stdout and stderr
```bash
{ echo out; echo err >&2; } 3>&1 1>&2 2>&3 | sed 's/^/was stderr: /'
```

### Keep stdout out of the way without discarding it
```bash
out=$(echo hidden)   # captured; print or test it later
[ -n "$out" ] && echo "captured ${#out} chars"
```

### Write to stderr
```bash
echo problem >&2
```

### Redirect a block
```bash
{ echo a; echo b; } > out.txt
cat out.txt
```

### Redirect a loop
```bash
for i in 1 2 3; do echo "$i"; done > nums.txt
cat nums.txt
```

### Input from file
```bash
printf 'a\nb\n' > f
wc -l < f
```

### Here-document
```bash
name=world
cat <<EOF
hello $name
EOF
```

### Quoted here-document
```bash
cat <<'EOF'
no $expansion here
EOF
```

### Indented here-document
```bash
cat <<-EOF
	indented with a tab
	EOF
```

### Here-document to file
```bash
cat > conf.txt <<'EOF'
key=value
EOF
cat conf.txt
```

### Here-document into command
```bash
sort <<EOF
b
a
EOF
```

### Here-string
```bash
grep -c a <<< "banana"
```

### Input process substitution
```bash
diff <(printf 'a\nb\n') <(printf 'a\nc\n')
```

### Output process substitution
```bash
echo hello > >(tr a-z A-Z)
```

### Run a remote script
```bash
bash <(curl -fsSL https://example.com/install.sh)
```

### Sorted intersection
```bash
comm -12 <(printf 'a\nb\n' | sort) <(printf 'b\nc\n' | sort)
```

### Loop without subshell
```bash
total=0
while read -r n; do
  (( total += n ))
done < <(seq 5)
echo "$total"
```

### Last pipe stage in shell
```bash
shopt -s lastpipe
total=0
seq 5 | while read -r n; do (( total += n )); done
echo "$total"
```

### Open file for reading
```bash
printf 'first\nsecond\n' > f
exec 3< f
read -r line <&3
echo "$line"
exec 3<&-
```

### Open file for writing
```bash
exec 4> out.txt
echo hi >&4
exec 4>&-
cat out.txt
```

### Open for read and write
```bash
exec 5<> rw.txt
echo data >&5
exec 5>&-
cat rw.txt
```

### Named descriptor
```bash
exec {fd}> out.txt
echo hi >&$fd
exec {fd}>&-
cat out.txt
```

### Save and restore stdout
```bash
exec 6>&1
exec > captured.txt
echo hidden
exec 1>&6 6>&-
echo shown
cat captured.txt
```

### Log to file and screen
```bash
exec > >(tee -a run.log) 2>&1
echo logged
```

### Tee to several files
```bash
echo hi | tee a.txt > b.txt
cat a.txt b.txt
```

### Tee append
```bash
echo one > a.txt
echo two | tee -a a.txt
cat a.txt
```

### Named pipe
```bash
mkfifo p
( echo hello > p ) &
cat p
wait
rm p
```

### Coprocess
```bash
coproc echoer { cat; }
echo ping >&"${echoer[1]}"
read -r reply <&"${echoer[0]}"
echo "$reply"
kill "$echoer_PID"
```

### Refuse to overwrite
```bash
set -o noclobber
echo a > f
echo b > f || echo refused
echo c >| f
cat f
```

### Pipeline exit codes
```bash
false | true
echo "${PIPESTATUS[@]}"
```

### Fail on any stage
```bash
set -o pipefail
false | true
echo $?
```

### Subshell redirect
```bash
( cd /tmp && pwd ) > where.txt
cat where.txt
```

### Capture and copy
```bash
out=$(printf 'x\ny\n' | tee copy.txt)
echo "$out"
```
