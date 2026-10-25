# Our own bugs (traps we actually hit; the house rules override any other example in this folder)

### Tab is IFS whitespace: empty fields collapse (cos_restore.sh, 10-25)
```bash
printf 'a\tb\t\t\te\n' | { IFS=$'\t' read -r x y z w v; echo "tab:  z=[$z] v=[$v]"; }       # z=[e]: shifted
printf 'a\tb\t\t\te\n' | tr '\t' '\037' | { IFS=$'\037' read -r x y z w v; echo "\\037: z=[$z] v=[$v]"; }   # z=[] v=[e]
```
Space, tab and newline are IFS whitespace; any other separator keeps empty fields. Better still, store records as JSON lines and read fields by name with jq.

### A heredoc's inner terminator ends it early (it once ran `launchctl bootout gui/501/` and logged the user out)
```bash
cat > s.sh <<'EOF'
cat <<EOF
inner
EOF
echo "this line runs NOW in the outer shell; it never reaches s.sh"
EOF
```
The inner `EOF` ends the outer heredoc, the next line runs at once, and the last `EOF` is a stray "command not found". Edit files with the Edit tool. Never nest the same terminator (use `OUTER`/`INNER`), and give launchctl literal targets, never `$`-built ones.

### `rm -r` on an empty variable
```bash
dir=""
echo rm -r -- "${dir:?dir is empty}/"   # stops with "dir is empty" instead of expanding to /
```

### /bin/bash on macOS is 3.2
```bash
/bin/bash -c 'echo $BASH_VERSION'; /opt/homebrew/bin/bash -c 'echo $BASH_VERSION'
```
Local scripts use `#!/opt/homebrew/bin/bash`. `declare -A`, `mapfile` and `${x^^}` fail under 3.2.

### pgrep -f matches the shell that runs the check
```bash
pgrep -fl 'sleep 1234'                 # finds this command's own bash -c wrapper too
sleep 1234 & sleep 0.2; pgrep -f '^sleep 1234$'; kill %1   # anchor the whole argv
```

### A filter's silence is not a result
```bash
grep -c 'ERROR' app.log || echo "0 matches, or no file: check which"
grep -c 'INFO' app.log    # positive control: a pattern that must match proves the input was read
```

### Slicing a number's string form (udpLab 10-25: 8.7e-06 shown as "8.7 Gbps")
```bash
echo 8.7e-06 | jq 'tostring | .[0:5]'   # "0.000" on jq 1.7.1; in udpLab's case "8.7"; either way the slice lies
echo 8.7e-06 | jq '. * 1e6'             # 8.7: scale numerically, then format
```

### GNU-only flags on macOS
```bash
ls -l -D '%T' .     # BSD ls; GNU's --time-style fails here
stat -f %m file     # BSD stat; GNU uses stat -c %Y
```
