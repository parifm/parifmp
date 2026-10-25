# Parameter expansion

### Default if unset or empty
```bash
unset name
echo "${name:-guest}"
```

### Default if unset only
```bash
name=
echo "[${name-unset}]"
```

### Assign default
```bash
unset name
: "${name:=guest}"
echo "$name"
```

### Alternate value
```bash
name=ann
echo "${name:+greeting for $name}"
```

### Fallback chain
```bash
unset a b
echo "${a:-${b:-default}}"
```

### Required variable
```bash
( : "${required:?required is not set}" ) || echo "failed as expected"
```

### String length
```bash
s=hello
echo "${#s}"
```

### Substring
```bash
s=abcdef
echo "${s:2:3}"
```

### Substring from end
```bash
s=abcdef
echo "${s: -3}"
```

### Strip shortest prefix
```bash
p=/a/b/c.txt
echo "${p#*/}"
```

### Strip longest prefix
```bash
p=/a/b/c.txt
echo "${p##*/}"
```

### Strip shortest suffix
```bash
p=c.tar.gz
echo "${p%.*}"
```

### Strip longest suffix
```bash
p=c.tar.gz
echo "${p%%.*}"
```

### Extension only
```bash
f=archive.tar.gz
echo "${f##*.}"
```

### Directory part
```bash
p=/a/b/c.txt
echo "${p%/*}"
```

### Remove trailing slash
```bash
d=/tmp/dir/
echo "${d%/}"
```

### Swap extension
```bash
f=report.txt
echo "${f%.txt}.log"
```

### Replace first match
```bash
s=a-b-c
echo "${s/-/_}"
```

### Replace all matches
```bash
s=a-b-c
echo "${s//-/_}"
```

### Replace at start
```bash
s=foobar
echo "${s/#foo/X}"
```

### Replace at end
```bash
s=foobar
echo "${s/%bar/X}"
```

### Delete matches
```bash
s=a1b2c3
echo "${s//[0-9]/}"
```

### Uppercase
```bash
s=hello
echo "${s^^}"
```

### Lowercase
```bash
s=HELLO
echo "${s,,}"
```

### Capitalize first letter
```bash
s=hello
echo "${s^}"
```

### Swap case
```bash
s=Hello
echo "${s~~}"
```

### Indirect reference
```bash
a=b
b=value
echo "${!a}"
```

### Names by prefix
```bash
app_one=1
app_two=2
echo "${!app_@}"
```

### Quoted for reuse
```bash
s="it's here"
echo "${s@Q}"
```

### Trim whitespace
```bash
s="   padded   "
s="${s#"${s%%[![:space:]]*}"}"
s="${s%"${s##*[![:space:]]}"}"
echo "[$s]"
```
