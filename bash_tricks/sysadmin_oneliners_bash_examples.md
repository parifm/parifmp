# Sysadmin one-liners

### Biggest entries
```bash
du -sk ./* | sort -rn | head -n 5
```

### Free space
```bash
df -h .
```

### Disk threshold check
```bash
df -P . | awk 'NR == 2 {gsub("%", "", $5); if ($5 > 85) print "disk high"}'
```

### Top memory processes
```bash
ps aux | sort -nrk 4 | head -n 5
```

### Top CPU processes
```bash
ps aux | sort -nrk 3 | head -n 5
```

### Zombie processes
```bash
ps -eo pid,ppid,state,command | awk '$3 ~ /^Z/'
```

### Process by pattern
```bash
pgrep -f 'sleep 99' || echo none
```

### Load average
```bash
uptime | awk -F'load average' '{print $2}'
```

### Listening sockets
```bash
lsof -i -P -n | grep LISTEN
```

### Established connections
```bash
netstat -an | awk '/ESTABLISHED/ {n++} END {print n + 0}'
```

### Open files of this shell
```bash
lsof -p $$ | wc -l
```

### Files changed recently
```bash
find . -type f -mmin -60
```

### Large files
```bash
find . -type f -size +100M
```

### Old logs
```bash
find . -name '*.log' -mtime +30
```

### Rotate a log by date
```bash
echo data > app.log
mv app.log "app.log.$(date +%F)"
ls
```

### Status codes from a log
```bash
printf '1 - - [x] "GET /" 200 5\n1 - - [x] "GET /a" 404 5\n1 - - [x] "GET /" 200 5\n' | awk '{print $(NF-1)}' | sort | uniq -c | sort -rn
```

### Entries per minute
```bash
printf '10:01:02 a\n10:01:09 b\n10:02:00 c\n' | cut -c1-5 | uniq -c
```

### Backup over ssh
```bash
tar czf - project | ssh backup-host 'cat > project.tgz'
```

### Restore over ssh
```bash
ssh backup-host 'cat project.tgz' | tar xzf -
```

### Request timing
```bash
out=$(curl -sS -w '\nconnect=%{time_connect} total=%{time_total}' https://example.com); echo "${out##*$'\n'}"
```

### Name lookup
```bash
dig +short example.com
```

### Service state
```bash
systemctl is-active --quiet sshd && echo up
```

### Recent unit logs
```bash
journalctl -u sshd --since '1 hour ago' | tail
```

### Memory available
```bash
awk '/MemAvailable/ {print $2}' /proc/meminfo
```

### Process tree
```bash
ps -ef --forest
```

### Repeat a command
```bash
watch -n 1 'ps aux --sort=-%mem | head'
```

### Pods by name
```bash
kubectl get pods -o json | jq -r '.items[].metadata.name'
```

### Private file mode
```bash
touch secret
chmod 600 secret
ls -l secret
```

### Find SUID binaries
```bash
find / -xdev -perm -4000 -type f
```

### Find world-writable files
```bash
find / -xdev -type f -perm -0002
```

### List sudo privileges
```bash
sudo -l
```
