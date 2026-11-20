# Portability and POSIX

### Safe printing
```bash
var='-n value'
printf '%s\n' "$var"
```

### Print without newline
```bash
printf %s "no newline"
echo
```

### Command lookup
```bash
if g=$(command -v git); then echo "has-git: $g"; fi
```

### Strict POSIX flags
```bash
( set -euf; echo ok )
```

### Prefix test with case
```bash
s=foobar
case $s in
  foo*) echo prefix ;;
esac
```

### Single-bracket tests
```bash
a=x
b=x
[ "$a" = "$b" ] && echo equal
[ -n "$a" ] && echo nonempty
```

### Split into positionals
```bash
s='a,b,c'
old=$IFS
IFS=,
set -- $s
IFS=$old
echo "$2"
```

### Quote a single quote
```bash
printf '%s\n' 'it'\''s'
```

### Source a file
```bash
printf 'x=1\n' > lib.sh
. ./lib.sh
echo "$x"
```

### Prefix removal
```bash
s=prefix-rest
echo "${s#prefix-}"
```

### Replace with sed
```bash
echo 'a-b-c' | sed 's/-/_/g'
```

### Signals by name
```bash
trap 'echo done' EXIT INT TERM
```

### Raw read
```bash
printf 'a\\nb\n' | { read -r line; echo "$line"; }
```

### Terminal test
```bash
[ -t 1 ] && echo tty || echo not-tty
```

### Detect bash
```bash
[ -n "$BASH_VERSION" ] && echo bash
```

### Detect the OS
```bash
case "$(uname -s)" in
  Linux) echo linux ;;
  Darwin) echo mac ;;
  *) echo other ;;
esac
```

### Re-exec under bash
```bash
[ -n "$BASH_VERSION" ] || exec bash "$0" "$@"
```
