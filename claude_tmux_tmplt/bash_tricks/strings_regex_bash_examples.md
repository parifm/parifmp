# Strings and regex

### Glob match
```bash
[[ report.csv == *.csv ]] && echo csv
```

### Regex captures
```bash
[[ "user42" =~ ^([a-z]+)([0-9]+)$ ]] && echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
```

### Regex in a variable
```bash
re='^[0-9]+$'
[[ 123 =~ $re ]] && echo number
```

### Digits-only test
```bash
n=123
[[ $n != *[!0-9]* ]] && echo digits
```

### Starts and ends with
```bash
s=foobar
[[ $s == foo* && $s == *bar ]] && echo both
```

### Contains
```bash
[[ "hello world" == *wor* ]] && echo found
```

### Ignore case
```bash
shopt -s nocasematch
[[ HELLO == hello ]] && echo same
```

### Compare lowercase
```bash
a=Hello
b=hELLO
[[ ${a,,} == "${b,,}" ]] && echo equal
```

### POSIX class
```bash
[[ x == [[:alpha:]] ]] && echo alpha
```

### Literal comparison
```bash
p='a*'
[[ aaa == "$p" ]] || echo literal
```

### Version parts
```bash
s="v1.22.3"
[[ $s =~ ([0-9]+)\.([0-9]+) ]]
echo "${BASH_REMATCH[2]}"
```

### Loop over matches
```bash
s="a1b22c333"
while [[ $s =~ [0-9]+ ]]; do
  echo "${BASH_REMATCH[0]}"
  s=${s#*"${BASH_REMATCH[0]}"}
done
```

### Padded columns
```bash
printf '%-10s|%5s|\n' left right
```

### Zero padding
```bash
printf '%05d\n' 42
```

### Fixed decimals
```bash
printf '%.2f\n' 3.14159
```

### Repeat a character
```bash
printf '%*s\n' 10 '' | tr ' ' '-'
```

### Format into variable
```bash
printf -v padded '%08.3f' 3.14159
echo "$padded"
```

### Reuse format
```bash
printf '%s,' a b c
echo
```

### Shell-quote a value
```bash
printf '%q\n' "a b;c"
```

### Backslash escapes
```bash
printf '%b\n' 'a\tb'
```

### ANSI-C quoting
```bash
printf '%s\n' $'tab\there'
```

### Reverse a string
```bash
s=abc
for (( i = ${#s} - 1; i >= 0; i-- )); do
  printf '%s' "${s:i:1}"
done
echo
```

### First and last field
```bash
s=a:b:c
echo "${s%%:*} ${s##*:}"
```
