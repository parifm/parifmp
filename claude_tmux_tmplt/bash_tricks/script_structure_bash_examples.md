# Script structure

### Script directory
```bash
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
echo "$script_dir"
```

### Main function
```bash
main() {
  echo "running with $# arguments"
}
main "$@"
```

### Run only when executed
```bash
main() { echo running; }
[[ ${BASH_SOURCE[0]} == "$0" ]] && main
```

### Constants
```bash
readonly PI=3.14
declare -r NAME=demo
echo "$PI $NAME"
```

### Immutable value
```bash
readonly LIMIT=5
LIMIT=6 || echo immutable
```

### Leveled logging
```bash
log() {
  local level=$1
  shift
  printf '%s [%s] %s\n' "$(date +%T)" "$level" "$*" >&2
}
log INFO started
```

### Usage text
```bash
usage() {
  cat <<EOF
Usage: ${0##*/} [-h] file
EOF
}
usage
```

### Require a minimum bash
```bash
( (( BASH_VERSINFO[0] >= 4 )) || exit 1 ) && echo ok
```

### Require root
```bash
(( EUID == 0 )) || echo "not root"
```

### Idempotent append
```bash
touch f
line='export A=1'
grep -qxF "$line" f || echo "$line" >> f
grep -qxF "$line" f || echo "$line" >> f
wc -l < f
```

### Idempotent symlink
```bash
mkdir target
ln -sfn target link
ln -sfn target link
ls -l link
```

### Idempotent directory
```bash
mkdir -p a/b/c
mkdir -p a/b/c
```

### Data after the script
```bash
printf '%s\n' 'sed "1,/^__DATA__\$/d" "$0"' 'exit' '__DATA__' 'embedded one' 'embedded two' > self.sh
bash self.sh
```

### Rename the script
```bash
BASH_ARGV0=renamed
echo "$0"
```

### PID file
```bash
printf '%s\n' "$$" > app.pid
cat app.pid
```

### Exit code table
```bash
readonly EX_OK=0 EX_USAGE=64 EX_DATAERR=65
echo "$EX_USAGE"
```
