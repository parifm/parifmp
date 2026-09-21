#!/bin/bash
[[ "x$1" == "x" ]] && CLUSTER=ceph CLUSTER="$1"
HEAD="backend001"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
COL="${DIR}/host_col.sh"
LOG_DIR="${DIR}/logs/${CLUSTER}"
LOG="${LOG_DIR}/${CLUSTER}_drive_smartctl_full_$(date "+%b_%d_%Y_%s").log.gz"

case $CLUSTER in
  "ceph")
    HEAD="backend001"
    ;;
  "")
    ;;
  *)
    echo "$1 is not a known Ceph cluster"
    exit 1
    ;;
esac

HOST_LIST=$(for x in $HEAD; do ssh $x 'c=$(which ceph 2>/dev/null) || c="cephadm shell -- ceph"; $c node ls -f json 2>/dev/null' | jq -r '[.[] | keys[]] | unique | .[]'; done)
#echo $HOST_LIST

[[ -z "$HOST_LIST" ]] && { echo "Error: no hosts from ceph node ls" >&2; exit 1; }
mkdir -p $LOG_DIR

declare -a fd
for h in $HOST_LIST; do
  exec {fd[++i]}< <(
    printf '=== %s ===\n' "$h"
    ssh -o StrictHostKeyChecking=no -o LogLevel=error -o ConnectTimeout=15 "$h" 'bash -s' < "${COL}" 2>&1
    rc=$?
    (( rc != 0 )) && printf '=== COLLECTION FAILED %s rc=%d ===\n' "$h" "$rc"
    printf '=== END %s ===\n' "$h"
  )
done
for f in "${fd[@]}"; do cat <&"$f"; exec {f}<&-; done | pigz -9 -p 12 > "$LOG"

#echo "Wrote $(wc -c < "$LOG") bytes to $LOG ($(wc -w <<< "$HOST_LIST") hosts)"
