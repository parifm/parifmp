# Expansion and globbing

### Brace list
```bash
echo {a,b,c}
```

### Brace range
```bash
echo {1..5}
```

### Zero-padded range
```bash
echo {01..05}
```

### Stepped range
```bash
echo {0..20..5}
```

### Letter range
```bash
echo {a..e}
```

### Brace product
```bash
echo {a,b}{1,2}
```

### Nested braces
```bash
echo {a,b{1,2}}
```

### Backup copy
```bash
touch file
cp file{,.bak}
ls
```

### Directory tree
```bash
mkdir -p proj/{src,tests,docs}
ls proj
```

### Rename suffix
```bash
touch notes.txt
mv notes.{txt,md}
ls
```

### Command substitution
```bash
echo "today is $(date +%A)"
```

### Nested substitution
```bash
echo "$(basename "$(pwd)")"
```

### Arithmetic expansion
```bash
echo $(( 7 * 6 ))
```

### Tilde expansion
```bash
echo ~
```

### Character class glob
```bash
touch a1 b2 c3
echo [ab][0-9]
```

### Directories only
```bash
mkdir x y
touch z
echo */
```

### Glob negation
```bash
shopt -s extglob
touch a.txt b.log c.jpg
echo !(*.txt|*.log)
```

### Glob alternatives
```bash
shopt -s extglob
touch a.txt b.log c.jpg
echo @(*.txt|*.jpg)
```

### Glob repeats
```bash
shopt -s extglob
touch aa a ab
echo +(a)
```

### Recursive glob
```bash
shopt -s globstar
mkdir -p d/e
touch d/e/f.txt d/g.txt
echo **/*.txt
```

### Empty glob is empty
```bash
shopt -s nullglob
files=(*.nomatch)
echo "${#files[@]}"
```

### Include dotfiles
```bash
shopt -s dotglob
touch .hidden
echo *
```

### Case-insensitive glob
```bash
shopt -s nocaseglob
touch README
echo readme*
```

### Disable globbing
```bash
set -f
echo *
set +f
```

### Glob existence test
```bash
if m=$(compgen -G '*.txt'); then echo "first: ${m%%$'\n'*}"; else echo "no txt files"; fi
```

### Safe file loop
```bash
touch a b
for f in ./*; do
  [[ -e $f ]] || continue
  echo "$f"
done
```
