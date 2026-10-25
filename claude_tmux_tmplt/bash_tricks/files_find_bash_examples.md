# Files and find

### Find by name
```bash
mkdir d
touch d/a.txt d/b.log
find d -name '*.txt'
```

### Find by type
```bash
mkdir d
touch f
find . -maxdepth 1 -type d
```

### Find newer than a file
```bash
touch ref
sleep 1
touch newer
find . -type f -newer ref
```

### Find by size
```bash
echo data > small
find . -type f -size -1k
```

### Find empty files
```bash
touch empty
echo x > full
find . -type f -empty
```

### Find by age
```bash
touch f
find . -type f -mtime -1
```

### Batch with exec plus
```bash
printf 'a\nb\n' > f.txt
find . -name '*.txt' -exec wc -l {} +
```

### One at a time with exec
```bash
touch a b
find . -type f -exec sh -c 'echo "file: $1"' sh {} \;
```

### Loop inside exec
```bash
touch a b
find . -type f -exec bash -c 'for f do echo "got $f"; done' bash {} +
```

### Prune a directory
```bash
mkdir -p skip keep
touch skip/a keep/b
find . -path ./skip -prune -o -type f -print
```

### Delete matches
```bash
touch a.tmp b.tmp keep
find . -name '*.tmp' -delete
ls
```

### Null-delimited handoff
```bash
touch 'a b' c
find . -type f -print0 | xargs -0 -n 1 echo
```

### Read null-delimited names
```bash
touch 'a b' c
find . -type f -print0 | while IFS= read -r -d '' f; do
  echo "$f"
done
```

### Null-delimited sort
```bash
printf 'b\0a\0' | sort -z | tr '\0' '\n'
```

### Count by extension
```bash
touch a.txt b.txt c.log
find . -type f | sed 's/.*\.//' | sort | uniq -c | sort -rn
```

### Largest files
```bash
head -c 100000 /dev/zero > big
echo x > small
find . -type f -exec du -k {} + | sort -rn | head -n 1
```

### Disk usage by entry
```bash
mkdir a b
head -c 50000 /dev/zero > a/f
du -sk ./* | sort -rn | head -n 3
```

### Files by size
```bash
head -c 5000 /dev/zero > big
echo x > small
ls -lhS | head -n 3
```

### Newest file
```bash
touch -t 202001010000 old
touch new
ls -t | head -n 1
```

### Hidden files
```bash
touch .a .b visible
ls -d .[!.]*
```

### Show hidden characters
```bash
printf 'a\tb \n' | cat -et
```

### Read file into variable
```bash
echo hello > f
content=$(< f)
echo "$content"
```

### Read lines
```bash
printf 'a\nb\n' > f
while IFS= read -r line; do
  echo "[$line]"
done < f
```

### Slurp whole file
```bash
printf 'a\nb\n' > f
IFS= read -r -d '' all < f
echo "${#all}"
```

### First bytes
```bash
printf 'abcdef' > f
head -c 3 f
```

### Temporary file
```bash
tmp=$(mktemp)
echo hi > "$tmp"
cat "$tmp"
rm -- "$tmp"
```

### Temporary directory
```bash
d=$(mktemp -d)
touch "$d/x"
ls "$d"
rm -r -- "${d:?}"
```

### Compare files
```bash
echo a > f1
echo a > f2
cmp -s f1 f2 && echo same
```

### Unified diff
```bash
printf 'a\nb\n' > f1
printf 'a\nc\n' > f2
diff -u f1 f2
```

### Sort in place
```bash
printf 'b\na\nb\n' > f
sort -u -o f f
cat f
```

### Edit with backup
```bash
echo v1 > f
cp f f.bak
sed -i.orig 's/v1/v2/' f
cat f f.orig f.bak
```

### Stream copy
```bash
mkdir src dst
echo data > src/f
tar cf - -C src . | tar xf - -C dst
ls dst
```

### Compress and read
```bash
echo hello > f
gzip -c f > f.gz
zcat f.gz
```

### Physical path
```bash
mkdir real
ln -s real link
cd -P link
pwd
```

### Absolute path
```bash
mkdir d
readlink -f d
```

### Directory stack
```bash
mkdir a
pushd a >&2   # the stack goes to stderr instead of being thrown away
pwd
popd >&2
pwd
```

### Locate a command
```bash
type -P bash
```

### Private file
```bash
umask 077
touch private
ls -l private
```
