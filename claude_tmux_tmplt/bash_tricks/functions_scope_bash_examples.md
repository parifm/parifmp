# Functions and scope

### Define and call
```bash
greet() { echo "hi $1"; }
greet bob
```

### Local variables
```bash
f() { local x=1; echo "$x"; }
x=0
f
echo "$x"
```

### Status as result
```bash
is_even() { (( $1 % 2 == 0 )); }
is_even 4 && echo even
```

### Output as result
```bash
square() { echo $(( $1 * $1 )); }
r=$(square 5)
echo "$r"
```

### Result via printf -v
```bash
square() { printf -v "$1" '%s' $(( $2 * $2 )); }
square out 6
echo "$out"
```

### Result via nameref
```bash
square() { local -n result=$1; result=$(( $2 * $2 )); }
square out 7
echo "$out"
```

### Fill array by name
```bash
fill() { local -n arr=$1; arr+=(x y); }
list=()
fill list
echo "${list[@]}"
```

### Several values back
```bash
minmax() { echo "$1 $2"; }
read -r lo hi < <(minmax 1 9)
echo "$lo $hi"
```

### Default argument
```bash
hello() { local name="${1:-world}"; echo "hello $name"; }
hello
hello bob
```

### Variadic arguments
```bash
show() { printf '[%s]\n' "$@"; }
show a "b c"
```

### Shift arguments
```bash
f() { local first=$1; shift; echo "$first|$*"; }
f a b c
```

### Scoped IFS
```bash
join() { local IFS=,; echo "$*"; }
join a b c
```

### Recursion
```bash
fact() {
  local n=$1
  (( n <= 1 )) && { echo 1; return; }
  echo $(( n * $(fact $(( n - 1 ))) ))
}
fact 5
```

### Dynamic scope
```bash
inner() { echo "$v"; }
outer() { local v=from-outer; inner; }
outer
```

### Callbacks
```bash
apply() { local fn=$1; shift; for x in "$@"; do "$fn" "$x"; done; }
double() { echo $(( $1 * 2 )); }
apply double 1 2 3
```

### Export a function
```bash
hello() { echo hi; }
export -f hello
bash -c hello
```

### Odd function names
```bash
my-func() { echo ok; }
my-func
```

### Print a definition
```bash
f() { echo x; }
declare -f f
```

### Remove a function
```bash
f() { :; }
unset -f f
type f || echo gone
```

### Caller name
```bash
f() { echo "${FUNCNAME[0]} called from ${FUNCNAME[1]:-main}"; }
g() { f; }
g
```

### Local array
```bash
f() { local -a a=(1 2); echo "${#a[@]}"; }
f
```

### Scoped shell option
```bash
f() { local -; set -f; echo *; }
touch a b
f
echo *
```

### Wrap a builtin
```bash
cd() { builtin cd "$@" && echo "now in $PWD"; }
cd /tmp
```

### Source a library
```bash
printf 'lib_fn() { echo from lib; }\n' > lib.sh
source ./lib.sh
lib_fn
```
