# Prompt and interactive

### Minimal prompt
```bash
PS1='\u:\W \$ '
```

### Colored prompt
```bash
PS1='\[\033[0;32m\]\u@\h\[\033[0m\]:\w\$ '
```

### Exit status in prompt
```bash
PS1='[$?] \w \$ '
```

### Git branch in prompt
```bash
PS1='\w$(__git_ps1 " (%s)") \$ '
```

### Time in prompt
```bash
PS1='\A \h \$ '
```

### Two-line prompt
```bash
PS1='\n\w\n\$ '
```

### Prompt command
```bash
prompt_fn() { PS1="$(date +%H:%M) \w \$ "; }
PROMPT_COMMAND=prompt_fn
```

### Foreground colors
```bash
printf '\033[31mred\033[0m \033[32mgreen\033[0m\n'
```

### Bold and underline
```bash
printf '\033[1mbold\033[0m \033[4munder\033[0m\n'
```

### 256-color
```bash
printf '\033[38;5;208morange\033[0m\n'
```

### Colors with tput
```bash
red=$(tput setaf 1)
reset=$(tput sgr0)
echo "${red}alert${reset}"
```

### Colors only on a terminal
```bash
if [[ -t 1 ]]; then
  red=$'\033[31m'
  reset=$'\033[0m'
else
  red=
  reset=
fi
echo "${red}hello${reset}"
```

### Progress counter
```bash
for i in 1 2 3; do
  printf '\rprogress %d/3' "$i"
  sleep 0.1
done
echo
```

### Progress bar
```bash
n=5
printf '[%-10s]\n' "$(printf '#%.0s' $(seq 1 "$n"))"
```

### Spinner
```bash
for c in '|' '/' '-' '\'; do
  printf '\r%s' "$c"
  sleep 0.1
done
printf '\r \n'
```

### Clear the line
```bash
printf '\033[2K\r'
```

### Terminal title
```bash
printf '\033]0;%s\007' "my title"
```

### Bell
```bash
printf '\a'
```

### Prompt with default
```bash
read -rp "Name [bob]: " name
name=${name:-bob}
echo "$name"
```

### Menu choice
```bash
PS3='choose: '
select item in start stop; do
  echo "$item"
  break
done <<< 1
```

### Alias
```bash
shopt -s expand_aliases
alias ll='ls -lAh'
ll
```

### Function instead of alias
```bash
mkcd() { mkdir -p -- "$1" && cd -- "$1"; }
mkcd newdir
pwd
```

### Climb directories
```bash
up() {
  local d="" i
  for (( i = 0; i < ${1:-1}; i++ )); do d+="../"; done
  cd "$d" || return
}
mkdir -p a/b
cd a/b
up 2
pwd
```

### Bypass an alias
```bash
shopt -s expand_aliases
alias ls='ls -l'
\ls
command ls
```

### Directory shortcuts
```bash
shopt -s autocd cdspell
CDPATH=.:~
```

### Completion word list
```bash
complete -W "start stop status" mycmd
```

### Completion function
```bash
_mycmd() {
  COMPREPLY=( $(compgen -W "start stop" -- "${COMP_WORDS[COMP_CWORD]}") )
}
complete -F _mycmd mycmd
```

### Completion generators
```bash
compgen -c | head -n 3
compgen -A function | head -n 3
```

### Help for builtins
```bash
help cd | head -n 2
```

### Where a command comes from
```bash
type -a bash
```

### Kind of command
```bash
type -t cd
```

### Time a command
```bash
TIMEFORMAT='%R seconds'
time sleep 0.1
```

### Window size
```bash
shopt -s checkwinsize
echo "${COLUMNS:-80}x${LINES:-24}"
```

### Load personal settings
```bash
if [[ -f ~/.bashrc ]]; then
  source ~/.bashrc
fi
```
