#!/bin/bash

for d in $(lsblk -o NAME,TYPE | grep disk | awk '{print "/dev/"$1}'); do exec {fd[++i]}< <(printf '%s,%s\n' "$HOSTNAME" "$d"; smartctl -x "$d" 2>&1); done
for f in "${fd[@]}"; do cat <&"$f"; exec {f}<&-; done

exit 0

drives=(/dev/sd? /dev/nvme?n1)
declare -a fd out

for i in "${!drives[@]}"; do
  exec {fd[i]}< <(printf '%s,%s\n' "$HOSTNAME" "${drives[i]}"; smartctl -x -l ssd "${drives[i]}" 2>&1)
done

for i in "${!drives[@]}"; do
  IFS= read -r -d '' 'out[i]' <&"${fd[i]}"
  exec {fd[i]}<&-
done

echo "=== $HOSTNAME ==="
printf '%s' "${out[@]}"
