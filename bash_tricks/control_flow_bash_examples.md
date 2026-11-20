# Control flow

### If, elif, else
```bash
n=5
if [[ $n -gt 3 ]]; then echo big; elif [[ $n -eq 3 ]]; then echo three; else echo small; fi
```

### Arithmetic condition
```bash
(( 5 > 3 )) && echo yes
```

### Empty and non-empty
```bash
s=""
[[ -z $s ]] && echo empty
s=x
[[ -n $s ]] && echo set
```

### Variable is set
```bash
unset v
[[ -v v ]] || echo unset
```

### Option is set
```bash
set -o noclobber
[[ -o noclobber ]] && echo on
```

### File tests
```bash
touch f
echo data > g
[[ -f f && ! -s f ]] && echo empty-file
[[ -d . && -s g ]] && echo dir-and-data
```

### Newer than
```bash
touch a
sleep 1
touch b
[[ b -nt a ]] && echo newer
```

### Lexical compare
```bash
[[ apple < banana ]] && echo before
```

### Negate a test
```bash
if ! grep -q x <<< y; then echo none; fi
```

### Command exists
```bash
if p=$(command -v bash); then echo "found: $p"; fi
```

### Terminal check
```bash
[[ -t 1 ]] && echo tty || echo not-tty
```

### Case with patterns
```bash
set -- run
case "$1" in
  start|run) echo go ;;
  stop) echo halt ;;
  *.txt) echo text ;;
  *) echo other ;;
esac
```

### Case fall-through
```bash
case a in
  a) echo one ;;&
  ?) echo two ;;
esac
```

### For over words
```bash
for i in 1 2 3; do echo "$i"; done
```

### For over arguments
```bash
set -- a b
for arg; do echo "$arg"; done
```

### C-style for
```bash
for (( i = 0; i < 3; i++ )); do echo "$i"; done
```

### While counter
```bash
i=0
while (( i < 3 )); do
  echo "$i"
  (( i++ ))
done
```

### Until
```bash
i=0
until (( i >= 3 )); do (( i++ )); done
echo "$i"
```

### Read lines
```bash
printf 'a\nb\n' | while IFS= read -r line; do echo "[$line]"; done
```

### Split fields while reading
```bash
printf 'root:x:0\nbob:x:1000\n' | while IFS=: read -r user _ uid; do echo "$user $uid"; done
```

### Break and continue
```bash
for i in 1 2 3; do
  for j in 1 2 3; do
    [[ $j == 2 ]] && continue 2
    echo "$i$j"
  done
done
```

### Infinite loop
```bash
while :; do echo tick; break; done
```

### Menu
```bash
PS3='pick: '
select choice in a b; do
  echo "$choice"
  break
done <<< 2
```

### Short-circuit
```bash
true && echo ok || echo fail
```

### Chain commands
```bash
mkdir -p d && cd d && pwd
```

### Group commands
```bash
{ echo a; echo b; } | wc -l
```

### Subshell isolates directory
```bash
( cd /tmp; pwd )
pwd
```

### Exit status
```bash
( exit 3 )
echo $?
```
