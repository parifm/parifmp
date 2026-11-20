# Arrays and maps

### Indexed array
```bash
a=(x y z)
echo "${a[1]}"
```

### All elements
```bash
a=(x "y z")
printf '%s\n' "${a[@]}"
```

### Length
```bash
a=(x y z)
echo "${#a[@]}"
```

### Append
```bash
a=(x)
a+=(y z)
echo "${a[@]}"
```

### Slice
```bash
a=(a b c d e)
echo "${a[@]:1:3}"
```

### Indices
```bash
a=(p q r)
echo "${!a[@]}"
```

### Last element
```bash
a=(a b c)
echo "${a[-1]}"
```

### Delete element
```bash
a=(a b c)
unset 'a[1]'
echo "${a[@]}"
```

### Reindex
```bash
a=(a b c)
unset 'a[1]'
a=("${a[@]}")
echo "${!a[@]}"
```

### Copy
```bash
a=(1 2 3)
b=("${a[@]}")
echo "${b[@]}"
```

### Element length
```bash
a=(abc d)
echo "${#a[0]}"
```

### Transform every element
```bash
a=(a.txt b.txt)
echo "${a[@]%.txt}"
```

### Prefix every element
```bash
a=(x y)
printf '%s\n' "${a[@]/#/p-}"
```

### Sparse array
```bash
a[5]=x
a[10]=y
echo "${!a[@]}"
```

### Format into element
```bash
printf -v 'a[2]' '%s' x
echo "${a[2]}"
```

### Lines into array
```bash
mapfile -t lines < <(printf 'a\nb\nc\n')
echo "${#lines[@]}"
```

### File into array
```bash
printf 'x\ny\n' > f
readarray -t rows < f
echo "${rows[1]}"
```

### Null-delimited input
```bash
mapfile -d '' -t items < <(printf 'a\0b\0')
echo "${#items[@]}"
```

### First lines only
```bash
mapfile -t -n 2 first < <(seq 10)
echo "${first[@]}"
```

### Split on delimiter
```bash
IFS=, read -ra parts <<< "a,b,c"
echo "${parts[2]}"
```

### Join with delimiter
```bash
a=(a b c)
( IFS=,; echo "${a[*]}" )
```

### Filter
```bash
a=(1 22 3 44)
out=()
for x in "${a[@]}"; do
  [[ $x == ??* ]] && out+=("$x")
done
echo "${out[@]}"
```

### Sort
```bash
a=(c a b)
mapfile -t sorted < <(printf '%s\n' "${a[@]}" | sort)
echo "${sorted[@]}"
```

### Stack
```bash
s=()
s+=(1)
s+=(2)
echo "${s[-1]}"
unset 's[-1]'
echo "${#s[@]}"
```

### Queue with positionals
```bash
set -- a b
set -- "$@" c
echo "$1"
shift
echo "$#"
```

### Command in an array
```bash
cmd=(printf '%s\n' "a b" c)
"${cmd[@]}"
```

### Print definition
```bash
a=(x y)
declare -p a
```

### Associative array
```bash
declare -A color=([apple]=red [lime]=green)
echo "${color[apple]}"
```

### Assign key
```bash
declare -A m
m[key]=value
echo "${m[key]}"
```

### Iterate keys
```bash
declare -A m=([a]=1 [b]=2)
for k in "${!m[@]}"; do
  echo "$k=${m[$k]}"
done
```

### Key exists
```bash
declare -A m=([a]=1)
[[ -v m[a] ]] && echo yes
```

### Delete key
```bash
declare -A m=([a]=1 [b]=2)
unset 'm[a]'
echo "${!m[@]}"
```

### Count keys
```bash
declare -A m=([a]=1 [b]=2)
echo "${#m[@]}"
```

### De-duplicate in order
```bash
declare -A seen
for x in a b a c b; do
  [[ -v seen[$x] ]] || { seen[$x]=1; printf '%s ' "$x"; }
done
echo
```

### Count occurrences
```bash
declare -A n
for w in a b a; do
  n[$w]=$(( ${n[$w]:-0} + 1 ))
done
declare -p n
```

### Load key=value lines
```bash
declare -A kv
while IFS== read -r k v; do
  kv[$k]=$v
done < <(printf 'a=1\nb=2\n')
echo "${kv[b]}"
```
