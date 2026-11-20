# Date and time

### Epoch seconds
```bash
date +%s
```

### Epoch without a fork
```bash
printf '%(%s)T\n' -1
```

### Epoch variable
```bash
echo "$EPOCHSECONDS"
```

### Formatted time without a fork
```bash
printf '%(%Y-%m-%d %H:%M:%S)T\n' -1
```

### Epoch to calendar time
```bash
printf '%(%F %T)T\n' 1628600000
```

### Timestamped name
```bash
printf -v ts '%(%Y%m%d-%H%M%S)T' -1
echo "backup-$ts.tar"
```

### Duration as clock
```bash
s=3725
printf '%02d:%02d:%02d\n' $(( s / 3600 )) $(( s % 3600 / 60 )) $(( s % 60 ))
```

### UTC ISO timestamp
```bash
date -u +%Y-%m-%dT%H:%M:%SZ
```

### Another timezone
```bash
TZ=Asia/Tokyo date +%H:%M
```

### Weekday and day of year
```bash
date +%A
date +%j
```

### Epoch to date with GNU date
```bash
date -d @1628600000 '+%Y-%m-%d %H:%M:%S'
```

### Add a day with GNU date
```bash
date -d '2025-01-01 +1 day' +%F
```

### Relative dates with GNU date
```bash
date -d 'last friday' +%F
date -d '2 weeks ago' +%F
```

### Days between dates with GNU date
```bash
a=$(date -d 2025-03-01 +%s)
b=$(date -d 2025-01-01 +%s)
echo $(( (a - b) / 86400 ))
```

### Fractional sleep
```bash
sleep 0.25
```
