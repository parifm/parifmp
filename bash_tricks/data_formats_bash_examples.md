# Data formats

### Build JSON
```bash
jq -n --arg name bob --argjson n 3 '{name: $name, n: $n}'
```

### Escape a JSON string
```bash
s='a "q"'
printf '"%s"\n' "${s//\"/\\\"}"
```

### JSON template
```bash
name=bob
cat <<EOF
{"name": "$name"}
EOF
```

### URL-encode
```bash
jq -rn --arg s 'a b&c' '$s | @uri'
```

### CSV to TSV
```bash
echo 'a,b' | tr , '\t'
```

### Aligned CSV
```bash
printf 'a,b\nccc,d\n' | column -t -s,
```

### Base64
```bash
printf hello | base64
printf aGVsbG8= | base64 -d
```

### Decode and run an embedded payload
```bash
eval "$(base64 -d <<< "$encoded")"
```

### Hex dump
```bash
printf 'hi' | xxd -p
```

### Checksum
```bash
printf hi | cksum
```

### Key=value lines
```bash
while IFS== read -r k v; do
  printf '%s -> %s\n' "$k" "$v"
done <<< $'a=1\nb=2'
```

### Formatted table
```bash
printf '%-8s %5s\n' name score bob 10 amy 7
```
