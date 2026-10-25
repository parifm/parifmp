# Arguments and options

### Positional parameters
```bash
set -- a b c
echo "$1 $2 $#"
```

### Quoted argument list
```bash
set -- "a b" c
printf '[%s]\n' "$@"
```

### Star versus at
```bash
set -- "a b" c
for x in "$*"; do echo "[$x]"; done
for x in "$@"; do echo "[$x]"; done
```

### Join arguments
```bash
set -- a b c
( IFS=,; echo "$*" )
```

### Shift through arguments
```bash
set -- 1 2 3
while (( $# )); do
  echo "$1"
  shift
done
```

### Shift several
```bash
set -- a b c d
shift 2
echo "$@"
```

### Slice of arguments
```bash
set -- a b c d
echo "${@:2:2}"
```

### Last argument
```bash
set -- a b c
echo "${@: -1}"
```

### Arguments in an array
```bash
args=(--flag "value with space")
printf '[%s]\n' "${args[@]}"
```

### Parse with getopts
```bash
parse() {
  local OPTIND opt name="" verbose=0
  while getopts ":n:vh" opt; do
    case $opt in
      n) name=$OPTARG ;;
      v) verbose=1 ;;
      h) echo usage ;;
      :) echo "missing value for -$OPTARG" ;;
      \?) echo "unknown -$OPTARG" ;;
    esac
  done
  shift $(( OPTIND - 1 ))
  echo "name=$name verbose=$verbose rest=$*"
}
parse -n bob -v file1 file2
```

### Long options with case
```bash
set -- --name=bob -v -- rest
while [[ $# -gt 0 ]]; do
  case $1 in
    --name=*) name=${1#*=}; shift ;;
    --name) name=$2; shift 2 ;;
    -v|--verbose) verbose=1; shift ;;
    --) shift; break ;;
    -*) echo "unknown: $1" >&2; break ;;
    *) break ;;
  esac
done
echo "name=$name verbose=${verbose:-0} rest=$*"
```

### Subcommand dispatch
```bash
cmd_start() { echo starting; }
cmd_stop() { echo stopping; }
set -- stop
"cmd_${1:-start}"
```

### End of options marker
```bash
touch -- -odd-name
ls -- -odd-name
```

### Environment default
```bash
: "${PORT:=8080}"
echo "$PORT"
```

### Per-command environment
```bash
FOO=bar bash -c 'echo "$FOO"'
```

### Export to children
```bash
export A=1
bash -c 'echo "$A"'
```

### Clean environment
```bash
env -i bash -c 'echo "${HOME:-none}"'
```

### Load config into environment
```bash
printf 'A=1\nB=2\n' > conf
set -a
source ./conf
set +a
echo "$A$B"
```

### Script name
```bash
echo "${0##*/}"
```

### Prompt for input
```bash
read -rp "Name: " name <<< bob
echo "$name"
```

### Single keypress
```bash
read -n 1 -r key <<< x
echo "$key"
```

### Confirm
```bash
read -rp "Continue? [y/N] " ans <<< y
[[ $ans == [yY]* ]] && echo yes
```
