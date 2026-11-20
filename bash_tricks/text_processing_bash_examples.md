# Text processing

### Word frequency
```bash
printf 'the cat and the dog and the bird\n' | tr -cs A-Za-z '\n' | tr A-Z a-z | sort | uniq -c | sort -rn | sed 3q
```

### Count unique lines
```bash
printf 'a\nb\na\n' | sort | uniq -c | sort -rn
```

### Duplicates only
```bash
printf 'a\na\nb\n' | uniq -d
```

### Top value in a column
```bash
printf '1.1.1.1 x\n2.2.2.2 y\n1.1.1.1 z\n' | awk '{print $1}' | sort | uniq -c | sort -rn | head -n 1
```

### Print a column
```bash
echo 'a b c' | awk '{print $2}'
```

### Last column
```bash
echo 'a b c' | awk '{print $NF}'
```

### Custom separator
```bash
echo 'a,b,c' | awk -F, '{print $3}'
```

### Sum a column
```bash
printf '1\n2\n3\n' | awk '{s += $1} END {print s}'
```

### Average
```bash
printf '2\n4\n6\n' | awk '{s += $1} END {print s / NR}'
```

### Group totals
```bash
printf 'a 1\nb 2\na 3\n' | awk '{t[$1] += $2} END {for (k in t) print k, t[k]}'
```

### Match with line numbers
```bash
printf 'ok\nerror x\n' | awk '/error/ {print NR": "$0}'
```

### Numeric filter
```bash
printf '1\n5\n9\n' | awk '$1 > 4'
```

### Long lines
```bash
printf 'ab\nabcd\n' | awk 'length > 3'
```

### Drop duplicate lines
```bash
printf 'a\nb\na\n' | awk '!seen[$0]++'
```

### Line range
```bash
seq 10 | awk 'NR >= 3 && NR <= 5'
```

### Every other line
```bash
seq 6 | awk 'NR % 2'
```

### Substitute and print
```bash
echo hello | awk '{sub(/l+/, "L")} 1'
```

### Aligned output
```bash
printf 'a 1\nbb 22\n' | awk '{printf "%-5s %3d\n", $1, $2}'
```

### Pass a variable
```bash
awk -v n=2 '{print $n}' <<< 'a b c'
```

### Reverse fields
```bash
echo 'a b c' | awk '{for (i = NF; i > 0; i--) printf "%s%s", $i, (i > 1 ? " " : "\n")}'
```

### Join two files by key
```bash
printf 'a 1\nb 2\n' > f1
printf 'a x\nc y\n' > f2
awk 'NR == FNR {m[$1] = $2; next} $1 in m {print $1, m[$1], $2}' f1 f2
```

### Substitute
```bash
echo 'a-b' | sed 's/-/_/'
```

### Substitute everywhere
```bash
echo 'a-b-c' | sed 's/-/_/g'
```

### Capture groups
```bash
echo 'ab12' | sed -E 's/([a-z]+)([0-9]+)/\2\1/'
```

### Several expressions
```bash
echo abc | sed -e 's/a/1/' -e 's/c/3/'
```

### Delete a range
```bash
seq 5 | sed '2,3d'
```

### Print a range
```bash
seq 10 | sed -n '3,5p'
```

### Stop at first match
```bash
seq 10 | sed -n '/5/{p;q}'
```

### Remove blank lines
```bash
printf 'a\n\nb\n' | sed '/^$/d'
```

### Trim whitespace
```bash
echo '  hi  ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
```

### Join pairs of lines
```bash
printf 'a\nb\nc\nd\n' | sed 'N;s/\n/ /'
```

### Reverse line order
```bash
seq 3 | sed -n '1!G;h;$p'
```

### Number lines
```bash
printf 'a\nb\n' | sed = | sed 'N;s/\n/ /'
```

### Double space
```bash
printf 'a\nb\n' | sed G
```

### Edit in place with backup
```bash
echo old > f
sed -i.bak 's/old/new/' f
cat f f.bak
```

### Count matching lines
```bash
printf 'a\nb\na\n' | grep -c a
```

### Invert match
```bash
printf 'a\nb\n' | grep -v a
```

### Only the match
```bash
echo 'id=42 x' | grep -oE '[0-9]+'
```

### Fixed string
```bash
printf 'a.b\naxb\n' | grep -F 'a.b'
```

### Whole word
```bash
printf 'cat\ncatalog\n' | grep -w cat
```

### Whole line
```bash
printf 'a\nab\n' | grep -x a
```

### Several patterns
```bash
printf 'a\nb\nc\n' | grep -e a -e c
```

### Extended alternation
```bash
printf 'a\nb\nc\n' | grep -E 'a|c'
```

### Context lines
```bash
seq 5 | grep -C1 3
```

### Line numbers
```bash
printf 'a\nb\n' | grep -n b
```

### Stop after first match
```bash
seq 10 | grep -m1 '[2-9]'
```

### Patterns from a file
```bash
printf 'a\nc\n' > pats
printf 'a\nb\nc\n' | grep -f pats
```

### Recursive with include
```bash
mkdir d
echo needle > d/a.txt
echo needle > d/b.log
grep -r --include='*.txt' needle d
```

### Files containing a match
```bash
echo needle > a.txt
echo hay > b.txt
grep -l needle ./*.txt
```

### Quiet test
```bash
echo needle > a.txt
grep -q needle a.txt && echo found
```

### Cut by delimiter
```bash
echo 'a:b:c' | cut -d: -f2
```

### Cut by characters
```bash
echo abcdef | cut -c2-4
```

### Paste lines with commas
```bash
printf 'a\nb\nc\n' | paste -sd, -
```

### Paste files side by side
```bash
printf 'a\nb\n' > f1
printf '1\n2\n' > f2
paste -d' ' f1 f2
```

### Join on first field
```bash
printf 'a 1\nb 2\n' > f1
printf 'a x\nb y\n' > f2
join f1 f2
```

### Set intersection
```bash
comm -12 <(printf 'a\nb\n') <(printf 'b\nc\n')
```

### Set difference
```bash
comm -23 <(printf 'a\nb\n') <(printf 'b\nc\n')
```

### Numeric sort
```bash
printf '10\n9\n100\n' | sort -n
```

### Sort by key
```bash
printf 'b,2\na,10\n' | sort -t, -k2,2nr
```

### Human-size sort
```bash
printf '1G\n20M\n3K\n' | sort -h
```

### Unique sort
```bash
printf 'b\na\nb\n' | sort -u
```

### First and last lines
```bash
seq 10 | head -n 2
seq 10 | tail -n 2
```

### Skip a header
```bash
printf 'h\na\nb\n' | tail -n +2
```

### Line, word, byte counts
```bash
printf 'a b\nc\n' | wc
```

### Align columns
```bash
printf 'a 1\nbbb 2\n' | column -t
```

### Reverse characters
```bash
echo abc | rev
```

### Wrap long lines
```bash
echo abcdefghij | fold -w 4
```

### Tee in the middle
```bash
seq 3 | tee out.txt | wc -l
```

### Lines onto one line
```bash
seq 5 | xargs
```

### Repeat a line
```bash
yes ok | head -n 3
```

### Translate characters
```bash
echo hello | tr a-z A-Z
```

### Squeeze repeats
```bash
echo 'a    b' | tr -s ' '
```

### Delete characters
```bash
echo 'a1b2' | tr -d '0-9'
```

### Words to lines
```bash
echo a b c | tr ' ' '\n'
```

### Lines to words
```bash
printf 'a\nb\n' | tr '\n' ' '
echo
```

### Fields with read
```bash
echo 'a b c' | { read -r x y z; echo "$z"; }
```

### CSV fields with read
```bash
while IFS=, read -r a b; do
  echo "$b,$a"
done <<< $'1,x\n2,y'
```

### Select JSON field
```bash
echo '{"a":[1,2]}' | jq -r '.a[]'
```

### Compact JSON
```bash
echo '{ "a": 1 }' | jq -c .
```

### Filter JSON array
```bash
echo '[{"n":1},{"n":5}]' | jq -r '.[] | select(.n > 2) | .n'
```

### Slurp JSON lines
```bash
printf '{"a":1}\n{"a":2}\n' | jq -s 'map(.a) | add'
```
