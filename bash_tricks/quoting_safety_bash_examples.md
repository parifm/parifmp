# Quoting and safety

### What unquoted eval allows
```bash
user_input='x; echo INJECTED'
eval "echo $user_input"
```

### Quote expansions
```bash
f="my file.txt"
touch "$f"
ls "$f"
```

### Single versus double quotes
```bash
x=1
echo '$x' "$x"
```

### Escape a dollar sign
```bash
echo "cost: \$5"
```

### Newline in a variable
```bash
nl=$'\n'
echo "a${nl}b"
```

### Option terminator
```bash
touch -- -x
rm -- -x
```

### Path prefix for globs
```bash
touch ./-y
for f in ./*; do echo "$f"; done
```

### Commands in arrays
```bash
cmd=(echo "a b")
"${cmd[@]}"
```

### Raw read
```bash
read -r line <<< 'a\nb'
echo "$line"
```

### Keep leading whitespace
```bash
IFS= read -r line <<< '  spaced  '
echo "[$line]"
```

### Pattern versus literal
```bash
p='a*'
[[ aaa == $p ]] && echo pattern
[[ aaa == "$p" ]] || echo literal
```

### Empty-safe test
```bash
x=""
[ -n "$x" ] || echo empty
```

### Preserve spacing in substitution
```bash
out="$(printf 'a  b')"
echo "$out"
```

### Quote for display
```bash
printf '%q\n' 'a b$c'
```

### Quoted replacement result
```bash
f="a b"
echo "${f// /_}"
```
