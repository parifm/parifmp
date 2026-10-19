#!/bin/bash
# fabric_sleuth: dual-rail backend-to-backend iperf3 fabric check.
# Hosts and rails come from env vars (see usage); output is a tarball
# that generate_dashboard.py turns into an HTML dashboard.

usage() {
    cat <<'EOF'
Usage: FS_HOSTS=<targets> FS_RAIL_A=<cidr,...> FS_RAIL_B=<cidr,...> ./fabric_sleuth_v2.sh [duration_s]
       FS_HOSTS=<targets> ./fabric_sleuth_v2.sh --list   (print expanded targets, no ssh)
From a jump host (settings ride in the remote command; nothing to edit or copy first):
       ssh jump 'FS_HOSTS=10.1.0.0/24 FS_RAIL_A=... FS_RAIL_B=... bash -s -- 120' < fabric_sleuth_v2.sh
       The run ends by printing the scp + render line for the tarball it left on the jump host.

Required
  FS_HOSTS   ssh targets, comma or space separated, any mix of:
               10.1.0.5,node07          single IPs or hostnames
               10.1.0.0/24              CIDR (network and broadcast dropped below /31)
               10.1.0.10-10.1.1.20      full range
               10.1.0.10-40             last-octet range
               10.1.0-1.10-40           per-octet ranges (nmap style)
               @hosts.txt               file, entries split on lines/commas/spaces, # comments
  FS_RAIL_A  rail A data subnets, comma separated:  10.20.1.0/24,10.20.3.0/24
  FS_RAIL_B  rail B data subnets:                    10.20.2.0/24,10.20.4.0/24
   or
  FS_RAILS   shorthand for one subnet per rail, A first:  10.20.1.0/24,10.20.2.0/24
   or
  FS_NICS    data NIC per rail, rail A first:   enp5s0np0,enp196s0np0   (wins over the subnet forms)
  None set: the tool sweeps the hosts, prints the IPv4 subnets it found, and stops.

Optional (default)
  FS_DURATION      iperf3 seconds per run (120; $1 also sets it)
  FS_ITER          iterations, round-robin pairing: no pair repeats, every host pair
                   is tested after n-1 iterations (n if n is odd) (5)
  FS_STREAMS       iperf3 parallel streams, >=2 (16)
  FS_TOS           IP TOS byte for the test traffic, 0-255 (iperf3 -S), e.g. 106 = DSCP 26
                   + ECT(0); TCP keeps the DSCP, the kernel sets the ECN bits (unset: 0)
  FS_UDP=1         after the TCP phases, run the same pairs with UDP and no rate cap
                   (iperf3 -u -b 0, datagrams sized to the path MTU). Loss is split into
                   receiver socket, NIC, kernel backlog and unaccounted (likely fabric).
                   With FS_TOS the whole TOS byte, ECN bits included, is sent.
  FS_UDP_DURATION  seconds per UDP run (FS_DURATION)
  FS_MESH=1        before load, ping every tested host's rail IPs from every other one's (same rail and
                   cross-rail; tested hosts only, so other clusters on shared subnets are never
                   probed). Failures go to mesh_failures.txt and the Preflight card.
  FS_PORT          iperf3 port (5201)
  FS_SSH_USER      ssh user; non-root runs remote steps with sudo -n (root)
  FS_SSH_PARALLEL  ssh sessions at once for sweep and collection (64)
  FS_SSH_RETRY_PARALLEL  retry targets that refused ssh under load (reset, kex) this many at a time (8)
  FS_MAX_TARGETS   refuse to expand FS_HOSTS beyond this (4096)
  FS_LABEL         name in the report and tarball (first tested hostname)
  FS_OUT_DIR       where the tarball goes (.)
  FS_LINE_GBPS     link speed for OK/SLOW cut-offs (most common rail NIC speed)
  FS_OK_PCT        OK at or above this % of link speed (75)
  FS_SLOW_PCT      SLOW at or above this %, CRITICAL below (50)
  FS_BUSY_CHECK    command run on each host before any load; exit 0 = host is in
                   production use, 1 = idle, anything else = unknown (counts as in use).
                   Default: WEKA containers running (`weka local ps`); idle where WEKA
                   isn't installed. Other example: 'systemctl is-active --quiet myservice'.
                   none = no check.
  FS_BUSY_OK=1     run even where FS_BUSY_CHECK says in use (stop the cluster's I/O first)
  FS_EXPECT_HOSTS  hosts that should be tested; fewer makes the coverage PARTIAL
                   (default: every target for a plain host list, the hosts found on
                   the rails when FS_HOSTS has a CIDR or range)

Result: the last line is "RESULT coverage=COMPLETE|PARTIAL|NONE hosts=t/e paths=r/p ...";
exit 0 = COMPLETE, 3 = PARTIAL, 4 = NONE (no throughput result at all), 2 = stopped early.
EOF
}

die() { echo "ERROR: $*" >&2; echo "RESULT coverage=STOPPED ($*)" >&2; exit 2; }
log() { echo "# $*" >&2; }

# ---------- target expansion (pure bash, no ssh) ----------

is_ip() {
    [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local o
    for o in "${BASH_REMATCH[@]:1}"; do (( 10#$o <= 255 )) || return 1; done
}
ip2int() { local IFS=.; set -- $1; echo $(( (10#$1 << 24) + (10#$2 << 16) + (10#$3 << 8) + 10#$4 )); }
int2ip() { echo "$(( $1 >> 24 & 255 )).$(( $1 >> 16 & 255 )).$(( $1 >> 8 & 255 )).$(( $1 & 255 ))"; }

# CIDR -> "network broadcast" as integers
cidr_bounds() {
    local ip=${1%/*} len=${1#*/}
    [[ $1 == */* ]] && is_ip "$ip" && [[ $len =~ ^[0-9]{1,2}$ ]] && (( 10#$len <= 32 )) || return 1
    local mask=$(( (0xFFFFFFFF << (32 - 10#$len)) & 0xFFFFFFFF ))
    local net=$(( $(ip2int "$ip") & mask ))
    echo "$net $(( net | (~mask & 0xFFFFFFFF) ))"
}

in_cidr() {  # ip cidr; no subshells, it runs per address per host
    is_ip "$1" || return 1
    local -a o; IFS=. read -ra o <<<"$1"
    local n=$(( (10#${o[0]} << 24) + (10#${o[1]} << 16) + (10#${o[2]} << 8) + 10#${o[3]} ))
    local b=${_CIDR_CACHE[$2]}
    [[ -n $b ]] || { b=$(cidr_bounds "$2") || return 1; _CIDR_CACHE[$2]=$b; }
    (( n >= ${b% *} && n <= ${b#* } ))
}
declare -A _CIDR_CACHE=()

declare -a TARGETS=()
INPUT_RANGES=0   # 1 once FS_HOSTS has a CIDR or range: unanswered addresses are then normal
declare -A _SEEN=()
_emit() {
    [[ -n ${_SEEN[$1]+x} ]] && return
    _SEEN[$1]=1; TARGETS+=("$1")
    (( ${#TARGETS[@]} <= FS_MAX_TARGETS )) || die "FS_HOSTS expands past FS_MAX_TARGETS=$FS_MAX_TARGETS; narrow it or raise the cap"
}
_need() {  # refuse a range before looping over it
    (( ${#TARGETS[@]} + $1 <= FS_MAX_TARGETS )) || die "'$2' adds $1 targets, past FS_MAX_TARGETS=$FS_MAX_TARGETS"
}

expand_entry() {
    local e=$1 b lo hi n
    [[ $e == *:* ]] && die "IPv6 is not supported: '$e'"
    if [[ $e == */* ]]; then
        b=$(cidr_bounds "$e") || die "bad CIDR: '$e'"
        lo=${b% *}; hi=${b#* }
        (( hi - lo >= 2 )) && { lo=$(( lo + 1 )); hi=$(( hi - 1 )); }
        (( hi > lo )) && INPUT_RANGES=1
        _need $(( hi - lo + 1 )) "$e"
        for (( n = lo; n <= hi; n++ )); do _emit "$(int2ip $n)"; done
    elif [[ $e =~ ^([0-9.]+)-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
        local from=${BASH_REMATCH[1]} to=${BASH_REMATCH[2]}  # is_ip resets BASH_REMATCH
        is_ip "$from" && is_ip "$to" || die "bad IP range: '$e'"
        lo=$(ip2int "$from"); hi=$(ip2int "$to")
        (( lo <= hi )) || die "range runs backwards: '$e'"
        (( hi > lo )) && INPUT_RANGES=1
        _need $(( hi - lo + 1 )) "$e"
        for (( n = lo; n <= hi; n++ )); do _emit "$(int2ip $n)"; done
    elif [[ $e =~ ^[0-9]+(-[0-9]+)?\.[0-9]+(-[0-9]+)?\.[0-9]+(-[0-9]+)?\.[0-9]+(-[0-9]+)?$ ]]; then
        local -a lo4 hi4; local IFS=. o i count=1 a b c d
        local -a oct=($e)
        for i in 0 1 2 3; do
            o=${oct[$i]}
            lo4[$i]=$(( 10#${o%-*} )); hi4[$i]=$(( 10#${o#*-} ))
            (( lo4[i] <= hi4[i] && hi4[i] <= 255 )) || die "bad octet '$o' in '$e'"
            count=$(( count * (hi4[i] - lo4[i] + 1) ))
        done
        unset IFS
        (( count > 1 )) && INPUT_RANGES=1
        _need $count "$e"
        for (( a = lo4[0]; a <= hi4[0]; a++ )); do for (( b = lo4[1]; b <= hi4[1]; b++ )); do
        for (( c = lo4[2]; c <= hi4[2]; c++ )); do for (( d = lo4[3]; d <= hi4[3]; d++ )); do
            _emit "$a.$b.$c.$d"
        done; done; done; done
    elif [[ $e =~ ^[0-9.-]+$ ]]; then
        die "not a valid IP, range or CIDR: '$e'"
    elif [[ $e =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
        _emit "$e"
    else
        die "not a hostname, IP, range or CIDR: '$e'"
    fi
}

# split on commas and whitespace, no globbing
_words() { local IFS=$', \t\n'; set -f; WORDS=($1); set +f; }

expand_targets() {
    local w line
    TARGETS=(); _SEEN=()
    [[ -n $1 ]] || die "FS_HOSTS is empty"
    _words "$1"
    local -a top=("${WORDS[@]}")
    for w in "${top[@]}"; do
        if [[ $w == @* ]]; then
            [[ -r ${w#@} ]] || die "cannot read host file '${w#@}'"
            while IFS= read -r line || [[ -n $line ]]; do
                line=${line%%#*}
                _words "$line"
                for e in "${WORDS[@]}"; do
                    [[ $e == @* ]] && die "nested @file not supported: '$e' in ${w#@}"
                    expand_entry "$e"
                done
            done < "${w#@}"
        else
            expand_entry "$w"
        fi
    done
    (( ${#TARGETS[@]} > 0 )) || die "FS_HOSTS expanded to zero targets"
}

# ---------- rail spec ----------

parse_rails() {
    if [[ -n $FS_NICS ]]; then
        RAIL_MODE=nic; _words "$FS_NICS"; RAIL_SPEC=("${WORDS[@]}")
        local n
        for n in "${RAIL_SPEC[@]}"; do [[ $n =~ ^[A-Za-z0-9_.:-]+$ ]] || die "bad NIC name in FS_NICS: '$n'"; done
        [[ ${RAIL_SPEC[0]} != "${RAIL_SPEC[1]}" ]] || die "FS_NICS names the same NIC twice"
    elif [[ -n $FS_RAIL_A || -n $FS_RAIL_B ]]; then
        [[ -n $FS_RAIL_A && -n $FS_RAIL_B ]] || die "set both FS_RAIL_A and FS_RAIL_B"
        RAIL_MODE=cidr
        _words "$FS_RAIL_A"; RAIL_SPEC[0]="${WORDS[*]}"
        _words "$FS_RAIL_B"; RAIL_SPEC[1]="${WORDS[*]}"
    elif [[ -n $FS_RAILS ]]; then
        RAIL_MODE=cidr; _words "$FS_RAILS"
        (( ${#WORDS[@]} == 2 )) || die "FS_RAILS takes one CIDR per rail (A,B), got ${#WORDS[@]}; for several per rail use FS_RAIL_A and FS_RAIL_B"
        RAIL_SPEC=("${WORDS[@]}")
    else
        RAIL_MODE=none; RAIL_SPEC=(); return
    fi
    (( ${#RAIL_SPEC[@]} == 2 )) || die "need exactly 2 rails, got ${#RAIL_SPEC[@]}: ${RAIL_SPEC[*]}"
    [[ $RAIL_MODE == cidr ]] || return 0
    # a rail is a set of CIDRs; no A CIDR may overlap a B CIDR
    local ca cb a b
    for ca in ${RAIL_SPEC[0]} ${RAIL_SPEC[1]}; do [[ -n $(cidr_bounds "$ca") ]] || die "bad rail CIDR: '$ca'"; done
    for ca in ${RAIL_SPEC[0]}; do for cb in ${RAIL_SPEC[1]}; do
        a=$(cidr_bounds "$ca"); b=$(cidr_bounds "$cb")
        if (( ${a% *} <= ${b#* } && ${b% *} <= ${a#* } )); then
            die "rail A $ca overlaps rail B $cb, so the rails can't be told apart; list each rail's subnets or set FS_NICS"
        fi
    done; done
}

# exit 1 = WEKA not installed or no container running, 0 = one is Running, 2 = CLI failed
WEKA_BUSY_CHECK='[ -n "$(command -v weka)" ] || exit 1; s=$(weka local ps --no-header -o name,state) || exit 2; echo "$s" | grep -qw Running'

# ---------- ssh ----------

throttle() { while (( $(jobs -rp | wc -l) >= FS_SSH_PARALLEL )); do wait -n; done; }
rsh() { local t=$1; shift; ssh -n "${SSH_OPTS[@]}" "$t" "$@"; }
rbash() { local t=$1; shift; ssh "${SSH_OPTS[@]}" "$t" $SUDO bash -s -- "$@"; }

# Discovery: raw facts only, parsed locally.
read -r -d '' DISCOVER_SCRIPT <<'EOF'
echo "=== hostname ==="; hostname -s
echo "=== machine-id ==="; cat /etc/machine-id 2>&1
echo "=== addr ==="; ip -o -4 addr show
echo "=== link ==="; ip -o link show
echo "=== tools ==="
for c in iperf3 ethtool lldpcli ibstat ss timeout; do p=$(command -v $c); echo "$c ${p:--}"; done
echo "=== iperf3 ==="; [ -n "$(command -v iperf3)" ] && iperf3 --version 2>&1 | head -n 1
echo "=== sysctl ==="
for s in rmem_max wmem_max; do echo "$s $(cat /proc/sys/net/core/$s 2>&1)"; done
if [ -n "$BUSY_CHECK" ]; then
    out=$(timeout 20 bash -c "$BUSY_CHECK" 2>&1); rc=$?
    echo "=== busy ==="; echo "rc=$rc"; echo "$out" | head -n 20
fi
EOF

# Per-host diagnostics for the rail NICs ($@, "-" = none)
read -r -d '' DIAG_SCRIPT <<'EOF'
h=$(hostname -s)
have() { [ -n "$(command -v "$1")" ]; }
ctr() { awk -v k="$1:" '$1==k {print $2; f=1; exit} END {if (!f) print "n/a"}'; }
for nic in "$@"; do
    [ "$nic" = - ] && continue
    ip=$(ip -o -4 addr show dev "$nic" 2>&1 | awk '{split($4,a,"/"); print a[1]; exit}')
    if have ethtool; then
        eth=$(ethtool "$nic" 2>&1); inf=$(ethtool -i "$nic" 2>&1)
        mod=$(ethtool -m "$nic" 2>&1); st=$(ethtool -S "$nic" 2>&1)
    else
        eth="ethtool not installed"; inf=$eth; mod=$eth; st=$eth
    fi
    speed=$(echo "$eth" | awk '/Speed:/{print $2}')
    set -- $(for k in rx_corrected_bits_phy rx_err_lane_0_phy rx_err_lane_1_phy rx_err_lane_2_phy \
                      rx_err_lane_3_phy link_down_events_phy rx_pcs_symbol_err_phy; do echo "$st" | ctr $k; done)
    # Rx power per channel (dBm) and module temp; vendors word these differently
    rxp=$(echo "$mod" | awk '
        /(Rcvr|Receiver|Rx).*power/ && /dBm/ && !/thresh|alarm|warning/ {
            ch = 1; if (match($0, /Channel [0-9]+/)) ch = substr($0, RSTART + 8, RLENGTH - 8)
            for (i = 2; i <= NF; i++) if ($i == "dBm") v[ch] = $(i-1)
        }
        END { for (c = 1; c <= 4; c++) printf "%s ", (c in v ? v[c] : "n/a") }')
    temp=$(echo "$mod" | awk '/Module temperature/ {for (i = 1; i <= NF; i++) if ($i == "degrees") {print $(i-1); exit}}')
    echo "@@NIC_DIAG $h $nic ${ip:-none} ${speed:-unknown} $* $rxp${temp:-n/a}"
    if have lldpcli; then lldp=$(lldpcli show neighbors ports "$nic" 2>&1); else lldp=""; fi
    chassis=$(echo "$lldp" | awk -F': *' '/SysName:/{gsub(/ /,"_",$2); print $2; exit}')
    portid=$(echo "$lldp" | awk '/PortID:/{print $NF; exit}')
    portdesc=$(echo "$lldp" | awk -F': *' '/PortDescr:/{gsub(/ /,"_",$2); print $2; exit}')
    sysdesc=$(echo "$lldp" | awk -F': *' '/SysDescr:/{gsub(/ /,"_",$2); print $2; exit}')
    echo "@@LLDP $h $nic ${ip:-none} ${chassis:-unknown} ${portid:-unknown} ${portdesc:-unknown} ${sysdesc:-unknown}"
    f() { echo "$inf" | awk -F': ' -v k="$1" '$1==k {print $2; exit}'; }
    drv=$(f driver); ver=$(f version); ver=${ver// /_}; fw=$(f firmware-version); bus=$(f bus-info)
    echo "@@DRV $h $nic ${ip:-none} ${drv:-unknown} ${ver:-unknown} ${fw:-unknown} ${bus:-unknown}"
    echo "=== ethtool $nic ==="; echo "$eth"
    echo "=== ethtool -i $nic ==="; echo "$inf"
    echo "=== ethtool -m $nic ==="; echo "$mod"
    echo "=== ethtool -S $nic ==="; echo "$st" | grep -E "rx_|tx_|link_down|pcs_symbol|prio|pause" | grep -v "ch[0-9]"
    echo "=== lldpcli $nic ==="; echo "${lldp:-lldpcli not installed}"
done
echo "=== hostname ==="; echo "$h"
echo "=== ip -br -4 a ==="; ip -br -4 a
if have ibstat; then echo "=== ibstat ==="; ibstat 2>&1; fi
EOF

# Drop counters for the rail NICs ($@): "host_nic ip rx_drop tx_drop rx_oob"
read -r -d '' DROPS_SCRIPT <<'EOF'
h=$(hostname -s)
for nic in "$@"; do
    [ "$nic" = - ] && continue
    ip=$(ip -o -4 addr show dev "$nic" 2>&1 | awk '{split($4,a,"/"); print a[1]; exit}')
    rx=$(cat /sys/class/net/$nic/statistics/rx_dropped 2>&1); tx=$(cat /sys/class/net/$nic/statistics/tx_dropped 2>&1)
    oob=$(ethtool -S "$nic" 2>&1 | awk '$1=="rx_out_of_buffer:" {print $2; f=1} END {if (!f) print "na"}')
    echo "${h}_${nic} ${ip:-none} ${rx:-na} ${tx:-na} ${oob:-na}"
done
EOF

# Per-priority, PFC/pause and ECN/CNP counters for the rail NICs ($@): "host_nic counter value".
# Names differ by driver (mlx5 rx_prio3_pause, ice rx_priority_3_xon.nic, bnxt pfc_*); per-queue lines skipped.
read -r -d '' PRIO_SCRIPT <<'EOF'
h=$(hostname -s)
for nic in "$@"; do
    [ "$nic" = - ] && continue
    ethtool -S "$nic" 2>&1 | awk -v k="${h}_${nic}" '$2 ~ /^[0-9]+$/ && $1 ~ /:$/ {
        n = $1; sub(/:$/, "", n); l = tolower(n)
        if (l ~ /prio|pri[0-9]|pfc|pause|xon|xoff|ecn|cnp/ && l !~ /ch[0-9]|_q[0-9]|queue/) print k, n, $2 }'
done
EOF

# FEC counters for the rail NICs ($@): "host_nic corrected_blocks uncorrectable_blocks corrected_bits symbol_errors".
# Blocks come from the vendor-neutral ethtool -I --show-fec; corrected bits and symbol errors are mlx5 extras. na = not exposed.
read -r -d '' FEC_SCRIPT <<'EOF'
h=$(hostname -s)
num() { awk -v k="$1" '$1 == k {for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}'; }
for nic in "$@"; do
    [ "$nic" = - ] && continue
    f=$(ethtool -I --show-fec "$nic" 2>&1); s=$(ethtool -S "$nic" 2>&1)
    cb=$(echo "$f" | num corrected_blocks:); ub=$(echo "$f" | num uncorrectable_blocks:)
    bits=$(echo "$s" | num rx_corrected_bits_phy:); sym=$(echo "$s" | num rx_pcs_symbol_err_phy:)
    echo "${h}_${nic} ${cb:-na} ${ub:-na} ${bits:-na} ${sym:-na}"
done
EOF

# Mesh: src_a src_b dst... -> "MESHFAIL src dst" for each rail IP pair that does not answer one ping.
# 64 pings at a time; "none" skips a missing rail.
read -r -d '' MESH_SCRIPT <<'EOF'
a=$1 b=$2; shift 2
n=0
for s in $a $b; do
    [ "$s" = none ] && continue
    for d in "$@"; do
        ( out=$(ping -c1 -W1 -I "$s" "$d" 2>&1) || echo "MESHFAIL $s $d" ) &
        n=$(( n + 1 )); [ $(( n % 64 )) = 0 ] && wait
    done
done
wait
EOF

# Rail gateways: rail_ip nic df_size peer... -> "DIRECT" or "GW <ip> OK|MTU|FAIL" per distinct gateway
# that `ip route get <peer> from <rail_ip>` uses (routed fabrics: /31 or per-rail policy tables).
read -r -d '' GW_SCRIPT <<'EOF'
src=$1 nic=$2 size=$3; shift 3
gws=""
for p in "$@"; do
    g=$(ip -o route get "$p" from "$src" 2>&1 | awk '{for (i = 1; i < NF; i++) if ($i == "via") {print $(i+1); exit}}')
    [ -n "$g" ] && case " $gws " in *" $g "*) ;; *) gws="$gws $g" ;; esac
done
[ -z "$gws" ] && { echo "DIRECT"; exit 0; }
for g in $gws; do
    if out=$(ping -c2 -W1 -M do -s "$size" -I "$src" "$g" 2>&1); then echo "GW $g OK"
    elif out=$(ping -c2 -W1 -I "$src" "$g" 2>&1); then echo "GW $g MTU"
    else echo "GW $g FAIL"; fi
done
EOF

# Path check: src_ip dst_ip src_nic df_size -> OK or a reason
read -r -d '' PATH_SCRIPT <<'EOF'
r=$(ip -o route get "$2" from "$1" 2>&1); r=${r%%$'\n'*}
case " $r " in *" dev $3 "*) ;; *) echo "ROUTE egress is not $3: $r"; exit 0 ;; esac
out=$(ping -c1 -W1 -I "$1" "$2" 2>&1) || { echo "PING no reply"; exit 0; }
out=$(ping -c1 -W2 -M do -s "$4" -I "$1" "$2" 2>&1) || { echo "MTU $(( $4 + 28 ))B no-fragment ping failed"; exit 0; }
echo OK
EOF

# Servers: port ip... ; clears earlier iperf3 first (port clash)
read -r -d '' SERVER_SCRIPT <<'EOF'
port=$1; shift
pkill -x iperf3
for i in $(seq 20); do [ -z "$(pgrep -x iperf3)" ] && break; sleep 0.5; done
for ip in "$@"; do iperf3 -s -D -B "$ip" -p "$port"; done
EOF

# One iperf3 run: src dst port streams secs [tos] -> "[SUM] ... receiver retransmits:N" or "ERROR ..."
read -r -d '' IPERF_SCRIPT <<'EOF'
out=$(iperf3 --connect-timeout 5000 -c "$2" -B "$1" -p "$3" -P "$4" -t "$5" -f g -Z ${6:+-S $6} 2>&1); rc=$?
retr=$(echo "$out" | awk '/SUM.*sender/{print $(NF-1)}')
rcv=$(echo "$out" | grep -m1 'SUM.*receiver')
if [ -n "$rcv" ]; then echo "$rcv retransmits:${retr:-0}"
else echo "ERROR rc=$rc $(echo "$out" | grep -i -m1 error | tr -s ' ')"; fi
EOF

# One UDP run, no rate cap: src dst port streams secs len [tos] -> "[SUM] ... receiver" or "ERROR ..."
read -r -d '' UDP_SCRIPT <<'EOF'
out=$(iperf3 --connect-timeout 5000 -u -b 0 -l "$6" -c "$2" -B "$1" -p "$3" -P "$4" -t "$5" -f g ${7:+-S $7} 2>&1); rc=$?
rcv=$(echo "$out" | grep -m1 'SUM.*receiver')
if [ -n "$rcv" ]; then echo "$rcv"
else echo "ERROR rc=$rc $(echo "$out" | grep -i -m1 error | tr -s ' ')"; fi
EOF

# Host-side UDP loss counters: "host InErrors RcvbufErrors SndbufErrors softnet_dropped".
# InErrors includes RcvbufErrors; softnet_stat column 2 (hex) is the per-CPU backlog drop count.
read -r -d '' UDPHOST_SCRIPT <<'EOF'
h=$(hostname -s)
u=$(awk '/^Udp:/ { n++; if (n == 1) split($0, k); else for (i = 2; i <= NF; i++) v[k[i]] = $i }
    END { printf "%d %d %d", v["InErrors"], v["RcvbufErrors"], v["SndbufErrors"] }' /proc/net/snmp)
d=0; while read -r a b rest; do d=$(( d + 16#$b )); done < /proc/net/softnet_stat
echo "$h $u $d"
EOF

# ---------- helpers on discovery files ----------

section() {  # file name -> lines of "=== name ===" section
    awk -v s="=== $2 ===" '$0==s {on=1; next} /^=== .* ===$/ {on=0} on' "$1"
}

# rail_lookup k r: sets RNIC/RIP/RMTU/RSTATE for host k rail r from its discovery file
rail_lookup() {
    local k=$1 r=$2 f=${DISC[$1]} nic="" ip="" n
    if [[ $RAIL_MODE == nic ]]; then
        nic=${RAIL_SPEC[$r]}
        if ! section "$f" link | awk -v n="$nic" '{sub(/:$/,"",$2); sub(/@.*/,"",$2)} $2==n {f=1} END {exit !f}'; then
            RSTATE[$k,$r]="no NIC $nic"; RNIC[$k,$r]=-; RIP[$k,$r]=none; return
        fi
        ip=$(section "$f" addr | awk -v n="$nic" '$2==n {split($4,a,"/"); print a[1]; exit}')
        [[ -n $ip ]] || { RNIC[$k,$r]=$nic; RIP[$k,$r]=none; RSTATE[$k,$r]="no IPv4 on $nic"; return; }
    else
        local -a hits=()
        local c
        while read -r n a; do
            for c in ${RAIL_SPEC[$r]}; do in_cidr "$a" "$c" && { hits+=("$n $a"); break; }; done
        done < <(section "$f" addr | awk '{split($4,a,"/"); print $2, a[1]}')
        if (( ${#hits[@]} == 0 )); then
            RNIC[$k,$r]=-; RIP[$k,$r]=none; RSTATE[$k,$r]="no address in ${RAIL_SPEC[$r]// /,}"; return
        fi
        nic=${hits[0]% *}; ip=${hits[0]#* }
        for n in "${hits[@]}"; do
            [[ ${n% *} == "$nic" ]] || { RNIC[$k,$r]=-; RIP[$k,$r]=none; RSTATE[$k,$r]="AMBIGUOUS: ${#hits[@]} NICs in ${RAIL_SPEC[$r]// /,}"; return; }
        done
    fi
    RNIC[$k,$r]=$nic; RIP[$k,$r]=$ip
    local line; line=$(section "$f" link | awk -v n="$nic" '{x=$2; sub(/:$/,"",x); sub(/@.*/,"",x)} x==n {print; exit}')
    RMTU[$k,$r]=$(awk '{for (i = 1; i < NF; i++) if ($i == "mtu") print $(i+1)}' <<<"$line")
    if [[ $line != *LOWER_UP* ]]; then RSTATE[$k,$r]="link DOWN on $nic"
    else RSTATE[$k,$r]=ok; fi
}

rail_ok() { [[ ${RSTATE[$1,$2]} == ok ]]; }
rail_letter() { [[ $1 == 0 ]] && echo A || echo B; }

# Swapped rails by NIC name (subnet mode): a host whose rail-A NIC is the name most hosts
# use for rail B, and the reverse, has its IPs or cables swapped.
rail_consistency() {
    [[ $RAIL_MODE == cidr ]] || return 0
    local maj k r; maj=$(for k in "${ELIG[@]}"; do for r in 0 1; do [[ ${RNIC[$k,$r]} != - ]] && echo "$r ${RNIC[$k,$r]}"; done; done |
        awk '{c[$1 " " $2]++} END {for (x in c) {split(x, p, " "); if (c[x] > b[p[1]]) {b[p[1]] = c[x]; m[p[1]] = p[2]}} print m[0] " " m[1]}')
    local ma=${maj% *} mb=${maj#* } n=0
    [[ -n $ma && -n $mb && $ma != "$mb" ]] || return 0
    for k in "${ELIG[@]}"; do
        if [[ ${RNIC[$k,0]} == "$mb" && ${RNIC[$k,1]} == "$ma" ]]; then
            echo "${T_HOST[$k]} swapped_nics rail A is on $mb and rail B on $ma, the reverse of most hosts (A=$ma, B=$mb): IPs or cables swapped" >> "$COLLECT_DIR/rail_anomalies.txt"; n=$(( n + 1 ))
        elif [[ ${RNIC[$k,0]} == "$mb" || ${RNIC[$k,1]} == "$ma" ]]; then
            echo "${T_HOST[$k]} rail_nic_overlap rail A on ${RNIC[$k,0]}, rail B on ${RNIC[$k,1]}; most hosts use A=$ma, B=$mb" >> "$COLLECT_DIR/rail_anomalies.txt"; n=$(( n + 1 ))
        fi
    done
    (( n )) && { log "WARNING: $n hosts have rail NICs the other way round from most hosts:"; grep -E ' swapped_nics | rail_nic_overlap ' "$COLLECT_DIR/rail_anomalies.txt" | sed 's/^/#   /' | head -n 10 >&2; }
    return 0
}

# Each usable rail's gateway(s) must answer a full-MTU no-fragment ping (routed rails only).
gateway_check() {
    local k r j
    : > "$COLLECT_DIR/gateways.txt"
    for k in "${ELIG[@]}"; do for r in 0 1; do
        rail_ok $k $r || continue
        local -a peers=()
        for j in "${ELIG[@]}"; do [[ $j != "$k" ]] && rail_ok $j $r && peers+=("${RIP[$j,$r]}"); done
        (( ${#peers[@]} )) || continue
        throttle
        ( out=$(rbash "${T_TARGET[$k]}" "${RIP[$k,$r]}" "${RNIC[$k,$r]}" $(( ${RMTU[$k,$r]:-1500} - 28 )) "${peers[@]}" <<<"$GW_SCRIPT" 2>&1)
          while read -r line; do [[ -n $line ]] && echo "${T_HOST[$k]} $(rail_letter $r) ${RIP[$k,$r]} $line"; done <<<"${out:-SSH no output}" > "$WORK/gw.$k.$r" ) &
    done; done
    wait
    cat "$WORK"/gw.* 2>&1 | grep -v 'No such file' | sort -V > "$COLLECT_DIR/gateways.txt"
    local direct ok bad
    direct=$(grep -c ' DIRECT$' "$COLLECT_DIR/gateways.txt"); ok=$(grep -c ' OK$' "$COLLECT_DIR/gateways.txt")
    bad=$(grep -v -E ' (DIRECT|OK)$' "$COLLECT_DIR/gateways.txt")
    log "Rail gateways: $ok answered a full-MTU no-fragment ping, $direct rails have no gateway (peers on-link)"
    if [[ -n $bad ]]; then
        log "WARNING: rail gateways that failed (MTU = answers only small pings):"; echo "$bad" | sed 's/^/#   /' >&2
        echo "$bad" | awk '{print $1, "gateway_" $NF, "rail", $2, $3, "gateway", $5}' >> "$COLLECT_DIR/rail_anomalies.txt"
    fi
}

# FS_MESH=1: every usable rail IP of each tested host pings every other tested host's usable rail IPs.
mesh_check() {
    local k j r total=0 a b
    local -A host_of=()
    for j in "${ELIG[@]}"; do for r in 0 1; do rail_ok $j $r && host_of[${RIP[$j,$r]}]=${T_HOST[$j]}; done; done
    log "Mesh: every rail IP pings the ${#host_of[@]} rail IPs of the other tested hosts..."
    for k in "${ELIG[@]}"; do
        local -a dst=()
        for j in "${ELIG[@]}"; do [[ $j != "$k" ]] || continue; for r in 0 1; do rail_ok $j $r && dst+=("${RIP[$j,$r]}"); done; done
        a=none; b=none; rail_ok $k 0 && a=${RIP[$k,0]}; rail_ok $k 1 && b=${RIP[$k,1]}
        [[ $a == none && $b == none ]] && continue
        local srcs=0; [[ $a != none ]] && srcs=$(( srcs + 1 )); [[ $b != none ]] && srcs=$(( srcs + 1 ))
        total=$(( total + srcs * ${#dst[@]} ))
        throttle
        ( rbash "${T_TARGET[$k]}" "$a" "$b" "${dst[@]}" <<<"$MESH_SCRIPT" > "$WORK/mesh.$k" 2>&1 ) &
    done
    wait
    cat "$WORK"/mesh.* 2>&1 | awk '$1 == "MESHFAIL" {print $2, $3}' | while read -r s d; do
        echo "${host_of[$s]:-?} $s ${host_of[$d]:-?} $d"
    done | sort -V > "$COLLECT_DIR/mesh_failures.txt"
    local fails; fails=$(wc -l < "$COLLECT_DIR/mesh_failures.txt" | tr -d ' ')
    log "Mesh: $total pings, $fails failed"
    MESH_PINGS=$total; MESH_FAILS=$fails
    (( fails )) || return 0
    local ip; for ip in "${!host_of[@]}"; do echo "$ip ${host_of[$ip]}"; done > "$WORK/meship"
    # A source whose pings fail to every peer gets no replies at all (its inbound ICMP or rail is
    # blocked): report it once as the source and keep its failures out of the destination counts.
    # Otherwise a destination failing from many sources points at that rail.
    # Peers of an IP = every rail IP except its own host's; sources of a destination likewise,
    # minus the silent sources on other hosts.
    awk 'FNR == 1 {f++}
         f == 1 {hof[$1] = $2; c[$2]++; all++; next}
         {m++; s[m] = $2; d[m] = $4; fs[$2]++}
         END {
             for (x in fs) if (fs[x] >= all - c[hof[x]]) {dead[x] = 1; nd++; deadon[hof[x]]++}
             for (x in dead) printf "%s mesh_no_replies rail IP %s got no reply from any of its %d peers (inbound ICMP blocked or rail down on that host)\n", hof[x], x, all - c[hof[x]]
             for (i = 1; i <= m; i++) if (!(s[i] in dead)) n[d[i]]++
             for (x in n) printf "%s mesh_unreachable rail IP %s did not answer %d of %d pinging rail IPs\n", hof[x], x, n[x], all - c[hof[x]] - (nd - deadon[hof[x]])
         }' "$WORK/meship" "$COLLECT_DIR/mesh_failures.txt" | sort -k2,2 -k7,7rn > "$WORK/mesh_anom"
    cat "$WORK/mesh_anom" >> "$COLLECT_DIR/rail_anomalies.txt"
    log "WARNING: mesh findings (silent sources first, then destinations, worst first):"
    sed 's/^/#   /' "$WORK/mesh_anom" | head -n 10 >&2
}

# LLDP: a rail NIC whose switch most hosts reach on the other rail is cabled to the wrong rail.
lldp_rail_check() {
    local railmap=$WORK/railmap k r
    for k in "${ELIG[@]}"; do for r in 0 1; do
        [[ ${RNIC[$k,$r]} != - ]] && echo "${T_HOST[$k]} ${RNIC[$k,$r]} $(rail_letter $r)"
    done; done > "$railmap"
    awk 'FNR == 1 {f++}
         f == 1 {rail[$1 " " $2] = $3; next}
         $4 != "unknown" && (($1 " " $2) in rail) {n++; h[n] = $1; nic[n] = $2; sw[n] = $4; rl[n] = rail[$1 " " $2]; c[$4 " " rl[n]]++}
         END {for (i = 1; i <= n; i++) {o = (rl[i] == "A") ? "B" : "A"
                  if (c[sw[i] " " o] > c[sw[i] " " rl[i]])
                      printf "%s lldp_wrong_rail rail %s NIC %s is cabled to %s, which %d other NICs reach on rail %s\n", h[i], rl[i], nic[i], sw[i], c[sw[i] " " o], o}}' \
        "$railmap" "$1" > "$WORK/lldp_anom"
    if [[ -s $WORK/lldp_anom ]]; then
        log "WARNING: $(wc -l < "$WORK/lldp_anom" | tr -d ' ') rail NICs are cabled to a switch that serves the other rail (LLDP):"
        sed 's/^/#   /' "$WORK/lldp_anom" | head -n 10 >&2
        cat "$WORK/lldp_anom" >> "$COLLECT_DIR/rail_anomalies.txt"
    fi
}

# round_pairs r: round r of the circle method over ROT (even length, "-" = bye).
# ROT[0] stays put and the rest rotate one place per round, so no pair repeats
# until every pair has met (${#ROT[@]} - 1 rounds). Sets PC/PS (client/server) and SITOUT.
round_pairs() {
    local r=$1 m=${#ROT[@]} i a b
    local -a arr=("${ROT[0]}")
    for (( i = 0; i < m - 1; i++ )); do arr+=("${ROT[1 + (i + r) % (m - 1)]}"); done
    PC=(); PS=(); SITOUT=""
    for (( i = 0; i < m / 2; i++ )); do
        a=${arr[i]}; b=${arr[m - 1 - i]}
        if [[ $a == - ]]; then SITOUT=$b
        elif [[ $b == - ]]; then SITOUT=$a
        else PC+=("$a"); PS+=("$b"); fi
    done
}

# check_path key src_k src_r dst_k dst_r: writes OK or a reason to $PATHS/key
check_path() {
    local key=$1 sk=$2 sr=$3 dk=$4 dr=$5
    if ! rail_ok $sk $sr; then echo "DOWN ${T_HOST[$sk]}: ${RSTATE[$sk,$sr]}" > "$PATHS/$key"; return; fi
    if ! rail_ok $dk $dr; then echo "DOWN ${T_HOST[$dk]}: ${RSTATE[$dk,$dr]}" > "$PATHS/$key"; return; fi
    local m1=${RMTU[$sk,$sr]:-1500} m2=${RMTU[$dk,$dr]:-1500}
    # the larger MTU: a 1500/9000 pair must fail here, not pass at 1472 and run with retransmits
    local size=$(( (m1 > m2 ? m1 : m2) - 28 ))
    ( out=$(rbash "${T_TARGET[$sk]}" "${RIP[$sk,$sr]}" "${RIP[$dk,$dr]}" "${RNIC[$sk,$sr]}" $size <<<"$PATH_SCRIPT" 2>&1)
      echo "${out:-SSH no output}" | tail -n1 > "$PATHS/$key" ) &
}

# run_path key src_k src_r dst_k dst_r [udp]: one iperf3 run, appends to $PHASE_OUT
run_path() {
    local key=$1 sk=$2 sr=$3 dk=$4 dr=$5 mode=${6:-tcp} st
    st=$(cat "$PATHS/$key")
    if [[ $st != OK ]]; then
        echo "$ITER $PHASE ${T_HOST[$sk]} ${RIP[$sk,$sr]} ${T_HOST[$dk]} ${RIP[$dk,$dr]} $st" >> "$PATH_EXCL"
        log "  skip ${T_HOST[$sk]} ${RIP[$sk,$sr]} -> ${T_HOST[$dk]} ${RIP[$dk,$dr]}: $st"
        return
    fi
    if [[ $mode == udp ]]; then
        local m1=${RMTU[$sk,$sr]:-1500} m2=${RMTU[$dk,$dr]:-1500}
        local len=$(( (m1 < m2 ? m1 : m2) - 28 ))   # largest datagram that needs no fragmenting
        ( out=$(timeout $(( FS_UDP_DURATION + 30 )) ssh "${SSH_OPTS[@]}" "${T_TARGET[$sk]}" $SUDO bash -s -- \
                  "${RIP[$sk,$sr]}" "${RIP[$dk,$dr]}" "$FS_PORT" "$FS_STREAMS" "$FS_UDP_DURATION" "$len" "$FS_TOS" <<<"$UDP_SCRIPT" 2>&1)
          [[ -n $out ]] || out="ERROR timeout or ssh failure"
          echo "${RIP[$sk,$sr]},${RIP[$dk,$dr]},${out%%$'\n'*}" >> "$PHASE_OUT" ) &
        return
    fi
    ( out=$(timeout $(( FS_DURATION + 30 )) ssh "${SSH_OPTS[@]}" "${T_TARGET[$sk]}" $SUDO bash -s -- \
              "${RIP[$sk,$sr]}" "${RIP[$dk,$dr]}" "$FS_PORT" "$FS_STREAMS" "$FS_DURATION" "$FS_TOS" <<<"$IPERF_SCRIPT" 2>&1)
      [[ -n $out ]] || out="ERROR timeout or ssh failure"
      echo "${RIP[$sk,$sr]},${RIP[$dk,$dr]},${out%%$'\n'*}" >> "$PHASE_OUT" ) &
}

collect_counters() {  # script outfile: run a counter script on every tested host
    local script=$1 outfile=$2 k
    : > "$outfile"
    for k in "${ELIG[@]}"; do
        rbash "${T_TARGET[$k]}" "${RNIC[$k,0]}" "${RNIC[$k,1]}" <<<"$script" >> "$outfile" 2>> "$RUNLOG_SSH" &
    done
    wait
}

# UDP loss placement, the same rule as the dashboard: per phase and receiving host,
# unaccounted = lost - (that host's InErrors + backlog drops + rail-NIC rx drops), floored at 0.
# Files: ipmap (ip host rail), nicmap (host_nic host), UDP results, host counters, NIC drops.
# -v t="iterN Ux" limits it to one phase. Prints: lost sent socket nic backlog unaccounted.
UDP_ATTR_AWK='
FNR == 1 { f++ }
f == 1 { host[$1] = $2; next }
f == 2 { nh[$1] = $2; next }
f == 3 { if (/^### /) { split($2, a, ":"); split($3, b, ":"); ph = "iter" a[2] " " b[2]; next }
         if (t != "" && ph != t) next
         n = 0; for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+\/[0-9]+$/) { split($i, x, "/"); n = 1 }
         if (!n) next
         split($1, s, ","); k = ph SUBSEP host[s[2]]; L[k] += x[1]; sent += x[2]; next }
f == 4 { k = $1 " " $2 SUBSEP $3; SK[k] += $4; BK[k] += $7; next }
f == 5 { k = $1 " " $2 SUBSEP nh[$3]; NK[k] += $4 + $5 }
END { for (k in L) { lost += L[k]; sock += SK[k]; nic += NK[k]; back += BK[k]
                     u = L[k] - SK[k] - NK[k] - BK[k]; if (u > 0) un += u }
      printf "%d %d %d %d %d %d\n", lost, sent, sock, nic, back, un }'

udp_attr() {  # [iterN Ux] -> "lost sent socket nic backlog unaccounted"
    awk -v t="$1" "$UDP_ATTR_AWK" "$WORK/ipmap" "$WORK/nicmap" "$UDP_RESULTS" \
        "$COLLECT_DIR/udp_host_counters.txt" "$COLLECT_DIR/udp_nic_drops.txt"
}

# UDP phases U1 (same rail) and U2 (cross) on the current pairs, with host and NIC
# counters read around each phase so lost datagrams can be placed.
udp_phases() {
    local u p ck sk a=$WORK/udp.0
    collect_counters "$UDPHOST_SCRIPT" "$a.host"; collect_drops "$a.nic"
    for u in 1 2; do
        PHASE=U$u; PHASE_OUT=$WORK/phase.$ITER.$PHASE; : > "$PHASE_OUT"
        [[ $u == 1 ]] && log "Phase U1: UDP A->A and B->B at once (-b 0)" || log "Phase U2: UDP A->B both directions at once (-b 0)"
        echo "### iteration:${ITER} phase:${PHASE}" >> "$UDP_RESULTS"
        for (( p = 0; p < ${#PC[@]}; p++ )); do
            ck=${PC[p]}; sk=${PS[p]}
            if [[ $u == 1 ]]; then run_path p1a_$p $ck 0 $sk 0 udp; run_path p1b_$p $sk 1 $ck 1 udp
            else run_path p2a_$p $ck 0 $sk 1 udp; run_path p2b_$p $sk 0 $ck 1 udp; fi
        done
        wait
        column -t < "$PHASE_OUT" | tee -a "$UDP_RESULTS"
        local b=$WORK/udp.$u
        collect_counters "$UDPHOST_SCRIPT" "$b.host"; collect_drops "$b.nic"
        # deltas: "iterN Uu host dInErrors dRcvbufErrors dSndbufErrors dSoftnet" and "iterN Uu host_nic drx doob"
        awk -v t="iter$ITER $PHASE" 'NR==FNR {for (i = 2; i <= 5; i++) p[$1, i] = $i; next}
            ($1, 2) in p {printf "%s %s", t, $1; for (i = 2; i <= 5; i++) printf " %d", $i - p[$1, i]; print ""}' \
            "$a.host" "$b.host" >> "$COLLECT_DIR/udp_host_counters.txt"
        awk -v t="iter$ITER $PHASE" 'NR==FNR {rx[$1] = $3; oob[$1] = $5; next} ($1 in rx) {
                drx = ($3 ~ /^[0-9]+$/ && rx[$1] ~ /^[0-9]+$/) ? $3 - rx[$1] : 0
                doob = ($5 ~ /^[0-9]+$/ && oob[$1] ~ /^[0-9]+$/) ? $5 - oob[$1] : 0
                print t, $1, drx, doob }' "$a.nic" "$b.nic" >> "$COLLECT_DIR/udp_nic_drops.txt"
        local r; read -r -a r <<<"$(udp_attr "iter$ITER $PHASE")"
        log "  $PHASE loss: ${r[0]} of ${r[1]} datagrams lost ($(awk -v l="${r[0]}" -v s="${r[1]}" 'BEGIN {printf "%.3f", s ? 100 * l / s : 0}')%): receiver socket ${r[2]}, NIC ${r[3]}, kernel backlog ${r[4]}, unaccounted ${r[5]}"
        a=$b
    done
}

# fec_deltas label seconds: per-NIC FEC counter changes over the iteration, appended to
# fec_rates.txt as "label host_nic seconds d_corrected_blocks d_uncorrectable_blocks d_corrected_bits d_symbol_errors"
# (na = not exposed, reset = counter went backwards). Links carry symbols even when idle, so wall time is the right base.
fec_deltas() {
    awk -v t="$1" -v s="$2" 'NR==FNR {for (i = 2; i <= 5; i++) p[$1, i] = $i; next}
        ($1, 2) in p {printf "%s %s %d", t, $1, s
            for (i = 2; i <= 5; i++) printf " %s", ($i ~ /^[0-9]+$/ && p[$1, i] ~ /^[0-9]+$/) ? ($i + 0 >= p[$1, i] + 0 ? $i - p[$1, i] : "reset") : "na"
            print ""}' "$WORK/fec_pre" "$WORK/fec_post" > "$WORK/fec_delta"
    cat "$WORK/fec_delta" >> "$COLLECT_DIR/fec_rates.txt"
    local seen unc
    seen=$(awk '$4 ~ /^[0-9]+$/ || $6 ~ /^[0-9]+$/' "$WORK/fec_delta" | wc -l | tr -d ' ')
    unc=$(awk '$5 ~ /^[0-9]+$/ && $5 > 0 {printf "%s(%s) ", $2, $5}' "$WORK/fec_delta")
    log "FEC over ${2}s: counters exposed on $seen of $(wc -l < "$WORK/fec_delta" | tr -d ' ') rail NICs"
    [[ -n $unc ]] && log "WARNING: uncorrectable FEC blocks (errors reach the host): $unc"
    return 0
}

collect_drops() {
    local outfile=$1 k
    : > "$outfile"
    for k in "${ELIG[@]}"; do
        rbash "${T_TARGET[$k]}" "${RNIC[$k,0]}" "${RNIC[$k,1]}" <<<"$DROPS_SCRIPT" >> "$outfile" 2>> "$RUNLOG_SSH" &
    done
    wait
    sort -o "$outfile" "$outfile"
}

compute_drops() {
    awk -v label="$3" '
        NR==FNR { pre[$1]=$3" "$4" "$5; next }
        ($1 in pre) {
            split(pre[$1], p, " ")
            drx = ($3 ~ /^[0-9]+$/ && p[1] ~ /^[0-9]+$/) ? $3 - p[1] : 0
            dtx = ($4 ~ /^[0-9]+$/ && p[2] ~ /^[0-9]+$/) ? $4 - p[2] : 0
            doob = ($5 ~ /^[0-9]+$/ && p[3] ~ /^[0-9]+$/) ? $5 - p[3] : 0
            if (drx > 0 || dtx > 0 || doob > 0)
                printf "%s %s %s rx_drop:%d tx_drop:%d rx_oob:%d %s\n", $1, $2, label, drx, dtx, doob, label
        }' "$1" "$2"
}

stop_servers() {
    (( ${#STARTED[@]} > 0 )) || return 0
    local k
    log "Stopping iperf3 on ${#STARTED[@]} hosts..."
    for k in "${!STARTED[@]}"; do rsh "${T_TARGET[$k]}" $SUDO pkill -x iperf3 >> "$WORK/cleanup.log" 2>&1 & done
    wait
    STARTED=()
}

cleanup() {
    local rc=$? k   # first: bash 5.1 would otherwise end a piped main with cleanup's last status
    trap '' INT TERM   # a second Ctrl-C must not cut cleanup short (iperf3 left running)
    stop_servers
    for k in "${T_TARGET[@]}" "${!REACH_ONLY[@]}"; do
        ssh -O exit -o "ControlPath=$SOCKET_DIR/%C" -l "$FS_SSH_USER" "$k" >> "$WORK/cleanup.log" 2>&1 &
    done
    wait
    if [[ -z $DONE ]]; then
        if [[ -n $LOADED ]]; then { [[ -f $FS_RUNLOG ]] && cp "$FS_RUNLOG" "$COLLECT_DIR/run.log"; log "Run did not finish; partial data left in $COLLECT_DIR"; }
        else rm -rf "${COLLECT_DIR:?}"; fi
    fi
    rm -rf "${SOCKET_DIR:?}" "${WORK:?}"
    exit $rc
}

# ======================================================================

main() {
    (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) )) || die "needs bash 4.3+"
    [[ $1 == -h || $1 == --help ]] && { usage; exit 0; }

    : "${FS_ITER:=5}" "${FS_STREAMS:=16}" "${FS_PORT:=5201}" "${FS_SSH_USER:=root}"
    : "${FS_SSH_PARALLEL:=64}" "${FS_SSH_RETRY_PARALLEL:=8}" "${FS_MAX_TARGETS:=4096}" "${FS_OUT_DIR:=.}"
    : "${FS_OK_PCT:=75}" "${FS_SLOW_PCT:=50}" "${FS_BUSY_OK:=0}"
    # Default busy check: any WEKA container in STATE Running (docs.weka.io CLI reference, `weka local ps`)
    : "${FS_BUSY_CHECK:=$WEKA_BUSY_CHECK}"
    [[ $FS_BUSY_CHECK == none ]] && FS_BUSY_CHECK=""
    [[ $1 =~ ^[0-9]+$ ]] && FS_DURATION=$1
    : "${FS_DURATION:=120}" "${FS_UDP:=0}" "${FS_MESH:=0}"
    : "${FS_UDP_DURATION:=$FS_DURATION}"
    [[ $FS_UDP == 0 || $FS_UDP == 1 ]] || die "FS_UDP must be 0 or 1, got '$FS_UDP'"
    [[ $FS_MESH == 0 || $FS_MESH == 1 ]] || die "FS_MESH must be 0 or 1, got '$FS_MESH'"
    local v
    for v in FS_DURATION FS_UDP_DURATION FS_ITER FS_STREAMS FS_PORT FS_SSH_PARALLEL FS_SSH_RETRY_PARALLEL FS_MAX_TARGETS FS_OK_PCT FS_SLOW_PCT; do
        [[ ${!v} =~ ^[0-9]+$ ]] && (( ${!v} > 0 )) || die "$v must be a positive integer, got '${!v}'"
    done
    (( FS_STREAMS >= 2 )) || die "FS_STREAMS must be >= 2 (iperf3 prints no [SUM] line for one stream)"
    [[ -z $FS_LINE_GBPS || $FS_LINE_GBPS =~ ^[0-9]+$ ]] || die "FS_LINE_GBPS must be an integer"
    [[ -z $FS_EXPECT_HOSTS || $FS_EXPECT_HOSTS =~ ^[1-9][0-9]*$ ]] || die "FS_EXPECT_HOSTS must be a positive integer"
    [[ -z $FS_TOS || ( $FS_TOS =~ ^[0-9]{1,3}$ && 10#$FS_TOS -le 255 ) ]] || die "FS_TOS must be 0-255 (decimal), got '$FS_TOS'"
    [[ -n $FS_TOS ]] && FS_TOS=$(( 10#$FS_TOS ))

    expand_targets "$FS_HOSTS"
    if [[ $1 == --list ]]; then printf '%s\n' "${TARGETS[@]}"; log "${#TARGETS[@]} targets"; exit 0; fi

    local c
    for c in ssh timeout column sort awk tar; do [[ -n $(command -v $c) ]] || die "'$c' not found on this machine"; done
    [[ -d $FS_OUT_DIR && -w $FS_OUT_DIR ]] || die "FS_OUT_DIR '$FS_OUT_DIR' is not a writable directory"

    WORK=$(mktemp -d /tmp/fs_work.XXXXXX)
    SOCKET_DIR=$(mktemp -d /tmp/fs_ssh.XXXXXX)
    COLLECT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dp_validation_XXXXXX")
    RAW_DIR=$COLLECT_DIR/raw_per_host; mkdir -p "$RAW_DIR" "$WORK/disc" "$WORK/sweep"
    RUNLOG_SSH=$COLLECT_DIR/ssh_errors.log

    SUDO=""; [[ $FS_SSH_USER == root ]] || SUDO="sudo -n"
    SSH_OPTS=(-o ControlMaster=auto -o ControlPersist=15m -o "ControlPath=$SOCKET_DIR/%C"
              -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5
              -o ServerAliveInterval=15 -l "$FS_SSH_USER")
    declare -gA T_TARGET T_HOST DISC RNIC RIP RMTU RSTATE STARTED REACH_ONLY DOWN_IP
    trap cleanup EXIT
    # explicit exits so the EXIT trap always runs on Ctrl-C or kill, whatever command was running
    trap 'exit 130' INT; trap 'exit 143' TERM
    parse_rails
    log "Begin $(date) | ${#TARGETS[@]} targets | rails: $RAIL_MODE A=${RAIL_SPEC[0]// /,} B=${RAIL_SPEC[1]// /,} | ${FS_DURATION}s x $FS_ITER iterations"

    # --- 1. reachability sweep (capped) ---
    local i t
    log "Sweeping ${#TARGETS[@]} targets over ssh, $FS_SSH_PARALLEL at a time..."
    for i in "${!TARGETS[@]}"; do
        throttle
        t=${TARGETS[$i]}
        ( if rsh "$t" true 2> "$WORK/sweep/$i.err"; then echo "$i" > "$WORK/sweep/$i.ok"; fi ) &
    done
    wait
    # refusals under fan-out (sshd MaxStartups, kex resets) look like dead hosts: retry those slower
    local -a retry=()
    for i in "${!TARGETS[@]}"; do
        [[ -f $WORK/sweep/$i.ok ]] && continue
        grep -q -i -E 'connection reset|kex_exchange_identification|ssh_exchange_identification|connection closed by|too many' \
            "$WORK/sweep/$i.err" && retry+=("$i")
    done
    if (( ${#retry[@]} )); then
        log "Retrying ${#retry[@]} targets that refused under load, $FS_SSH_RETRY_PARALLEL at a time..."
        local attempt keep=$FS_SSH_PARALLEL; FS_SSH_PARALLEL=$FS_SSH_RETRY_PARALLEL
        for attempt in 1 2; do
            for i in "${retry[@]}"; do
                [[ -f $WORK/sweep/$i.ok ]] && continue
                throttle; t=${TARGETS[$i]}
                ( if rsh "$t" true 2> "$WORK/sweep/$i.err"; then echo "$i" > "$WORK/sweep/$i.ok"; fi ) &
            done
            wait; sleep 1
        done
        FS_SSH_PARALLEL=$keep
        local rec=0; for i in "${retry[@]}"; do [[ -f $WORK/sweep/$i.ok ]] && rec=$(( rec + 1 )); done
        log "Retry recovered $rec of ${#retry[@]}"
    fi
    local -a REACH=()
    for i in "${!TARGETS[@]}"; do
        if [[ -f $WORK/sweep/$i.ok ]]; then REACH+=("$i")
        else
            local why; why=$(grep -v '^Warning: Permanently added' "$WORK/sweep/$i.err" | tail -n1)
            echo "${TARGETS[$i]} ${why:-no error text}" >> "$WORK/unreachable.txt"
        fi
    done
    if [[ -s $WORK/unreachable.txt ]]; then
        log "$(wc -l < "$WORK/unreachable.txt" | tr -d ' ') of ${#TARGETS[@]} targets unreachable, by reason:"
        awk '{$1=""; sub(/^ /,""); sub(/^ssh: connect to host [^ ]+ port [0-9]+: /,""); print}' "$WORK/unreachable.txt" \
            | sort | uniq -c | sort -rn | sed 's/^/#   /' >&2
        cp "$WORK/unreachable.txt" "$COLLECT_DIR/unreachable.txt"
    fi
    (( ${#REACH[@]} > 0 )) || die "no target answered ssh as $FS_SSH_USER"

    # --- 2. discovery ---
    log "Discovering ${#REACH[@]} hosts..."
    for i in "${REACH[@]}"; do
        throttle
        rbash "${TARGETS[$i]}" <<<"BUSY_CHECK=$(printf '%q' "$FS_BUSY_CHECK")"$'\n'"$DISCOVER_SCRIPT" \
            > "$WORK/disc/$i" 2>> "$RUNLOG_SSH" &
    done
    wait

    # dedupe: the same host can answer on several targets (mgmt and data IPs in one CIDR)
    local -A SEEN_ID=()
    local k=0 id host dups=0
    for i in "${REACH[@]}"; do
        host=$(section "$WORK/disc/$i" hostname | head -n1)
        [[ -n $host ]] || { echo "${TARGETS[$i]} discovery returned nothing" >> "$COLLECT_DIR/unreachable.txt"; continue; }
        id=$(section "$WORK/disc/$i" machine-id | head -n1)
        [[ $id =~ ^[0-9a-f]{32}$ ]] || id=$host
        if [[ -n ${SEEN_ID[$id]+x} ]]; then
            dups=$(( dups + 1 )); REACH_ONLY[${TARGETS[$i]}]=1
            echo "${TARGETS[$i]} same host as ${SEEN_ID[$id]}" >> "$COLLECT_DIR/excluded.txt"
            continue
        fi
        SEEN_ID[$id]=$host
        T_TARGET[$k]=${TARGETS[$i]}; T_HOST[$k]=$host; DISC[$k]=$WORK/disc/$i
        k=$(( k + 1 ))
    done
    (( dups > 0 )) && log "$dups targets were a second address of a host already found; using the first"

    if [[ $RAIL_MODE == none ]]; then
        log "No rail subnets or NIC names set. IPv4 subnets on the reachable hosts (hosts, NIC, subnet):"
        for k in "${!T_TARGET[@]}"; do
            section "${DISC[$k]}" addr | awk '$2!="lo" {print $2, $4}' | while read -r n a; do
                local b; b=$(cidr_bounds "$a") && echo "$n $(int2ip ${b% *})/${a#*/}"
            done
        done | sort | uniq -c | sort -rn | sed 's/^/#   /' >&2
        die "set FS_RAIL_A and FS_RAIL_B (subnets per rail), FS_RAILS (one per rail), or FS_NICS (two NIC names)"
    fi

    # --- 3. rails, eligibility, preflight ---
    local -a ELIG=() NO_IPERF=() BUSY=()
    local r rc
    for k in "${!T_TARGET[@]}"; do
        rail_lookup $k 0; rail_lookup $k 1
        if [[ ${RNIC[$k,0]} == - && ${RNIC[$k,1]} == - ]]; then
            echo "${T_TARGET[$k]} ${T_HOST[$k]} not on data rails" >> "$COLLECT_DIR/excluded.txt"; continue
        fi
        if [[ ${RNIC[$k,0]} != - && ${RNIC[$k,0]} == "${RNIC[$k,1]}" ]]; then
            echo "${T_TARGET[$k]} ${T_HOST[$k]} both rails on one NIC ${RNIC[$k,0]}" >> "$COLLECT_DIR/excluded.txt"; continue
        fi
        ELIG+=("$k")
        section "${DISC[$k]}" tools | grep -q '^iperf3 /' || NO_IPERF+=("${T_HOST[$k]}")
        if [[ -n $FS_BUSY_CHECK ]]; then
            rc=$(section "${DISC[$k]}" busy | sed -n '1s/^rc=//p')
            if [[ $rc == 0 ]]; then BUSY+=("${T_HOST[$k]}(in use)")
            elif [[ $rc != 1 ]]; then BUSY+=("${T_HOST[$k]}(check rc=${rc:-none})"); fi
        fi
        for r in 0 1; do
            [[ ${RSTATE[$k,$r]} == ok ]] || { [[ ${RIP[$k,$r]} != none ]] && DOWN_IP[${RIP[$k,$r]}]=1; }
        done
    done
    local not_rail; not_rail=$(grep -c 'not on data rails' "$COLLECT_DIR/excluded.txt" 2>&1)
    [[ $not_rail =~ ^[0-9]+$ && $not_rail -gt 0 ]] && log "$not_rail reachable hosts have no address on either rail; left out"
    (( ${#ELIG[@]} >= 2 )) || die "need at least 2 hosts on the rails, found ${#ELIG[@]} (see $COLLECT_DIR/excluded.txt)"
    (( ${#NO_IPERF[@]} == 0 )) || die "iperf3 missing on ${#NO_IPERF[@]} hosts: ${NO_IPERF[*]}"
    if (( ${#BUSY[@]} > 0 )); then
        if [[ $FS_BUSY_OK != 1 ]]; then
            die "FS_BUSY_CHECK: ${#BUSY[@]} hosts in use or check failed: ${BUSY[*]:0:10}. Line-rate load can starve cluster heartbeats and get nodes evicted. Stop the cluster's I/O and set FS_BUSY_OK=1 to proceed."
        fi
        log "WARNING: ${#BUSY[@]} hosts in use per FS_BUSY_CHECK; FS_BUSY_OK=1 given"
        for k in "${ELIG[@]}"; do
            echo "== ${T_HOST[$k]}"; section "${DISC[$k]}" busy
        done > "$COLLECT_DIR/busy_check.txt"
    fi

    # iperf3 build and socket-buffer limits per host (UDP ceilings depend on both)
    for k in "${ELIG[@]}"; do
        echo "${T_HOST[$k]} $(section "${DISC[$k]}" iperf3 | awk '{print $2; exit}') $(section "${DISC[$k]}" sysctl | awk '{printf "%s ", $2}')"
    done | sort -V > "$COLLECT_DIR/iperf3_versions.txt"
    if [[ $FS_UDP == 1 ]]; then
        # before 3.16 iperf3 runs every stream in one thread, so UDP tops out on host CPU
        local old; old=$(awk 'NF >= 2 && $2 ~ /^[0-9]/ { split($2, v, "."); if (v[1] < 3 || (v[1] == 3 && v[2] < 16)) printf "%s(%s) ", $1, $2 }' "$COLLECT_DIR/iperf3_versions.txt")
        [[ -n $old ]] && log "WARNING: iperf3 older than 3.16 (single-threaded, UDP ceiling is host CPU-bound): $old"
        local small; small=$(awk '$3 ~ /^[0-9]+$/ && $3 < 4194304 { printf "%s(%s) ", $1, $3 }' "$COLLECT_DIR/iperf3_versions.txt")
        [[ -n $small ]] && log "NOTE: net.core.rmem_max under 4 MiB, receiver-socket UDP loss will be inflated: $small"
    fi

    # rail table: what an engineer checks before load starts
    {
        echo "Host Target Rail_A_NIC Rail_A_IP MTU_A State_A Rail_B_NIC Rail_B_IP MTU_B State_B"
        for k in "${ELIG[@]}"; do
            echo "${T_HOST[$k]} ${T_TARGET[$k]} ${RNIC[$k,0]} ${RIP[$k,0]} ${RMTU[$k,0]:--} ${RSTATE[$k,0]// /_} ${RNIC[$k,1]} ${RIP[$k,1]} ${RMTU[$k,1]:--} ${RSTATE[$k,1]// /_}"
        done | sort -V
    } | column -t > "$COLLECT_DIR/rails.txt"
    local bad_rails; bad_rails=$(awk 'NR>1 && ($6!="ok" || $10!="ok")' "$COLLECT_DIR/rails.txt")
    log "${#ELIG[@]} hosts on the rails. Rail NIC names and MTUs seen (count, NIC, MTU):"
    for k in "${ELIG[@]}"; do for r in 0 1; do echo "rail_$([[ $r == 0 ]] && echo A || echo B) ${RNIC[$k,$r]} mtu=${RMTU[$k,$r]:--}"; done; done \
        | sort | uniq -c | sed 's/^/#   /' >&2
    if [[ -n $bad_rails ]]; then
        log "Rails not usable (paths through them are skipped):"
        echo "$bad_rails" | sed 's/^/#   /' >&2
    else
        log "All rails on all ${#ELIG[@]} hosts have an address and link"
    fi
    : > "$COLLECT_DIR/rail_anomalies.txt"   # preflight findings: host kind detail...
    # one MTU per rail expected; name the odd hosts (their paths fail the no-fragment check)
    local rr
    for rr in 0 1; do
        local mt; mt=$(for k in "${ELIG[@]}"; do rail_ok $k $rr && echo "${RMTU[$k,$rr]:-?} ${T_HOST[$k]}"; done |
            awk '{if (!($1 in n)) d++; n[$1]++; h[$1] = h[$1] " " $2} END {if (d < 2) exit; for (m in n) if (n[m] > b) {b = n[m]; mm = m}
                 t = 0; for (m in n) if (n[m] == b) t++
                 if (t > 1) {printf "no majority:"; for (m in n) printf " %s on%s;", m, h[m]}
                 else {printf "most at %s;", mm; for (m in n) if (m != mm) printf " %s on%s;", m, h[m]}}')
        [[ -n $mt ]] && log "WARNING: rail $( [[ $rr == 0 ]] && echo A || echo B) MTUs differ: $mt paths across them fail the no-fragment check and are skipped"
        [[ -n $mt ]] && echo "rail_$( [[ $rr == 0 ]] && echo A || echo B) mtu_mismatch $mt" >> "$COLLECT_DIR/rail_anomalies.txt"
    done
    rail_consistency
    gateway_check
    [[ $FS_MESH == 1 ]] && mesh_check

    # --- 4. diagnostics ---
    log "Collecting NIC diagnostics..."
    local NIC_DIAG=$COLLECT_DIR/nic_diagnostics.txt LLDP_DATA=$COLLECT_DIR/lldp_neighbors.txt DRV_DATA=$COLLECT_DIR/driver_info.txt
    : > "$NIC_DIAG"; : > "$LLDP_DATA"; : > "$DRV_DATA"
    for k in "${ELIG[@]}"; do
        throttle
        rbash "${T_TARGET[$k]}" "${RNIC[$k,0]}" "${RNIC[$k,1]}" <<<"$DIAG_SCRIPT" > "$WORK/diag.$k" 2>&1 &
    done
    wait
    for k in "${ELIG[@]}"; do
        grep '^@@NIC_DIAG ' "$WORK/diag.$k" | cut -d' ' -f2- >> "$NIC_DIAG"
        grep '^@@LLDP ' "$WORK/diag.$k" | cut -d' ' -f2- >> "$LLDP_DATA"
        grep '^@@DRV ' "$WORK/diag.$k" | cut -d' ' -f2- >> "$DRV_DATA"
        grep -v '^@@' "$WORK/diag.$k" > "$RAW_DIR/${T_HOST[$k]}.txt"
    done
    log "Diagnostics: $(wc -l < "$NIC_DIAG" | tr -d ' ') NIC, $(wc -l < "$LLDP_DATA" | tr -d ' ') LLDP, $(wc -l < "$DRV_DATA" | tr -d ' ') driver lines"
    lldp_rail_check "$LLDP_DATA"

    local LINE_GBPS=$FS_LINE_GBPS
    if [[ -z $LINE_GBPS ]]; then
        LINE_GBPS=$(awk '$4 ~ /^[0-9]+Mb\/s$/ {sub(/Mb\/s/,"",$4); n[$4/1000]++} END {for (s in n) if (n[s] > b) {b = n[s]; m = s} print m}' "$NIC_DIAG")
    fi
    if [[ -n $LINE_GBPS ]]; then
        log "Link speed for cut-offs: ${LINE_GBPS}G ($(awk -v l="$LINE_GBPS" -v o="$FS_OK_PCT" -v s="$FS_SLOW_PCT" 'BEGIN {printf "OK >= %gG, SLOW >= %gG", l * o / 100, l * s / 100}'))"
        awk -v want="$(( LINE_GBPS * 1000 ))Mb/s" '$4 ~ /^[0-9]+Mb\/s$/ && $4 != want {printf "#   %s %s %s\n", $1, $2, $4}' "$NIC_DIAG" > "$WORK/offspeed"
        [[ -s $WORK/offspeed ]] && { log "NICs not at ${LINE_GBPS}G:"; cat "$WORK/offspeed" >&2; }
    else
        log "WARNING: no link speed from ethtool and FS_LINE_GBPS unset; no OK/SLOW status"
    fi

    # --- 5. iperf3 servers ---
    LOADED=1
    log "Stopping stray iperf3 and starting servers on port $FS_PORT..."
    for k in "${ELIG[@]}"; do
        local ips=()
        for r in 0 1; do rail_ok $k $r && ips+=("${RIP[$k,$r]}"); done
        STARTED[$k]=1
        rbash "${T_TARGET[$k]}" "$FS_PORT" "${ips[@]}" <<<"$SERVER_SCRIPT" >> "$RUNLOG_SSH" 2>&1 &
    done
    wait
    for k in "${ELIG[@]}"; do
        ( for i in $(seq 20); do
              l=$(rsh "${T_TARGET[$k]}" ss -Htln 2>&1)
              all=1
              for r in 0 1; do rail_ok $k $r && [[ $l != *"${RIP[$k,$r]}:$FS_PORT "* ]] && all=0; done
              (( all )) && exit 0
              sleep 0.5
          done
          echo "$k" ) > "$WORK/srv.$k" &
    done
    wait
    for k in "${ELIG[@]}"; do
        if [[ -s $WORK/srv.$k ]]; then
            for r in 0 1; do
                rail_ok $k $r || continue
                RSTATE[$k,$r]="iperf3 server not listening on ${RIP[$k,$r]}:$FS_PORT"; DOWN_IP[${RIP[$k,$r]}]=1
            done
            log "WARNING: ${T_HOST[$k]}: iperf3 server not listening; its paths are skipped"
        fi
    done

    # --- 6. iterations ---
    local RESULTS=$COLLECT_DIR/iperf3_results.txt DROP_TOTALS=$COLLECT_DIR/packet_drops.txt
    PATH_EXCL=$COLLECT_DIR/paths_excluded.txt
    : > "$RESULTS"; : > "$DROP_TOTALS"; : > "$PATH_EXCL"
    ORDER=($(for k in "${ELIG[@]}"; do echo "$k ${T_HOST[$k]}"; done | sort -V -k2 | awk '{print $1}'))
    local FIRST_HOST=${T_HOST[${ORDER[0]}]}
    local n=${#ORDER[@]} p ck sk
    ROT=("${ORDER[@]}"); (( n % 2 )) && ROT+=(-)
    local rounds=$(( ${#ROT[@]} - 1 )) per=$(( n / 2 )) total=$(( n * (n - 1) / 2 ))
    local used=$(( FS_ITER < rounds ? FS_ITER : rounds ))
    PAIRS_COVERED=$(( used * per )); PAIRS_TOTAL=$total
    PATHS_PLANNED=0; DROP_READS_MIN=-1
    log "Pairing: round-robin, $per pairs per iteration; $FS_ITER iterations cover $PAIRS_COVERED of $total host pairs$( (( FS_ITER < rounds )) && echo " (all pairs need FS_ITER=$rounds)")"
    (( FS_ITER > rounds )) && log "Iterations past $rounds repeat the pairings from the start"
    [[ -n $FS_TOS ]] && log "Marking: iperf3 -S $FS_TOS = DSCP $(( FS_TOS >> 2 )), ECN bits $(( FS_TOS & 3 )) (TCP: the kernel owns the ECN bits)"
    : > "$COLLECT_DIR/pairs.txt"; : > "$COLLECT_DIR/prio_counters.txt"; : > "$COLLECT_DIR/fec_rates.txt"
    # rail IP -> host/rail, and host_nic -> host, for the summary and UDP loss placement
    for k in "${ELIG[@]}"; do
        [[ ${RIP[$k,0]} != none ]] && echo "${RIP[$k,0]} ${T_HOST[$k]} A"
        [[ ${RIP[$k,1]} != none ]] && echo "${RIP[$k,1]} ${T_HOST[$k]} B"
    done > "$WORK/ipmap"
    for k in "${ELIG[@]}"; do for r in 0 1; do
        [[ ${RNIC[$k,$r]} != - ]] && echo "${T_HOST[$k]}_${RNIC[$k,$r]} ${T_HOST[$k]}"
    done; done > "$WORK/nicmap"
    UDP_RESULTS=$COLLECT_DIR/iperf3_udp_results.txt
    if [[ $FS_UDP == 1 ]]; then
        : > "$UDP_RESULTS"; : > "$COLLECT_DIR/udp_host_counters.txt"; : > "$COLLECT_DIR/udp_nic_drops.txt"
        log "UDP pass on: phases U1/U2 after the TCP phases, ${FS_UDP_DURATION}s each, no rate cap"
    fi
    for (( ITER = 1; ITER <= FS_ITER; ITER++ )); do
        round_pairs $(( (ITER - 1) % rounds ))
        PATHS_PLANNED=$(( PATHS_PLANNED + 4 * ${#PC[@]} ))
        log "============ Iteration $ITER of $FS_ITER (${#PC[@]} pairs) ============"
        [[ -n $SITOUT ]] && log "Sits out this iteration (odd host count): ${T_HOST[$SITOUT]}"
        for (( p = 0; p < ${#PC[@]}; p++ )); do echo "$ITER ${T_HOST[${PC[p]}]} ${T_HOST[${PS[p]}]}"; done >> "$COLLECT_DIR/pairs.txt"
        PATHS=$WORK/paths.$ITER; mkdir -p "$PATHS"
        for (( p = 0; p < ${#PC[@]}; p++ )); do
            ck=${PC[p]}; sk=${PS[p]}
            check_path p1a_$p $ck 0 $sk 0; check_path p1b_$p $sk 1 $ck 1
            check_path p2a_$p $ck 0 $sk 1; check_path p2b_$p $sk 0 $ck 1
        done
        wait
        local bad; bad=$(grep -Lx OK "$PATHS"/* | wc -l | tr -d ' ')
        log "Path checks (egress route, ping, MTU no-fragment): $(( ${#PC[@]} * 4 - bad )) OK, $bad excluded"

        local DROPS_PRE=$WORK/drops_pre DROPS_POST=$WORK/drops_post
        collect_drops "$DROPS_PRE"
        collect_counters "$PRIO_SCRIPT" "$WORK/prio_pre"
        collect_counters "$FEC_SCRIPT" "$WORK/fec_pre"; local fec_t0; fec_t0=$(date +%s)
        for PHASE in 1 2; do
            PHASE_OUT=$WORK/phase.$ITER.$PHASE; : > "$PHASE_OUT"
            [[ $PHASE == 1 ]] && log "Phase 1: A->A and B->B at once" || log "Phase 2: A->B both directions at once"
            echo "### iteration:${ITER} phase:${PHASE}" >> "$RESULTS"
            for (( p = 0; p < ${#PC[@]}; p++ )); do
                ck=${PC[p]}; sk=${PS[p]}
                if [[ $PHASE == 1 ]]; then run_path p1a_$p $ck 0 $sk 0; run_path p1b_$p $sk 1 $ck 1
                else run_path p2a_$p $ck 0 $sk 1; run_path p2b_$p $sk 0 $ck 1; fi
            done
            wait
            column -t < "$PHASE_OUT" | tee -a "$RESULTS"
            local errs; errs=$(grep -c ',ERROR' "$PHASE_OUT")
            [[ $errs -gt 0 ]] && log "WARNING: $errs runs in phase $PHASE returned no result (lines with ERROR above)"
        done
        [[ $FS_UDP == 1 ]] && udp_phases
        collect_drops "$DROPS_POST"
        local nr; nr=$(wc -l < "$DROPS_POST" | tr -d ' ')   # "0 drops" only means something if NICs were read
        (( DROP_READS_MIN < 0 || nr < DROP_READS_MIN )) && DROP_READS_MIN=$nr
        collect_counters "$PRIO_SCRIPT" "$WORK/prio_post"
        collect_counters "$FEC_SCRIPT" "$WORK/fec_post"
        fec_deltas "iter$ITER" $(( $(date +%s) - fec_t0 > 0 ? $(date +%s) - fec_t0 : 1 ))
        # per-priority / pause / ECN counter increases: "iterN host_nic counter delta"
        awk -v it="iter$ITER" 'NR==FNR {pre[$1" "$2]=$3; next}
            ($1" "$2) in pre && $3 > pre[$1" "$2] {print it, $1, $2, $3 - pre[$1" "$2]}' \
            "$WORK/prio_pre" "$WORK/prio_post" > "$WORK/prio_delta"
        if [[ -s $WORK/prio_delta ]]; then
            cat "$WORK/prio_delta" >> "$COLLECT_DIR/prio_counters.txt"
            # which priority carried the bytes (shows where the DSCP mapped)
            log "Traffic by priority in iteration $ITER (rx+tx bytes, all rail NICs): $(awk '
                { l = tolower($3) } l ~ /byte/ && match(l, /pri(ority|o)?_?[0-9]/) {
                    p = substr(l, RSTART, RLENGTH); gsub(/[^0-9]/, "", p); b[p] += $4; n++ }
                END { for (p in b) printf "prio%s %.1fGB  ", p, b[p] / 1e9; if (!n) printf "no per-priority byte counters" }' "$WORK/prio_delta")"
            awk 'tolower($3) !~ /byte|packet/' "$WORK/prio_delta" | sort -k4 -rn > "$WORK/prio_events"
            if [[ -s $WORK/prio_events ]]; then
                log "Pause/ECN/discard counters that rose (top 10 of $(wc -l < "$WORK/prio_events" | tr -d ' ')):"
                head -n 10 "$WORK/prio_events" | column -t | sed 's/^/#   /' >&2
            else
                log "No pause/ECN/discard counter rose in iteration $ITER"
            fi
        else
            log "No priority/pause/ECN counter rose in iteration $ITER ($(wc -l < "$WORK/prio_post" | tr -d ' ') counters read)"
        fi
        local iter_drops; iter_drops=$(compute_drops "$DROPS_PRE" "$DROPS_POST" "iter${ITER}")
        if [[ -n $iter_drops ]]; then
            log "Drops during iteration $ITER:"; echo "$iter_drops" | column -t | sed 's/^/#   /' >&2
            echo "$iter_drops" >> "$DROP_TOTALS"
        else
            log "No drop counter increases in iteration $ITER ($(wc -l < "$DROPS_POST" | tr -d ' ') NICs read)"
        fi
        echo
    done

    # --- 7. summary ---
    local LABEL=${FS_LABEL:-$FIRST_HOST}
    LABEL=${LABEL//[^A-Za-z0-9_.-]/_}
    {
        echo ""
        echo "=================================================================="
        echo " $LABEL DATA PLANE VALIDATION SUMMARY: $(date)"
        echo "=================================================================="
        local map=$WORK/ipmap
        if grep -q 'Gbits/sec' "$RESULTS"; then
            echo "Per-host throughput, worst first (Gbps; each rail averaged over all its runs):"
            grep 'Gbits/sec' "$RESULTS" | awk -F'[, ]+' -v ok="$(( ${LINE_GBPS:-0} * FS_OK_PCT ))" -v slow="$(( ${LINE_GBPS:-0} * FS_SLOW_PCT ))" '
                NR==FNR { host[$1]=$2; rail[$1]=$3; next }
                { for (i = 1; i <= NF; i++) if ($i == "Gbits/sec") { s = $(i-1) + 0; break }
                  for (j = 1; j <= 2; j++) { ip = $j; sum[host[ip], rail[ip]] += s; cnt[host[ip], rail[ip]]++; seen[host[ip]] = 1 } }
                END {
                    print "Host Avg_Gbps Rail_A Rail_B Status"
                    for (h in seen) {
                        a = cnt[h,"A"] ? sum[h,"A"]/cnt[h,"A"] : -1; b = cnt[h,"B"] ? sum[h,"B"]/cnt[h,"B"] : -1
                        t = 0; m = 0; if (a >= 0) {t += a; m++} if (b >= 0) {t += b; m++}
                        avg = t / m
                        st = ok == 0 ? "-" : (avg * 100 >= ok ? "OK" : (avg * 100 >= slow ? "SLOW" : "CRITICAL"))
                        if (m < 2) st = st "(1rail)"
                        printf "%s %.1f %s %s %s\n", h, avg, (a < 0 ? "-" : sprintf("%.1f", a)), (b < 0 ? "-" : sprintf("%.1f", b)), st
                    }
                }' "$map" - | { read -r hdr; echo "$hdr"; sort -k2 -n; } | column -t | sed 's/^/  /'
        else
            echo "  No iperf3 results collected."
        fi
        echo ""
        echo "  Hosts tested: ${#ELIG[@]} | Rails unusable: $(awk 'NR > 1 {n += ($6 != "ok") + ($10 != "ok")} END {print n + 0}' "$COLLECT_DIR/rails.txt") (rails.txt) | Paths skipped: $(wc -l < "$PATH_EXCL" | tr -d ' ') (paths_excluded.txt)"
        echo "  Runs with no result: $(grep -c ',ERROR' "$RESULTS")"
        if [[ $FS_UDP == 1 ]]; then
            echo ""
            if grep -q 'Gbits/sec' "$UDP_RESULTS"; then
                echo "UDP (-b 0) by receiving host: avg Gbps per run, datagrams lost/sent, loss %:"
                grep 'Gbits/sec' "$UDP_RESULTS" | awk -F'[, ]+' '
                    NR==FNR { host[$1]=$2; next }
                    { for (i = 1; i <= NF; i++) { if ($i == "Gbits/sec") g = $(i-1); if ($i ~ /^[0-9]+\/[0-9]+$/) split($i, x, "/") }
                      h = host[$2]; gs[h] += g; c[h]++; l[h] += x[1]; s[h] += x[2] }
                    END { print "Host Avg_Gbps Lost/Sent Loss_%"
                          for (h in c) printf "%s %.1f %d/%d %.3f\n", h, gs[h] / c[h], l[h], s[h], s[h] ? 100 * l[h] / s[h] : 0 }' \
                    "$map" - | { read -r hdr; echo "$hdr"; sort -k4 -rn; } | column -t | sed 's/^/  /'
                local r; read -r -a r <<<"$(udp_attr "")"
                echo "  Lost datagrams ${r[0]} of ${r[1]}: receiver socket ${r[2]}, NIC ${r[3]}, kernel backlog ${r[4]}, unaccounted (likely fabric) ${r[5]}"
            else
                echo "  No UDP results collected."
            fi
            echo "  UDP runs with no result: $(grep -c ',ERROR' "$UDP_RESULTS")"
        fi
        echo "=================================================================="
    } >&2

    # --- 8. coverage verdict: never a clean result on partial or empty data ---
    local expect hosts_tested paths_ok skipped noresult coverage cov_rc
    if [[ -n $FS_EXPECT_HOSTS ]]; then expect=$FS_EXPECT_HOSTS
    elif (( INPUT_RANGES )); then expect=${#ELIG[@]}
    else expect=$(( ${#TARGETS[@]} - dups )); fi
    hosts_tested=$(grep 'Gbits/sec' "$RESULTS" | awk -F'[, ]+' 'NR==FNR {h[$1]=$2; next} {print h[$1]; print h[$2]}' "$WORK/ipmap" - | sort -u | grep -c .)
    paths_ok=$(grep -c 'Gbits/sec' "$RESULTS")
    skipped=$(awk '$2 ~ /^[12]$/' "$PATH_EXCL" | wc -l | tr -d ' ')
    noresult=$(grep -c ',ERROR' "$RESULTS")
    if (( paths_ok == 0 )); then coverage=NONE; cov_rc=4
    elif (( hosts_tested >= expect && paths_ok >= PATHS_PLANNED )); then coverage=COMPLETE; cov_rc=0
    else coverage=PARTIAL; cov_rc=3; fi
    local RESULT_LINE="RESULT coverage=$coverage hosts=$hosts_tested/$expect paths=$paths_ok/$PATHS_PLANNED skipped=$skipped no_result=$noresult"
    (( INPUT_RANGES )) && [[ -z $FS_EXPECT_HOSTS ]] && RESULT_LINE+=" (hosts expected = hosts found on the rails; set FS_EXPECT_HOSTS to check for missing ones)"

    local ts; ts=$(date -u +%Y%m%dT%H%M%SZ)
    {
        echo "label=$LABEL"
        echo "timestamp=$START_TS"
        echo "end_timestamp=$ts"
        echo "duration=$FS_DURATION"
        echo "iterations=$FS_ITER"
        echo "parallel_streams=$FS_STREAMS"
        echo "total_hosts=${#ELIG[@]}"
        echo "targets_input=${#TARGETS[@]}"
        echo "targets_reachable=${#REACH[@]}"
        echo "rail_mode=$RAIL_MODE"
        echo "rail_a=${RAIL_SPEC[0]// /,}"
        echo "rail_b=${RAIL_SPEC[1]// /,}"
        echo "line_rate_gbps=${LINE_GBPS:-unknown}"
        echo "ok_pct=$FS_OK_PCT"
        echo "slow_pct=$FS_SLOW_PCT"
        echo "busy_hosts=${#BUSY[@]}"
        echo "port=$FS_PORT"
        echo "tos=${FS_TOS:-none}"
        echo "pairing=round-robin"
        echo "pairs_covered=$PAIRS_COVERED"
        echo "pairs_total=$PAIRS_TOTAL"
        echo "udp=$FS_UDP"
        echo "udp_duration=$FS_UDP_DURATION"
        echo "coverage=$coverage"
        echo "hosts_expected=$expect"
        echo "hosts_tested=$hosts_tested"
        echo "paths_planned=$PATHS_PLANNED"
        echo "paths_ok=$paths_ok"
        echo "drop_nics_read_min=$DROP_READS_MIN"
        echo "drop_nics_expected=$(( ${#ELIG[@]} * 2 ))"
        echo "nic_diag_lines=$(wc -l < "$NIC_DIAG" | tr -d ' ')"
        echo "mesh_pings=${MESH_PINGS:-}"
        echo "mesh_failures=${MESH_FAILS:-}"
        echo "tool=fabric_sleuth_v2"
    } > "$COLLECT_DIR/metadata.txt"
    for k in "${ELIG[@]}"; do
        echo "${T_HOST[$k]} ${T_TARGET[$k]} ${RIP[$k,0]} ${RIP[$k,1]} ${RNIC[$k,0]} ${RNIC[$k,1]}"
    done | sort -V > "$COLLECT_DIR/host_list.txt"
    printf '%s\n' "${!DOWN_IP[@]}" | grep . | sort -V > "$COLLECT_DIR/down_ips.txt"

    local tarball=$FS_OUT_DIR/fabric_sleuth_${LABEL}_${ts}.tar.gz
    stop_servers
    DONE=1
    [[ -n $FS_RUNLOG && -f $FS_RUNLOG ]] && cp "$FS_RUNLOG" "$COLLECT_DIR/run.log"
    COPYFILE_DISABLE=1 tar czf "$tarball" -C "$(dirname "$COLLECT_DIR")" "$(basename "$COLLECT_DIR")" || die "tar failed; data left in $COLLECT_DIR"
    log "Data archive: $tarball ($(du -h "$tarball" | cut -f1))"
    local abs; abs=$(cd "$(dirname "$tarball")" && pwd)/$(basename "$tarball")
    if [[ -n $SSH_CONNECTION ]]; then   # ran on a jump host: say how to fetch it
        local srv; srv=$(awk '{print $3}' <<<"$SSH_CONNECTION")
        # SSH_CONNECTION shows the address this host sees; behind NAT that is private, so name the host too
        log "Fetch and render: scp $(id -un)@$srv:$abs . && python3 generate_dashboard_v2.py $(basename "$tarball")"
        log "  ($srv is this jump host's own address; from outside use the address you ssh to, e.g. $(hostname -f 2>&1 | head -n1))"
    else
        log "Render: python3 generate_dashboard_v2.py $abs"
    fi
    rm -rf "${COLLECT_DIR:?}"
    echo "$RESULT_LINE" >&2
    exit $cov_rc   # exit, not return: bash 5.1 drops a piped function's return status under an EXIT trap
}

START_TS=$(date -u +%Y%m%dT%H%M%SZ)
# Run when executed or fed on stdin (ssh jump 'bash -s' < script: BASH_SOURCE is empty); not when sourced.
# stderr is copied to the run log by tee in a pipeline, not a process substitution: bash 5.1's
# bare `wait` also waits for a process substitution, which never exits while main runs.
# tee ignores SIGINT so an interrupted run's cleanup can still write.
if [[ ${#BASH_SOURCE[@]} -eq 0 || ${BASH_SOURCE[0]} == "$0" ]]; then
    FS_RUNLOG=$(mktemp "${TMPDIR:-/tmp}/fs_runlog.XXXXXX") || exit 2
    { main "$@" 2>&1 1>&3 3>&- | ( trap '' INT; exec tee -a "$FS_RUNLOG" >&2 3>&- ); rc=${PIPESTATUS[0]}; } 3>&1
    rm -f "$FS_RUNLOG"
    exit "$rc"
fi
