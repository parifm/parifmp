# History and readline

### Repeat last command
```bash
!!
```

### Last argument
```bash
ls /tmp
cd !$
```

### First argument
```bash
echo one two
echo !^
```

### All arguments
```bash
echo a b c
echo !*
```

### Reuse one word
```bash
echo a b c
echo !!:2
```

### Last command starting with text
```bash
!ssh
```

### Last command containing text
```bash
!?pattern?
```

### Command by offset
```bash
!-2
```

### Command by number
```bash
!123
```

### Fix a typo
```bash
echo helo
^helo^hello
```

### Substitute in last command
```bash
!!:s/old/new/
```

### Edit then run last command
```bash
fc
```

### Show recent history
```bash
history | tail -n 5
```

### Search history
```bash
history | grep ssh
```

### Ignore duplicates and leading spaces
```bash
HISTCONTROL=ignoreboth
```

### Omit one command from history
```bash
HISTCONTROL=ignorespace
 echo "this command is not recorded"
```

### Clear history
```bash
history -c
```

### Disable history for the session
```bash
unset HISTFILE
```

### Large history
```bash
HISTSIZE=100000
HISTFILESIZE=200000
```

### Timestamps in history
```bash
HISTTIMEFORMAT='%F %T '
```

### Append instead of overwrite
```bash
shopt -s histappend
```

### Share history between sessions
```bash
PROMPT_COMMAND='history -a; history -n'
```

### Skip noisy commands
```bash
HISTIGNORE='ls:cd:pwd:exit'
```

### Review before running
```bash
shopt -s histverify
```

### Prefix search on arrows
```bash
bind '"\e[A": history-search-backward'
bind '"\e[B": history-search-forward'
```

### Bind a key to a command
```bash
bind -x '"\C-l": clear'
```

### Edit the line from a binding
```bash
bind -x '"\C-x\C-t": READLINE_LINE="$(date +%T)"; READLINE_POINT=${#READLINE_LINE}'
```

### Case-insensitive completion
```bash
bind 'set completion-ignore-case on'
```

### List completions at once
```bash
bind 'set show-all-if-ambiguous on'
```

### Vi editing mode
```bash
set -o vi
```

### List bindings
```bash
bind -p | head -n 5
```
