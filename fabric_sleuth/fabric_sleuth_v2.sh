#!/bin/bash
# fabric_sleuth: dual-rail backend-to-backend iperf3 fabric check.
# Hosts and rails come from env vars (see usage); output is a .tgz bundle
# that generate_dashboard.py turns into an HTML dashboard.

usage() {
    cat <<'EOF'
Usage: FS_HOSTS=<targets> FS_RAIL_A=<cidr,...> FS_RAIL_B=<cidr,...> ./fabric_sleuth_v2.sh [duration_s]
       FS_HOSTS=<targets> ./fabric_sleuth_v2.sh --list   (print expanded targets, no ssh)
From a jump host (settings ride in the remote command; nothing to edit or copy first):
       ssh jump 'FS_HOSTS=10.1.0.0/24 FS_RAIL_A=... FS_RAIL_B=... bash -s -- 120' < fabric_sleuth_v2.sh
       The run ends by printing the scp + render line for the tarball it left on the jump host.
The bundle also carries each host's system info (sysinfo/<host>/<item>: OS, CPU, PCIe, NIC rings/IRQs/QoS, routes,
sysctls, kernel log over the run) and host_rx.txt, the per-host receive side (rings, PCIe, drops, iperf3 CPU, flags).

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
                   is tested after n-1 iterations (n if n is odd); the next n-1 swap client
                   and server, so every direction on every NIC pair runs after 2(n-1).
                   all = 2(n-1) (5)
  FS_STREAMS       iperf3 parallel streams, >=2 (16)
  FS_TOS           IP TOS byte for the test traffic, 0-255 (iperf3 -S), e.g. 106 = DSCP 26
                   + ECT(0); TCP keeps the DSCP, the kernel sets the ECN bits (unset: 0)
  FS_SKIP_IPERF=1  no iperf3 at all, for a cluster whose I/O can't stop (WEKA running): every other check
                   runs (discovery, rails, path checks for every planned path, mesh, LLDP, NIC/FEC/priority
                   and drop counters, system info, host-side receive), the counters over one FS_DURATION
                   window of the cluster's own traffic. The busy check reports but doesn't stop the run.
  FS_UDP=1         after the TCP phases, run the same pairs with UDP and no rate cap
                   (iperf3 -u -b 0, datagrams sized to the path MTU). Loss is split into
                   receiver socket, NIC, kernel backlog and unaccounted (likely fabric).
                   With FS_TOS the whole TOS byte, ECN bits included, is sent.
  FS_UDP_DURATION  seconds per UDP run (FS_DURATION)
  FS_IGNORE_LOCK=1 run even if another fabric_sleuth run holds a host (two runs on the same hosts
                   kill each other's iperf3 servers and both get garbage)
  FS_MESH=1        before load, ping every tested host's rail IPs from every other one's (same rail and
                   cross-rail; tested hosts only, so other clusters on shared subnets are never
                   probed). Failures go to mesh_failures.txt and the Preflight card.
  FS_CROSS_RAIL=0  the rails are separate fabrics by design: skip the cross-rail phase (A<->B) and
                   leave it out of the coverage count. Default: test it; unrouted A<->B paths count
                   as skipped (PARTIAL), since missing inter-rail routes can be the fault. When every
                   A<->B check fails on routing and no same-rail one does, the log says so.
  FS_CROSS_MAX=N   at most N cross-rail flows at once: phase 2 (and U2) run in balanced waves,
                   each flow for the full duration; keeps a shared inter-rail path from capping
                   every flow (unset: all at once)
  FS_SYSINFO_TIMEOUT  seconds per host for the system info capture before load (300); a host that runs
                   out keeps what it sent and is flagged sysinfo_partial
  FS_PORT          iperf3 port (5201)
  FS_SSH_USER      ssh user; non-root runs remote steps with sudo -n (root)
  FS_SSH_PARALLEL  ssh sessions at once for sweep and collection (64)
  FS_SSH_RETRY_PARALLEL  retry targets that refused ssh under load (reset, kex) this many at a time (8)
  FS_MAX_TARGETS   refuse to expand FS_HOSTS beyond this (4096)
  FS_LABEL         name in the report and tarball (first tested hostname)
  FS_OUT_DIR       where the .tgz bundle goes (.)
  FS_LINE_GBPS     link speed for OK/SLOW cut-offs: N for both rails, or A,B when the rails
                   differ by design (e.g. 100,50). Default: the faster rail's most common NIC
                   speed for both, so a rail that came up slow everywhere shows as slow
  FS_OK_PCT        OK at or above this % of link speed (75)
  FS_SLOW_PCT      SLOW at or above this %, CRITICAL below (50)
                   Each iteration: phase 1 same rail (A->A, B->B); phase 2 cross-rail, one flow each
                   way per pair (A->B and B->A at once). Host Status = the worst of Rail_A, Rail_B
                   and Cross; SLOW(cross)/CRITICAL(cross) = only the cross-rail runs were that slow.
  FS_SPINES        leaf-spine uplinks, all three or none (no defaults): spines, links from each
  FS_SPINE_LINKS   leaf to each spine, Gbps per link. The summary always sums each leaf's runs to
  FS_SPINE_GBPS    other leaves per phase (leaf = LLDP neighbour); with these set it judges them
                   against spines x links x Gbps per direction: oversubscribed by design, or a
                   lost link/spine. Status is unchanged.
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
    # passive DACs have no monitoring and report 0.00 C at 0 V: that is n/a, not a reading
    temp=$(echo "$mod" | awk '/Module temperature/ && t == "" {for (i = 1; i <= NF; i++) if ($i == "degrees") {t = $(i-1); break}}
        /Module voltage *:/ && $NF == "V" && $(NF-1) + 0 == 0 {z = 1} END {if (t != "" && !z) print t}')
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
    # carrier drops: vendor-neutral, and counts flaps that mlx5 link_down_events_phy misses on some firmware
    cd=$(cat /sys/class/net/$nic/carrier_down_count 2>&1); case $cd in ''|*[!0-9]*) cd=na ;; esac
    echo "${h}_${nic} ${ip:-none} ${rx:-na} ${tx:-na} ${oob:-na} $cd"
done
EOF

# Per-priority, PFC/pause, ECN/CNP and NIC discard counters for the rail NICs ($@): "host_nic counter value".
# Names differ by driver (mlx5 rx_prio3_pause, ice rx_priority_3_xon.nic, bnxt pfc_*); per-queue/ring lines
# (chN_, rxN_, txN_, _qN, queue) skipped. RoCE ECN/CNP/retransmit counters live only in the RDMA port's sysfs, printed as "rdma:<name>".
# FS_SYSFS (default /sys) is a test hook.
read -r -d '' PRIO_SCRIPT <<'EOF'
h=$(hostname -s); sys=${FS_SYSFS:-/sys}
for nic in "$@"; do
    [ "$nic" = - ] && continue
    ethtool -S "$nic" 2>&1 | awk -v k="${h}_${nic}" '$2 ~ /^[0-9]+$/ && $1 ~ /:$/ {
        n = $1; sub(/:$/, "", n); l = tolower(n)
        if (l ~ /prio|pri[0-9]|pfc|pause|xon|xoff|ecn|cnp|discard|out_of_buffer/ && l !~ /ch[0-9]|_q[0-9]|queue|^[rt]x[0-9]+_/) print k, n, $2 }'
    # the RDMA port whose default GID is on this NIC, or on its only lower device (a VLAN's parent)
    phys=$nic; n=0
    for l in "$sys/class/net/$nic"/lower_*; do [ -e "$l" ] && { phys=${l##*lower_}; n=$((n + 1)); }; done
    [ "$n" -le 1 ] || phys=$nic
    for p in "$sys"/class/infiniband/*/ports/*; do
        [ "$(cat "$p/gid_attrs/ndevs/0" 2>&1)" = "$phys" ] || continue
        for f in "$p"/hw_counters/* "$p"/counters/*; do
            c=${f##*/}
            case $c in *ecn*|*cnp*|*seq*|*nak*|*timeout*|*retrans*|*restart*|*discard*|*err*|*downed*|*out_of_buffer*|\
                       *duplicate*|*exceeded*|*invalid*|*dropped*|*xmit_wait*) ;; *) continue ;; esac
            v=$(cat "$f" 2>&1)
            case $v in ''|*[!0-9]*) ;; *) echo "${h}_${nic} rdma:$c $v" ;; esac
        done
    done
done
EOF

# FEC counters for the rail NICs ($@): "host_nic corrected_blocks uncorrectable_blocks corrected_bits symbol_errors".
# Blocks come from the vendor-neutral ethtool -I --show-fec; corrected bits and symbol errors are mlx5 extras. na = not exposed,
# off = the link runs without FEC (Active FEC encoding Off/None), so there is no pre-FEC BER.
read -r -d '' FEC_SCRIPT <<'EOF'
h=$(hostname -s)
num() { awk -v k="$1" '$1 == k {for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}'; }
for nic in "$@"; do
    [ "$nic" = - ] && continue
    f=$(ethtool -I --show-fec "$nic" 2>&1); s=$(ethtool -S "$nic" 2>&1)
    cb=$(echo "$f" | num corrected_blocks:); ub=$(echo "$f" | num uncorrectable_blocks:)
    bits=$(echo "$s" | num rx_corrected_bits_phy:); sym=$(echo "$s" | num rx_pcs_symbol_err_phy:)
    echo "$f" | grep -q -i -E '^Active FEC encoding: *(off|none)' && { cb=off; ub=off; bits=off; }
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

# Run lock per host: take <id> <info> <max_age_s> | touch <id> | release <id>.
# take prints OK, or BUSY <holder> when another run touched the lock within max_age.
read -r -d '' LOCK_SCRIPT <<'EOF'
L=${FS_LOCK_FILE:-/tmp/fabric_sleuth.lock}
mine() { [ -f "$L" ] && grep -q "^$1 " "$L"; }
case $1 in
take)
    # atomic create: set -C (noclobber) refuses an existing file, so two runs cannot both win
    if out=$( (set -C; echo "$2 $3" > "$L") 2>&1 ); then echo OK; exit 0; fi
    mine "$2" && { echo OK; exit 0; }
    age=$(( $(date +%s) - $(date -r "$L" +%s) ))
    if [ "$age" -lt "$4" ]; then echo "BUSY $(cut -d" " -f2- "$L") (lock refreshed ${age}s ago)"; exit 0; fi
    # stale lock: replace it whole, then re-read; of two runs doing this, only the last writer keeps it
    echo "$2 $3" > "$L.$$" && mv -f "$L.$$" "$L"; sleep 1
    if mine "$2"; then echo OK; else echo "BUSY $(cut -d" " -f2- "$L") (took over a stale lock first)"; fi ;;
touch) mine "$2" && touch "$L"; echo OK ;;
release) mine "$2" && rm -f "$L"; echo OK ;;
esac
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

# One iperf3 run: src dst port streams secs [tos] -> "[SUM] ... receiver retransmits:N cpu:S/R" or "ERROR ..."
# cpu: -V's process CPU % on the sender (client) and receiver (server); over 100 with iperf3 3.16+ threads, na if absent.
read -r -d '' IPERF_SCRIPT <<'EOF'
out=$(iperf3 --connect-timeout 5000 -c "$2" -B "$1" -p "$3" -P "$4" -t "$5" -f g -Z -V ${6:+-S $6} 2>&1); rc=$?
retr=$(echo "$out" | awk '/SUM.*sender/{print $(NF-1)}')
rcv=$(echo "$out" | grep -m1 'SUM.*receiver')
cpu=$(echo "$out" | awk '/CPU Utilization/ {for (i = 1; i < NF; i++) {if ($i == "local/sender") s = $(i+1); if ($i == "remote/receiver") r = $(i+1)}}
    END {gsub(/[%,]/, "", s); gsub(/[%,]/, "", r); print (s == "" ? "na" : s) "/" (r == "" ? "na" : r)}')
if [ -n "$rcv" ]; then echo "$rcv retransmits:${retr:-0} cpu:$cpu"
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

# System info, once per tested host: wekatester's set plus the receive path, as "=== SYSINFO <item> ===" sections
# (split locally into sysinfo/<host>/<item>). Rail NICs are $@. A missing tool or file says "n/a: <why>", never a blank.
read -r -d '' SYSINFO_SCRIPT <<'EOF'
have() { [ -n "$(command -v "$1")" ]; }
s() { echo "=== SYSINFO $1 ==="; }
to=""; have timeout && to=timeout   # an item that hangs (a stale mount under df, say) costs its section, not the host
cmd() {   # T=seconds (20)
    if ! have "$1"; then echo "n/a: $1 not installed"; return; fi
    $to ${to:+${T:-20}} "$@" 2>&1; [ $? = 124 ] && echo "n/a: $1 timed out after ${T:-20}s"
}
f() { if [ -r "$1" ]; then cat "$1" 2>&1; else echo "n/a: $1 not readable"; fi; }
s epoch; date +%s
for p in cmdline mounts meminfo softirqs; do s $p; f /proc/$p; done
s isolated; f /sys/devices/system/cpu/isolated
s os-release; f /etc/os-release
s uname; uname -a
s uptime; cmd uptime
s df; cmd df -kP
s ip; ip -o addr 2>&1; ip -o link 2>&1
s ip-rule; ip rule 2>&1
s ip-route-all; ip route show table all 2>&1 | head -n 2000
s lscpu; cmd lscpu
s lspci; cmd lspci
s numactl; cmd numactl --hardware
s free; cmd free
s iperf3; cmd iperf3 --version
s weka; cmd weka local ps
s chrony; if have chronyc; then cmd chronyc tracking; else cmd timedatectl status; fi
s ofed; cmd ofed_info -s
s dmidecode; cmd dmidecode -t bios -t system -t baseboard
s sysctl
for k in net/core/netdev_max_backlog net/core/netdev_budget net/core/rmem_max net/core/wmem_max net/ipv4/tcp_rmem \
         net/ipv4/tcp_wmem net/ipv4/tcp_congestion_control net/ipv4/tcp_ecn; do echo "$k $(cat /proc/sys/$k 2>&1)"; done
for n in all default "$@"; do
    [ "$n" = - ] && continue
    for k in rp_filter arp_ignore arp_announce; do echo "net/ipv4/conf/$n/$k $(cat /proc/sys/net/ipv4/conf/$n/$k 2>&1)"; done
done
s cpu-governor
g=/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
if [ -r $g ]; then cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>&1 | sort | uniq -c
else echo "n/a: no cpufreq governor (the BIOS or a VM controls frequency)"; fi
s irqbalance; if [ -n "$(pgrep -x irqbalance)" ]; then echo running; else echo "not running"; fi
for nic in "$@"; do
    [ "$nic" = - ] && continue
    dev=/sys/class/net/$nic/device; bus=$(basename "$(readlink -f $dev)")
    s "nic-$nic"
    echo "bus $bus"; echo "driver $(basename "$(readlink -f $dev/driver)")"; echo "numa_node $(cat $dev/numa_node 2>&1)"
    for a in current_link_speed current_link_width max_link_speed max_link_width; do echo "$a $(cat $dev/$a 2>&1 | tr ' ' _)"; done
    for a in correctable nonfatal fatal; do
        echo "aer_$a $(awk '$1 ~ /^TOTAL_ERR/ {print $2; f = 1} END {if (!f) print "n/a"}' $dev/aer_dev_$a 2>&1)"
    done
    irqs=$(ls $dev/msi_irqs 2>&1); echo "msi_irqs $(echo "$irqs" | grep -c '^[0-9]')"
    echo "irq_cpus $(for i in $irqs; do cat /proc/irq/$i/smp_affinity_list 2>&1; done | tr '\n' ' ')"
    for o in -g -l -c -a; do echo "--- ethtool $o"; cmd ethtool $o "$nic"; done
    echo "--- modinfo"; d=$(basename "$(readlink -f $dev/driver/module)"); cmd modinfo "$d" | head -n 12
    echo "--- mlnx_qos"; cmd mlnx_qos -i "$nic"
    echo "--- mlxconfig"; if have mlxconfig; then T=60 cmd mlxconfig -d "$bus" q | head -n 400; else echo "n/a: mlxconfig not installed (MFT)"; fi
done
EOF

# Receive-side host counters, read at each TCP phase boundary: "host key value". TCP from /proc/net/snmp and
# netstat, softnet_stat summed over CPUs (hex), NET_RX softirqs, PCIe AER totals per rail NIC ($@).
read -r -d '' HOSTCTR_SCRIPT <<'EOF'
h=$(hostname -s)
awk -v h="$h" -v want='^(RetransSegs|InErrs|TCPRcvQDrop|TCPBacklogDrop|TCPOFODrop|TCPOFOQueue|PruneCalled|RcvPruned|OfoPruned|TCPRcvCollapsed|TCPZeroWindowDrop|TCPLostRetransmit|TCPTimeouts|TCPMemoryPressures)$' '
    $1 == "Tcp:" || $1 == "TcpExt:" { if (seen[$1]++ % 2 == 0) { for (i = 2; i <= NF; i++) n[i] = $i }
                                      else for (i = 2; i <= NF; i++) if (n[i] ~ want) print h, n[i], $i }' /proc/net/snmp /proc/net/netstat
p=0; d=0; q=0; while read -r a b c rest; do p=$(( p + 16#$a )); d=$(( d + 16#$b )); q=$(( q + 16#$c )); done < /proc/net/softnet_stat
echo "$h softnet_processed $p"; echo "$h softnet_dropped $d"; echo "$h softnet_squeezed $q"
awk -v h="$h" '$1 == "NET_RX:" {for (i = 2; i <= NF; i++) s += $i; print h, "softirq_net_rx", s}' /proc/softirqs
for nic in "$@"; do
    [ "$nic" = - ] && continue
    for a in correctable nonfatal fatal; do
        v=$(awk '$1 ~ /^TOTAL_ERR/ {print $2}' /sys/class/net/$nic/device/aer_dev_$a 2>&1)
        case $v in ''|*[!0-9]*) ;; *) echo "$h aer_$a:$nic $v" ;; esac
    done
done
EOF

# Kernel log since the run began, by the host's own clock ($1 = its epoch from the sysinfo capture)
read -r -d '' KLOG_SCRIPT <<'EOF'
if [ -n "$(command -v journalctl)" ] && out=$(timeout 60 journalctl -k --no-pager -o short-iso --since "@$1" 2>&1); then echo "$out" | tail -n 3000
else echo "n/a: journalctl -k failed or missing (${out%%$'\n'*}); dmesg instead, last 500 lines of the boot"; dmesg -T 2>&1 | tail -n 500; fi
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

# Run lock: take on every tested host before load; another live run (its lock refreshed within
# about two iterations) stops this one, since each run kills stray iperf3 servers on its hosts.
take_locks() {
    local k busy other
    RUN_ID="$(hostname -s)-$$-$START_TS"
    cross_waves $(( ${#ELIG[@]} / 2 ))   # phase 2 waves stretch an iteration
    local max=$(( 2 * ((1 + XW) * FS_DURATION + (FS_UDP == 1 ? (1 + XW) * FS_UDP_DURATION : 0)) + 300 ))
    local info="since=$(date -u +%Y-%m-%dT%H:%M:%SZ),from=$(hostname -s),user=$(id -un)"   # no spaces: args are re-split remotely
    for k in "${ELIG[@]}"; do
        throttle
        ( out=$(rbash "${T_TARGET[$k]}" take "$RUN_ID" "$info" "$max" <<<"$LOCK_SCRIPT" 2>&1)
          echo "${T_HOST[$k]} ${out%%$'\n'*}" > "$WORK/lock.$k" ) &
    done
    wait
    LOCKED=1   # release whatever we took, even if we stop below
    save_state
    busy=$(cat "$WORK"/lock.* | grep ' BUSY ')
    other=$(cat "$WORK"/lock.* | grep -v -E ' (OK|BUSY .*)$')
    [[ -n $other ]] && { log "WARNING: could not take the run lock on:"; echo "$other" | sed 's/^/#   /' >&2; }
    [[ -n $busy ]] || return 0
    if [[ $FS_IGNORE_LOCK == 1 ]]; then
        log "WARNING: FS_IGNORE_LOCK=1: running although another run holds:"; echo "$busy" | sed 's/^/#   /' >&2
    else
        die "another fabric_sleuth run is active on $(echo "$busy" | wc -l | tr -d ' ') hosts (it would lose its iperf3 servers to this one): $(echo "$busy" | head -n 3 | tr '\n' ';') wait for it, or set FS_IGNORE_LOCK=1 if it is dead"
    fi
}

lock_all() {  # touch | release on every tested host (only our own lock is changed)
    local k
    for k in "${ELIG[@]}"; do rbash "${T_TARGET[$k]}" "$1" "$RUN_ID" <<<"$LOCK_SCRIPT" >> "$WORK/lock.log" 2>&1 & done
    wait
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
# until every pair has met (${#ROT[@]} - 1 rounds). Sets PC/PS (client/server), PI (pair slot) and SITOUT.
round_pairs() {
    local r=$1 m=${#ROT[@]} i a b
    local -a arr=("${ROT[0]}")
    for (( i = 0; i < m - 1; i++ )); do arr+=("${ROT[1 + (i + r) % (m - 1)]}"); done
    PC=(); PS=(); PI=(); SITOUT=""
    for (( i = 0; i < m / 2; i++ )); do
        a=${arr[i]}; b=${arr[m - 1 - i]}
        if [[ $a == - ]]; then SITOUT=$b
        elif [[ $b == - ]]; then SITOUT=$a
        else PC+=("$a"); PS+=("$b"); PI+=("$i"); fi
    done
}

# xpaths p: pair p's two phase 2 runs, one each way across the rails, in X1/X2 (src_k src_r dst_k dst_r).
# Odd: client A <-> server B; even: client B <-> server A. A rotating host moves one slot per round, so slot
# parity swaps its NIC each iteration; slot 0 (the fixed host) swaps by iteration.
xpaths() {
    local c=${PC[$1]} s=${PS[$1]} i=${PI[$1]}
    if (( i ? i % 2 : (RND + 1) % 2 )); then X1=($c 0 $s 1); X2=($s 1 $c 0); else X1=($c 1 $s 0); X2=($s 0 $c 1); fi
}

# cross_waves npairs: XW = phase 2 waves under FS_CROSS_MAX (1 when unset). A pair's two flows (one each
# way) stay in one wave, so every wave is balanced A->B / B->A; a cap of 1 runs the flows one at a time.
cross_waves() {
    local np=$1 cap=${FS_CROSS_MAX:-0}
    if (( cap == 0 || 2 * np <= cap )); then XW=1
    elif (( cap == 1 )); then XW=$(( 2 * np ))
    else XW=$(( (np + cap / 2 - 1) / (cap / 2) )); fi
}

# xwaves results [udp]: the current pairs' cross-rail runs in XW waves (pair p in wave p % XW). TCP results
# get a "wave:w/W" marker per wave, so totals only add up flows that ran at the same time.
xwaves() {
    local res=$1 mode=$2 w p all=$PHASE_OUT
    cross_waves ${#PC[@]}
    (( XW > 1 && ITER == 1 )) && log "  $(( 2 * ${#PC[@]} )) cross-rail flows in $XW waves of at most $FS_CROSS_MAX (FS_CROSS_MAX), $( (( FS_CROSS_MAX == 1 )) && echo "one flow at a time" || echo "each wave A->B and B->A balanced")"
    for (( w = 0; w < XW; w++ )); do
        PHASE_OUT=$all.w$w; : > "$PHASE_OUT"
        [[ $mode == udp ]] || echo "### iteration:${ITER} phase:${PHASE}$( (( XW > 1 )) && echo " wave:$(( w + 1 ))/$XW")" >> "$res"
        for (( p = 0; p < ${#PC[@]}; p++ )); do
            xpaths $p
            if (( ${FS_CROSS_MAX:-0} == 1 && XW > 1 )); then   # cap 1: wave 2p runs X1, 2p+1 runs X2
                (( p == w / 2 )) || continue
                if (( w % 2 )); then run_path p2b_$p "${X2[@]}" $mode; else run_path p2a_$p "${X1[@]}" $mode; fi
            else
                (( p % XW == w )) || continue
                run_path p2a_$p "${X1[@]}" $mode; run_path p2b_$p "${X2[@]}" $mode
            fi
        done
        wait
        [[ $mode == udp ]] || column -t < "$PHASE_OUT" | tee -a "$res"
        cat "$PHASE_OUT" >> "$all"
    done
    PHASE_OUT=$all
}

# check_path key src_k src_r dst_k dst_r: writes OK or a reason to $PATHS/key
check_path() {
    local key=$1 sk=$2 sr=$3 dk=$4 dr=$5
    if ! rail_ok $sk $sr; then echo "DOWN ${T_HOST[$sk]}: ${RSTATE[$sk,$sr]}" > "$PATHS/$key"; return; fi
    if ! rail_ok $dk $dr; then echo "DOWN ${T_HOST[$dk]}: ${RSTATE[$dk,$dr]}" > "$PATHS/$key"; return; fi
    local m1=${RMTU[$sk,$sr]:-1500} m2=${RMTU[$dk,$dr]:-1500}
    # same rail: the larger MTU, so a 1500/9000 pair fails here, not pass at 1472 and run with retransmits.
    # Cross-rail (routed): the smaller of the two rails' MTUs (each rail at its highest host MTU, as its
    # router side would be), so a 4220 RDMA rail to a 9000 rail passes but a 1500 host on a 9000 rail fails.
    local r1=${RAIL_MTU[$sr]:-$m1} r2=${RAIL_MTU[$dr]:-$m2}
    local size=$(( (sr == dr ? (m1 > m2 ? m1 : m2) : (r1 < r2 ? r1 : r2)) - 28 ))
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
    if [[ $mode == check ]]; then echo "${RIP[$sk,$sr]} ${RIP[$dk,$dr]}" >> "$WORK/paths_ok"; return; fi   # FS_SKIP_IPERF=1
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

# System info per tested host, split into $SI/<host>/<item> (SYSINFO_SCRIPT)
collect_sysinfo() {
    local k f t
    log "System info: capturing on ${#ELIG[@]} hosts, at most ${FS_SYSINFO_TIMEOUT}s each (bundle: sysinfo/<host>/)..."
    for k in "${ELIG[@]}"; do
        throttle
        ( timeout "$FS_SYSINFO_TIMEOUT" ssh "${SSH_OPTS[@]}" "${T_TARGET[$k]}" $SUDO bash -s -- "${RNIC[$k,0]}" "${RNIC[$k,1]}" \
              <<<"$SYSINFO_SCRIPT" > "$WORK/si.$k" 2>> "$RUNLOG_SSH"; echo $? > "$WORK/si_rc.$k" ) &
    done
    wait
    for k in "${ELIG[@]}"; do
        f=$WORK/si.$k
        if ! grep -q '^=== SYSINFO ' "$f"; then log "WARNING: ${T_HOST[$k]}: no system info captured (see ssh_errors.log)"; continue; fi
        if [[ $(cat "$WORK/si_rc.$k") == 124 ]]; then
            log "WARNING: ${T_HOST[$k]}: system info cut off after ${FS_SYSINFO_TIMEOUT}s (FS_SYSINFO_TIMEOUT); the partial capture is kept"
            SI_CUT[${T_HOST[$k]}]=1
        fi
        t=$(awk '/^=== SYSINFO / {s = $3} /^n\/a: .* timed out after/ {printf "%s%s", c, s; c = " "}' "$f")
        [[ -n $t ]] && log "WARNING: ${T_HOST[$k]}: system info items timed out: $t"
        mkdir -p "$SI/${T_HOST[$k]}"
        awk -v d="$SI/${T_HOST[$k]}" '/^=== SYSINFO [^ \/]+ ===$/ {if (o) close(o); o = d "/" $3; next} o {print > o}' "$f"
    done
}

# Rail NIC receive config from the sysinfo capture: "host rail numa ring_cur/max pcie_GTs x width cur/max"
rx_config() {
    local k r f
    for k in "${ELIG[@]}"; do for r in 0 1; do
        f=$SI/${T_HOST[$k]}/nic-${RNIC[$k,$r]}
        [[ ${RNIC[$k,$r]} != - && -f $f ]] || continue
        awk -v h="${T_HOST[$k]}" -v r=$(rail_letter $r) '
            $1 == "numa_node" { numa = $2 }
            $1 ~ /^(current|max)_link_(speed|width)$/ { v = $2; sub(/[^0-9.].*/, "", v); L[$1] = v }
            /^--- / { sec = $3; g = "" }
            sec == "-g" && /^Pre-set maximums/ { g = "max" }
            sec == "-g" && /^Current hardware/ { g = "cur" }
            sec == "-g" && $1 == "RX:" && g != "" && !(g in R) { R[g] = $2 }
            END { ring = ("cur" in R && "max" in R) ? R["cur"] "/" R["max"] : "-"
                  pc = (L["current_link_speed"] != "" && L["max_link_speed"] != "") ? \
                       L["current_link_speed"] "x" L["current_link_width"] "/" L["max_link_speed"] "x" L["max_link_width"] : "-"
                  print h, r, (numa ~ /^-?[0-9]+$/ ? numa : "-"), ring, pc }' "$f"
    done; done
}

# hostctr_delta label pre post: receive counters that rose -> host_counters.txt "label host key delta"
hostctr_delta() {
    awk -v t="$1" 'NR == FNR {p[$1 " " $2] = $3; next}
        ($1 " " $2) in p && $3 ~ /^[0-9]+$/ && $3 > p[$1 " " $2] {print t, $1, $2, $3 - p[$1 " " $2]}' "$2" "$3" > "$WORK/hc_delta"
    cat "$WORK/hc_delta" >> "$COLLECT_DIR/host_counters.txt"
    # who answered this read, and with AER counters: a counter never read shows as "-" in host_rx.txt, not 0
    awk '{n[$1]++; if ($2 ~ /^aer_/) a[$1] = 1} END {for (h in n) print h, ((h in a) ? 1 : 0)}' "$3" >> "$WORK/hc_reads"
    HC_READS=$(( HC_READS + 1 ))
}

# hc_log what snapshot: one line on the receive drop counters in $WORK/hc_delta (squeezes stay in the table only)
hc_log() {
    local hd; hd=$(awk '$3 ~ /^(softnet_dropped|TCPRcvQDrop|TCPBacklogDrop|TCPOFODrop|RcvPruned|OfoPruned|TCPZeroWindowDrop|TCPMemoryPressures|aer_)/' "$WORK/hc_delta" | sort -k4 -rn)
    if [[ -n $hd ]]; then
        log "  Host receive drops in $1 ($(echo "$hd" | wc -l | tr -d ' ') counters rose; top 5): $(echo "$hd" | head -n 5 | awk '{printf "%s%s %s +%d", s, $2, $3, $4; s = "; "}')"
    else log "  No host receive drop counter rose in $1 ($(wc -l < "$2" | tr -d ' ') counters read)"; fi
}

# Kernel log per host since its own sysinfo epoch -> $SI/<host>/kernel-log
collect_klog() {
    local k e
    for k in "${ELIG[@]}"; do
        e=$(cat "$SI/${T_HOST[$k]}/epoch" 2>&1); [[ $e =~ ^[0-9]+$ ]] || continue
        throttle
        rbash "${T_TARGET[$k]}" "$e" <<<"$KLOG_SCRIPT" > "$SI/${T_HOST[$k]}/kernel-log" 2>> "$RUNLOG_SSH" &
    done
    wait
}

# Kernel log lines that point at the receive path or the NIC (a match is a lead, not a verdict)
KLOG_RE='aer|pcie bus error|link is down|tx timeout|transmit timeout|watchdog|hung_task|blocked for more than|out of memory|oom-kill|mlx5.*(err|fail|timeout|health)'

# host_rx.txt: per host, rail NIC config + receive counters over the run + iperf3 CPU + kernel log leads, with flags.
# Files: nicmap, ipmap, rx config, hostinfo (host governor irqbalance klog_hits), TCP results, host_counters, prio_counters.
HOSTRX_AWK='
# by argument position, not FNR: an empty file (no counter rose) has no first line and would shift the count
FNR == 1 { for (f = 1; f < ARGC; f++) if (ARGV[f] == FILENAME) break }
f == 1 { nh[$1] = $2; next }
f == 2 { ih[$1] = $2; next }
f == 3 { hosts[$1] = 1; numa[$1, $2] = $3; ring[$1, $2] = $4; pcie[$1, $2] = $5
         if (split($4, x, "/") == 2 && x[1] + 0 < x[2] + 0) fl[$1] = fl[$1] ",ring" $2 "<max"
         if (split($5, y, "/") == 2) { split(y[1], c, "x"); split(y[2], m, "x"); if (c[1] + 0 < m[1] + 0 || c[2] + 0 < m[2] + 0) fl[$1] = fl[$1] ",pcie" $2 "<max" }
         next }
f == 4 { gov[$1] = $2; irq[$1] = $3; kl[$1] = $4; th[$1] = $6; hosts[$1] = 1
         if ($5 == "missing") fl[$1] = fl[$1] ",sysinfo_missing"; else if ($5 == "cut") fl[$1] = fl[$1] ",sysinfo_partial"
         if ($2 != "-" && $2 != "performance") fl[$1] = fl[$1] ",gov:" $2; if ($4 > 0) fl[$1] = fl[$1] ",klog"; next }
f == 5 { split($1, ip, ","); for (i = 1; i <= NF; i++) if ($i ~ /^cpu:/) { split(substr($i, 5), u, "/")
             if (u[2] ~ /^[0-9.]+$/ && (!(ih[ip[2]] in rc) || u[2] + 0 > rc[ih[ip[2]]])) rc[ih[ip[2]]] = u[2] + 0
             if (u[1] ~ /^[0-9.]+$/ && (!(ih[ip[1]] in sc) || u[1] + 0 > sc[ih[ip[1]]])) sc[ih[ip[1]]] = u[1] + 0 }
         next }
f == 6 { k = $3; sub(/:.*/, "", k)
         if (k == "softnet_dropped") sd[$2] += $4; else if (k == "softnet_squeezed") sq[$2] += $4
         else if (k ~ /^(TCPRcvQDrop|TCPBacklogDrop|TCPOFODrop|RcvPruned|OfoPruned|TCPZeroWindowDrop)$/) td[$2] += $4
         else if (k ~ /^aer_/) ae[$2] += $4
         next }
f == 7 { if ($3 !~ /^rdma:/ && tolower($3) ~ /discard|out_of_buffer/) nd[nh[$2]] += $4; next }
f == 8 { hr[$1] = $2; ha[$1] = $3; next }
f == 9 { if ($2 !~ /^rdma:/ && tolower($2) ~ /discard|out_of_buffer/) dc[nh[$1]] = 1 }
function v(a, k) { return (k in a) ? a[k] : "-" }
END {
    print "Host NUMA_A/B Ring_A Ring_B PCIe_A PCIe_B Governor IRQbal RcvCPU% RcvThr% SndCPU% Softnet_drop Squeeze TCP_rcv_drop NIC_discard AER Klog Flags"
    for (h in hosts) {
        # "-" = not read (ssh failed, no AER in sysfs, no discard counter on this driver): unknown, not zero
        cr = (h in hr) ? hr[h] : 0
        if (cr == 0) fl[h] = fl[h] ",counters_unread"; else if (cr < ns) fl[h] = fl[h] ",counters_partial"
        SD = cr ? sd[h] + 0 : "-"; SQ = cr ? sq[h] + 0 : "-"; TD = cr ? td[h] + 0 : "-"
        ND = (h in dc) ? nd[h] + 0 : "-"; AE = (ha[h] > 0) ? ae[h] + 0 : "-"
        if (SD > 0) fl[h] = fl[h] ",softnet_drop"; if (TD > 0) fl[h] = fl[h] ",tcp_rcv_drop"
        if (ND > 0) fl[h] = fl[h] ",nic_discard"; if (AE > 0) fl[h] = fl[h] ",aer"
        # iperf3 3.16+ runs a thread per stream and sums their CPU, so judge per thread: raw / threads (th: FS_STREAMS
        # on 3.16+, else 1; an unknown version counts as 1, which can only flag more)
        RT = (h in rc) ? sprintf("%.1f", rc[h] / ((th[h] + 0 > 0) ? th[h] : 1)) : "-"
        if (RT != "-" && RT + 0 >= 90) fl[h] = fl[h] ",rcv_cpu>=90/thread"
        printf "%s %s/%s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s\n", h, v(numa, h SUBSEP "A"), v(numa, h SUBSEP "B"),
            v(ring, h SUBSEP "A"), v(ring, h SUBSEP "B"), v(pcie, h SUBSEP "A"), v(pcie, h SUBSEP "B"), v(gov, h), v(irq, h),
            ((h in rc) ? rc[h] : "-"), RT, ((h in sc) ? sc[h] : "-"), SD, SQ, TD, ND, AE, v(kl, h), (fl[h] == "" ? "-" : substr(fl[h], 2))
    }
}'

host_rx() {  # writes $COLLECT_DIR/host_rx.txt and prints the flagged hosts
    local k h g i n s t
    rx_config > "$WORK/rxcfg"
    for k in "${ELIG[@]}"; do
        h=${T_HOST[$k]}
        g=-; [[ -f $SI/$h/cpu-governor ]] && g=$(awk '$1 ~ /^[0-9]+$/ {printf "%s%s", s, $2; s = "+"} /^n\/a/ {printf "-"}' "$SI/$h/cpu-governor")
        i=$(cat "$SI/$h/irqbalance" 2>&1); [[ $i == running ]] && i=on || { [[ $i == "not running" ]] && i=off || i=-; }
        n=-; [[ -f $SI/$h/kernel-log ]] && n=$(grep -c -i -E "$KLOG_RE" "$SI/$h/kernel-log")
        s=ok; [[ -d $SI/$h ]] || s=missing; [[ -n ${SI_CUT[$h]} ]] && s=cut
        # iperf3 threads per receiving process: one per stream from 3.16 (its own --version, from sysinfo)
        t=1; [[ -f $SI/$h/iperf3 ]] && (( $(awk 'match($0, /iperf 3\.[0-9]+/) {print substr($0, RSTART + 8, RLENGTH - 8) + 0; exit}' "$SI/$h/iperf3") + 0 >= 16 )) && t=$FS_STREAMS
        echo "$h ${g:--} $i $n $s $t"
    done > "$WORK/hostinfo"
    grep "Gbits/sec" "$1" > "$WORK/rx_results"
    awk '{r[$1]++; a[$1] += $2} END {for (h in r) print h, r[h], a[h]}' "$WORK/hc_reads" > "$WORK/hcreads"
    [[ -f $WORK/prio_post ]] || : > "$WORK/prio_post"
    awk -v ns="$HC_READS" "$HOSTRX_AWK" "$WORK/nicmap" "$WORK/ipmap" "$WORK/rxcfg" "$WORK/hostinfo" "$WORK/rx_results" \
        "$COLLECT_DIR/host_counters.txt" "$COLLECT_DIR/prio_counters.txt" "$WORK/hcreads" "$WORK/prio_post" \
        | { read -r hdr; echo "$hdr"; sort -V; } > "$COLLECT_DIR/host_rx.txt"
}

# UDP loss placement, the same rule as the dashboard: per phase and receiving host,
# unaccounted = lost - (that host's InErrors + backlog drops + rail-NIC drops), floored at 0. The kernel
# also adds backlog drops to rx_dropped, so NIC = max(0, rx_dropped - backlog) + rx_out_of_buffer.
# Files: ipmap (ip host rail), nicmap (host_nic host rail), UDP results, host counters, NIC drops.
# -v t="iterN Ux" limits it to one phase. Prints: lost sent socket nic backlog unaccounted over (over: buckets beyond the loss).
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
f == 5 { k = $1 " " $2 SUBSEP nh[$3]; DR[k] += $4; DO[k] += $5 }
END { for (k in L) { nk = DR[k] - BK[k]; if (nk < 0) nk = 0; nk += DO[k]
                     lost += L[k]; sock += SK[k]; nic += nk; back += BK[k]
                     u = L[k] - SK[k] - nk - BK[k]; if (u > 0) un += u; else ov -= u }
      printf "%d %d %d %d %d %d %d\n", lost, sent, sock, nic, back, un, ov }'

udp_attr() {  # [iterN Ux] -> "lost sent socket nic backlog unaccounted over"
    awk -v t="$1" "$UDP_ATTR_AWK" "$WORK/ipmap" "$WORK/nicmap" "$UDP_RESULTS" \
        "$COLLECT_DIR/udp_host_counters.txt" "$COLLECT_DIR/udp_nic_drops.txt"
}

# cross_summary ipmap results: the inter-rail total (an iteration's cross-rail runs share the path between
# the rails at once) and, when only cross-rail runs miss the OK cut-off, where to look.
cross_summary() {
    local x xm am bm
    x=$(awk -F'[, ]+' 'NR == FNR { rail[$1] = $3; next }
        /^### / { split($2, a, ":"); it = a[2]; if ($4 ~ /^wave:/) it = it "w" substr($4, 6); next }
        { g = -1; rt = 0
          for (i = 1; i <= NF; i++) { if ($i == "Gbits/sec") g = $(i-1) + 0; if ($i ~ /^retransmits:/) { split($i, q, ":"); rt = q[2] + 0 } }
          if (g >= 0 && ($1 in rail) && ($2 in rail)) print (rail[$1] == rail[$2] ? rail[$1] : rail[$1] ">" rail[$2]), it, g, rt }' "$1" "$2")
    [[ $x == *'>'* ]] || return 0
    med() { sort -n | awk '{v[NR] = $1} END {if (NR) printf "%.1f", NR % 2 ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2}'; }
    xm=$(awk '$1 ~ />/ {print $3}' <<<"$x" | med); am=$(awk '$1 == "A" {print $3}' <<<"$x" | med); bm=$(awk '$1 == "B" {print $3}' <<<"$x" | med)
    awk -v xm="$xm" -v am="$am" -v bm="$bm" -v la="${LINE_A:-0}" -v lb="${LINE_B:-0}" -v ok="$FS_OK_PCT" -v cm="${FS_CROSS_MAX:-0}" '
        function bw(g) { return g >= 1000 ? sprintf("%.2f Tbps", g / 1000) : sprintf("%.1f Gbps", g) }
        function k(n) { return n >= 1e6 ? sprintf("%.1fM", n / 1e6) : (n >= 1e4 ? sprintf("%.1fk", n / 1e3) : n) }
        $1 ~ />/ { nx++; d[$1]++; tot[$2] += $3; xr += $4; if (index($2, "w")) wv = 1; next }
        { sr += $4 }
        END { for (i in tot) { ni++; s += tot[i]; if (ni == 1 || tot[i] < lo) lo = tot[i]; if (ni == 1 || tot[i] > hi) hi = tot[i] }
              if (ni == 1) printf "  Cross-rail total: %s over %d flows run at once", bw(s), nx
              else if (wv) printf "  Cross-rail total per wave (FS_CROSS_MAX=%d flows at once): largest %s, %s on average (%s to %s over %d waves), %d flows", cm, bw(hi), bw(s / ni), bw(lo), bw(hi), ni, nx
              else printf "  Cross-rail total per iteration: %s on average (%s to %s over %d iterations), %d flows", bw(s / ni), bw(lo), bw(hi), ni, nx
              printf " (A->B %d, B->A %d); median %s Gbps per flow; retransmits %s cross-rail vs %s same-rail\n", d["A>B"], d["B>A"], xm, k(xr), k(sr + 0)
              lx = la < lb ? la : lb; ca = la * ok / 100; cb = lb * ok / 100; cx = lx * ok / 100
              if (lx > 0 && xm + 0 < cx && (am != "" || bm != "") && (am == "" || am + 0 >= ca) && (bm == "" || bm + 0 >= cb))
                  printf "  Same-rail runs are OK, cross-rail runs are not: cross-rail median %s Gbps per flow (OK >= %g), same-rail median %s (A) / %s (B) Gbps. The hosts pass on their own rail, so the likely limit is the shared path between the rails (switch inter-link or spine), not the hosts.\n", xm, cx, (am == "" ? "-" : am), (bm == "" ? "-" : bm) }' <<<"$x"
}

# uplink_summary ipmap lldp nicdiag results: per leaf (its LLDP neighbour) and phase, the runs that cross
# to another leaf, out by the source's leaf and in by the destination's. With FS_SPINES/FS_SPINE_LINKS/
# FS_SPINE_GBPS, judged against C = spines x links x Gbps per direction. NICs without LLDP stay out.
UPLINK_AWK='
function med(s,   n, v, i, j, t) { n = split(s, v, " "); if (!n) return -1
    for (i = 2; i <= n; i++) { t = v[i] + 0; for (j = i - 1; j >= 1 && v[j] + 0 > t; j--) v[j + 1] = v[j]; v[j + 1] = t }
    return n % 2 ? v[(n + 1) / 2] + 0 : (v[n / 2] + v[n / 2 + 1]) / 2 }
function tb(g) { return sprintf("%.2f T", g / 1000) }
FNR == 1 { f++ }
f == 1 { rail[$1] = $3; nip++; next }
f == 2 { if ($4 != "unknown" && $4 != "") leaf[$3] = $4; next }
f == 3 { if ($4 ~ /^[0-9]+Mb\/s$/) { s = $4; sub(/Mb\/s/, "", s); sp[$3] = s / 1000 }; next }
/^### / { split($2, a, ":"); split($3, b, ":"); it = a[2]; ph = b[2]; if ($4 ~ /^wave:/) it = it " wave " substr($4, 6); next }
{ g = -1; for (i = 1; i <= NF; i++) if ($i == "Gbits/sec") { g = $(i-1) + 0; break }
  if (g < 0 || !($1 in rail) || !($2 in rail)) next
  if (!($1 in leaf) || !($2 in leaf)) { left++; next }
  x = leaf[$1]; y = leaf[$2]
  if (x == y) { if (rail[$1] == rail[$2]) same[x] = same[x] " " g; next }
  if (!((ph, it, x) in seen)) { seen[ph, it, x] = 1; key[++nk] = ph SUBSEP it SUBSEP x }
  if (!((ph, it, y) in seen)) { seen[ph, it, y] = 1; key[++nk] = ph SUBSEP it SUBSEP y }
  ob[ph, it, x] += g; ib[ph, it, y] += g; xl[ph, x] = xl[ph, x] " " g; xl[ph, y] = xl[ph, y] " " g; its[ph, it] = 1 }
END {
    for (ip in rail) if (ip in leaf) { nl++; dl[leaf[ip]] += (ip in sp) ? sp[ip] : (rail[ip] == "A" ? la : lb) } else nm++
    if (C > 0) printf "  Declared uplinks: %d spines x %d links x %dG = %s per leaf, each direction\n", N, M, S, tb(C)
    if (!nl) { if (C > 0) print "  Uplink check skipped: it needs LLDP, and no rail NIC reported a switch neighbour."; exit }
    # busiest iteration per (phase, leaf), in first-seen order
    for (k = 1; k <= nk; k++) { split(key[k], p, SUBSEP); bz = ob[key[k]] > ib[key[k]] ? ob[key[k]] : ib[key[k]]
        pl = p[1] SUBSEP p[3]; if (!(pl in best)) lst[++no] = pl; if (!(pl in best) || bz > best[pl]) { best[pl] = bz; bk[pl] = key[k] } }
    if (!no && C == 0) exit
    if (C == 0) print "  Uplink totals per leaf (set FS_SPINES, FS_SPINE_LINKS, FS_SPINE_GBPS to judge against uplink capacity):"
    if (nm) printf "  Uplinks: %d of %d rail NICs have no LLDP neighbour; their %d runs are left out of the leaf totals.\n", nm, nip, left
    if (!no) { print "  No runs crossed between leaves."; exit }
    lx = la < lb ? la : lb; okc = lx * ok / 100
    for (q = 1; q <= no; q++) { pl = lst[q]; split(pl, p, SUBSEP); k = bk[pl]; split(k, kk, SUBSEP)
        ni = 0; for (z in its) { split(z, zz, SUBSEP); if (zz[1] == p[1]) ni++ }
        bi = ni > 1 ? sprintf(" [iteration %s, busiest of %d]", kk[2], ni) : ""
        if (C == 0) { printf "  Uplinks %s phase %s: out %s / in %s%s; downlinks %s\n", p[2], p[1], tb(ob[k]), tb(ib[k]), bi, tb(dl[p[2]]); continue }
        pct = 100 * best[pl] / C
        printf "  Uplinks %s phase %s: out %s / in %s of %s declared (%.0f%%)%s; downlinks %s, oversubscribed %.1f:1\n", p[2], p[1], tb(ob[k]), tb(ib[k]), tb(C), pct, bi, tb(dl[p[2]]), dl[p[2]] / C
        xm = med(xl[pl]); sm = med(same[p[2]])
        if (lx > 0 && pct >= ok && xm < lx)
            printf "    at declared uplink capacity: oversubscribed %.1f:1 by design; cross-leaf runs (median %.1f Gbps) get their share of the uplinks, not line rate\n", dl[p[2]] / C, xm
        else if (lx > 0 && xm >= 0 && xm < okc && sm >= okc && pct < slow)
            printf "    uplinks carried only %.0f%% of declared capacity while cross-leaf runs were slow (median %.1f Gbps, OK >= %g) and same-leaf runs were OK (median %.1f); a link or spine may be down, or ECMP is uneven\n", pct, xm, okc, sm
    } }'

uplink_summary() {
    awk -F'[, ]+' -v C="${UPLINK_GBPS:-0}" -v N="$FS_SPINES" -v M="$FS_SPINE_LINKS" -v S="$FS_SPINE_GBPS" -v la="${LINE_A:-0}" -v lb="${LINE_B:-0}" \
        -v ok="$FS_OK_PCT" -v slow="$FS_SLOW_PCT" "$UPLINK_AWK" "$@"
}

# UDP phases U1 (same rail) and U2 (cross) on the current pairs, with host and NIC
# counters read around each phase so lost datagrams can be placed.
udp_phases() {
    local u p ck sk a=$WORK/udp.0
    collect_counters "$UDPHOST_SCRIPT" "$a.host"; collect_drops "$a.nic"
    for u in 1 2; do
        PHASE=U$u; PHASE_OUT=$WORK/phase.$ITER.$PHASE; : > "$PHASE_OUT"
        if [[ $u == 2 && $CROSS != on ]]; then log "Phase U2: skipped (cross-rail $CROSS)"; continue; fi
        [[ $u == 1 ]] && log "Phase U1: UDP A->A and B->B at once (-b 0)" || log "Phase U2: UDP cross-rail, A->B and B->A at once (-b 0)"
        echo "### iteration:${ITER} phase:${PHASE}" >> "$UDP_RESULTS"
        if [[ $u == 1 ]]; then
            for (( p = 0; p < ${#PC[@]}; p++ )); do
                ck=${PC[p]}; sk=${PS[p]}; run_path p1a_$p $ck 0 $sk 0 udp; run_path p1b_$p $sk 1 $ck 1 udp
            done
            wait
        else xwaves "$UDP_RESULTS" udp; fi
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
        log "  $PHASE loss: ${r[0]} of ${r[1]} datagrams lost ($(awk -v l="${r[0]}" -v s="${r[1]}" 'BEGIN {printf "%.3f", s ? 100 * l / s : 0}')%): receiver socket ${r[2]}, NIC ${r[3]}, kernel backlog ${r[4]}, unaccounted ${r[5]}$( (( r[6] > 0 )) && echo "; host counters exceed the loss by ${r[6]} (they count all of the phase's traffic, not only these flows)")"
        a=$b
    done
}

# fec_deltas label seconds: per-NIC FEC counter changes over the iteration, appended to
# fec_rates.txt as "label host_nic seconds d_corrected_blocks d_uncorrectable_blocks d_corrected_bits d_symbol_errors"
# (na = not exposed, reset = counter went backwards). Links carry symbols even when idle, so wall time is the right base.
fec_deltas() {
    awk -v t="$1" -v s="$2" 'NR==FNR {for (i = 2; i <= 5; i++) p[$1, i] = $i; next}
        ($1, 2) in p {printf "%s %s %d", t, $1, s
            for (i = 2; i <= 5; i++) printf " %s", ($i ~ /^[0-9]+$/ && p[$1, i] ~ /^[0-9]+$/) ? ($i + 0 >= p[$1, i] + 0 ? $i - p[$1, i] : "reset") : ($i == "off" ? "off" : "na")
            print ""}' "$WORK/fec_pre" "$WORK/fec_post" > "$WORK/fec_delta"
    cat "$WORK/fec_delta" >> "$COLLECT_DIR/fec_rates.txt"
    local seen unc off
    seen=$(awk '$4 ~ /^[0-9]+$/ || $6 ~ /^[0-9]+$/' "$WORK/fec_delta" | wc -l | tr -d ' ')
    off=$(awk '$4 == "off"' "$WORK/fec_delta" | wc -l | tr -d ' ')
    unc=$(awk '$5 ~ /^[0-9]+$/ && $5 > 0 {printf "%s(%s) ", $2, $5}' "$WORK/fec_delta")
    log "FEC over ${2}s: counters exposed on $seen of $(wc -l < "$WORK/fec_delta" | tr -d ' ') rail NICs$( (( off )) && echo "; FEC off on $off")"
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

# cleanup's inputs, so the wrapper can finish cleanup when main dies without it: SIGKILL, OOM, or (seen 1 in ~76
# Ctrl-C runs under load) bash running the INT trap's exit but never the EXIT trap. Written whole, then renamed.
save_state() {
    [[ -n $STATE_FILE ]] || return 0
    declare -p WORK SOCKET_DIR COLLECT_DIR LOADED DONE LOCKED RUN_ID STARTED T_TARGET REACH_ONLY ELIG SSH_OPTS SUDO \
        FS_SSH_USER 2>&1 | grep '^declare ' > "$STATE_FILE.tmp" && mv -f "$STATE_FILE.tmp" "$STATE_FILE"
}

cleanup() {
    local rc=$? k   # first: bash 5.1 would otherwise end a piped main with cleanup's last status
    trap '' INT TERM HUP PIPE   # nothing may cut cleanup short: a second signal, or a dead tee (EPIPE, not death)
    stop_servers
    [[ -n $LOCKED ]] && lock_all release
    for k in "${T_TARGET[@]}" "${!REACH_ONLY[@]}"; do
        ssh -O exit -o "ControlPath=$SOCKET_DIR/%C" -l "$FS_SSH_USER" "$k" >> "$WORK/cleanup.log" 2>&1 &
    done
    wait
    if [[ -z $DONE ]]; then
        if [[ -n $LOADED ]]; then { [[ -f $FS_RUNLOG ]] && cp "$FS_RUNLOG" "$COLLECT_DIR/run.log"; log "Run did not finish; partial data left in $COLLECT_DIR"; }
        else rm -rf "${COLLECT_DIR:?}"; fi
    fi
    rm -rf "${SOCKET_DIR:?}" "${WORK:?}"
    [[ -z $STATE_FILE ]] || rm -f "$STATE_FILE"   # last: the wrapper reruns a cleanup cut short
    exit $rc
}

# Every FS_* setting this tool reads. Any other FS_* in the environment is a typo that would be silently
# ignored (a dropped letter, say), so it stops the run. A regress test keeps the list complete.
FS_KNOWN="FS_BUSY_CHECK FS_BUSY_OK FS_CROSS_MAX FS_CROSS_RAIL FS_DURATION FS_EXPECT_HOSTS FS_HOSTS FS_IGNORE_LOCK FS_ITER FS_LABEL FS_LINE_GBPS FS_LOCK_FILE FS_MAX_TARGETS FS_MESH FS_NICS FS_OK_PCT FS_OUT_DIR FS_PORT FS_RAIL_A FS_RAIL_B FS_RAILS FS_RUNLOG FS_SKIP_IPERF FS_SLOW_PCT FS_SPINE_GBPS FS_SPINE_LINKS FS_SPINES FS_SSH_PARALLEL FS_SSH_RETRY_PARALLEL FS_SSH_USER FS_STREAMS FS_SYSFS FS_SYSINFO_TIMEOUT FS_TOS FS_UDP FS_UDP_DURATION"

# edit_distance a b: Levenshtein distance, for the "did you mean" hint
edit_distance() {
    local a=$1 b=$2 i j c x y z; local -a p q
    for (( j = 0; j <= ${#b}; j++ )); do p[j]=$j; done
    for (( i = 1; i <= ${#a}; i++ )); do
        q=($i)
        for (( j = 1; j <= ${#b}; j++ )); do
            [[ ${a:i-1:1} == "${b:j-1:1}" ]] && c=0 || c=1
            x=$(( p[j] + 1 )); y=$(( q[j-1] + 1 )); z=$(( p[j-1] + c ))
            q[j]=$(( x < y ? (x < z ? x : z) : (y < z ? y : z) ))
        done
        p=("${q[@]}")
    done
    echo "${p[${#b}]}"
}

check_settings() {
    local v k d best bd
    for v in $(compgen -e); do
        [[ $v == FS_* && " $FS_KNOWN " != *" $v "* ]] || continue
        best=; bd=99
        for k in $FS_KNOWN; do d=$(edit_distance "$v" "$k"); (( d < bd )) && { bd=$d; best=$k; }; done
        (( bd == 1 || bd <= (${#v} - 3) / 3 )) && die "unknown setting $v; did you mean $best?"
        die "unknown setting $v; this tool reads: ${FS_KNOWN// /, }"
    done
}

# ======================================================================

main() {
    (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) )) || die "needs bash 4.3+"
    [[ $1 == -h || $1 == --help ]] && { usage; exit 0; }
    check_settings

    : "${FS_ITER:=5}" "${FS_STREAMS:=16}" "${FS_PORT:=5201}" "${FS_SSH_USER:=root}"
    : "${FS_SSH_PARALLEL:=64}" "${FS_SSH_RETRY_PARALLEL:=8}" "${FS_MAX_TARGETS:=4096}" "${FS_OUT_DIR:=.}"
    : "${FS_OK_PCT:=75}" "${FS_SLOW_PCT:=50}" "${FS_BUSY_OK:=0}" "${FS_SYSINFO_TIMEOUT:=300}"
    # Default busy check: any WEKA container in STATE Running (docs.weka.io CLI reference, `weka local ps`)
    : "${FS_BUSY_CHECK:=$WEKA_BUSY_CHECK}"
    [[ $FS_BUSY_CHECK == none ]] && FS_BUSY_CHECK=""
    [[ $1 =~ ^[0-9]+$ ]] && FS_DURATION=$1
    : "${FS_DURATION:=120}" "${FS_UDP:=0}" "${FS_MESH:=0}" "${FS_SKIP_IPERF:=0}"
    : "${FS_UDP_DURATION:=$FS_DURATION}"
    [[ $FS_UDP == 0 || $FS_UDP == 1 ]] || die "FS_UDP must be 0 or 1, got '$FS_UDP'"
    [[ $FS_MESH == 0 || $FS_MESH == 1 ]] || die "FS_MESH must be 0 or 1, got '$FS_MESH'"
    [[ $FS_SKIP_IPERF == 0 || $FS_SKIP_IPERF == 1 ]] || die "FS_SKIP_IPERF must be 0 or 1, got '$FS_SKIP_IPERF'"
    (( FS_SKIP_IPERF && FS_UDP == 1 )) && die "FS_UDP=1 is a load test; FS_SKIP_IPERF=1 sends no load: set one of them"
    [[ -z $FS_CROSS_RAIL || $FS_CROSS_RAIL == 0 || $FS_CROSS_RAIL == 1 ]] || die "FS_CROSS_RAIL must be 0 or 1, got '$FS_CROSS_RAIL'"
    [[ -z $FS_CROSS_RAIL ]] && FS_CROSS_RAIL=1
    ITER_ALL=0; [[ $FS_ITER == all ]] && { ITER_ALL=1; FS_ITER=1; }   # 2 x the pairing rounds, set once the hosts are known
    [[ -z $FS_CROSS_MAX || $FS_CROSS_MAX =~ ^[1-9][0-9]*$ ]] || die "FS_CROSS_MAX must be a positive integer (cross-rail flows at once), got '$FS_CROSS_MAX'"
    local v
    for v in FS_DURATION FS_UDP_DURATION FS_SYSINFO_TIMEOUT FS_ITER FS_STREAMS FS_PORT FS_SSH_PARALLEL FS_SSH_RETRY_PARALLEL FS_MAX_TARGETS FS_OK_PCT FS_SLOW_PCT; do
        [[ ${!v} =~ ^[0-9]+$ ]] && (( ${!v} > 0 )) || die "$v must be a positive integer, got '${!v}'"
    done
    (( FS_STREAMS >= 2 )) || die "FS_STREAMS must be >= 2 (iperf3 prints no [SUM] line for one stream)"
    [[ -z $FS_LINE_GBPS || $FS_LINE_GBPS =~ ^[1-9][0-9]*(,[1-9][0-9]*)?$ ]] || die "FS_LINE_GBPS must be an integer (both rails) or A,B integers, got '$FS_LINE_GBPS'"
    # declared uplinks: all three or none, and no default speed (a guess could pass a fault)
    local sv smiss=; UPLINK_GBPS=0
    for sv in FS_SPINES FS_SPINE_LINKS FS_SPINE_GBPS; do
        if [[ -z ${!sv} ]]; then smiss+=" $sv"
        elif ! [[ ${!sv} =~ ^[1-9][0-9]*$ ]]; then die "$sv must be a positive integer, got '${!sv}'"; fi
    done
    if [[ -z $smiss ]]; then UPLINK_GBPS=$(( FS_SPINES * FS_SPINE_LINKS * FS_SPINE_GBPS ))
    elif [[ $smiss != " FS_SPINES FS_SPINE_LINKS FS_SPINE_GBPS" ]]; then die "FS_SPINES, FS_SPINE_LINKS and FS_SPINE_GBPS go together; missing:$smiss"; fi
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
    SI=$COLLECT_DIR/sysinfo
    RUNLOG_SSH=$COLLECT_DIR/ssh_errors.log

    SUDO=""; [[ $FS_SSH_USER == root ]] || SUDO="sudo -n"
    SSH_OPTS=(-o ControlMaster=auto -o ControlPersist=15m -o "ControlPath=$SOCKET_DIR/%C"
              -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5
              -o ServerAliveInterval=15 -l "$FS_SSH_USER")
    declare -gA T_TARGET T_HOST DISC RNIC RIP RMTU RSTATE STARTED REACH_ONLY DOWN_IP SI_CUT
    declare -ga RAIL_MTU=()   # per rail: highest MTU among its usable hosts
    trap cleanup EXIT
    # explicit exits so the EXIT trap always runs on Ctrl-C or kill, whatever command was running
    trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
    trap '' PIPE   # a dead log tee must not abort the run: log writes just fail, results go to files
    parse_rails
    log "Begin $(date) | ${#TARGETS[@]} targets | rails: $RAIL_MODE A=${RAIL_SPEC[0]// /,} B=${RAIL_SPEC[1]// /,} | ${FS_DURATION}s x $( (( ITER_ALL )) && echo "all (2 x pairing rounds)" || echo $FS_ITER) iterations$([[ -n $FS_CROSS_MAX ]] && echo " | cross-rail at most $FS_CROSS_MAX flows at once")"
    log "Temp: $WORK $SOCKET_DIR $COLLECT_DIR $FS_RUNLOG $STATE_FILE (all removed at the end; the collect dir is kept if a run is cut short)"
    save_state

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
    if (( ${#ELIG[@]} < 2 )); then   # the work dir goes with the stop, so show the left-out hosts here
        [[ -s $COLLECT_DIR/excluded.txt ]] && { log "Left out (first 20):"; head -n 20 "$COLLECT_DIR/excluded.txt" | sed 's/^/#   /' >&2; }
        die "need at least 2 hosts on the rails, found ${#ELIG[@]}"
    fi
    (( ${#NO_IPERF[@]} == 0 || FS_SKIP_IPERF )) || die "iperf3 missing on ${#NO_IPERF[@]} hosts: ${NO_IPERF[*]}"
    if (( ${#BUSY[@]} > 0 )); then
        if (( FS_SKIP_IPERF )); then
            log "${#BUSY[@]} hosts in use per FS_BUSY_CHECK: fine with FS_SKIP_IPERF=1 (no test load is sent)"
        elif [[ $FS_BUSY_OK != 1 ]]; then
            local nb=${#BUSY[@]}; mapfile -t BUSY < <(printf "%s\n" "${BUSY[@]}" | sort -V)
            die "FS_BUSY_CHECK: $nb hosts in use or check failed$( (( nb > 10 )) && echo " (first 10 of $nb)"): ${BUSY[*]:0:10}. Line-rate load can starve cluster heartbeats and get nodes evicted. Stop the cluster's I/O and set FS_BUSY_OK=1 to proceed, or set FS_SKIP_IPERF=1 to run every check but the bandwidth runs."
        else log "WARNING: ${#BUSY[@]} hosts in use per FS_BUSY_CHECK; FS_BUSY_OK=1 given"; fi
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
    # run lock before any preflight: a second run on the same hosts would kill this one's iperf3 servers
    take_locks
    : > "$COLLECT_DIR/rail_anomalies.txt"   # preflight findings: host kind detail...
    # one MTU per rail expected; name the odd hosts (their paths fail the no-fragment check)
    local rr
    for rr in 0 1; do
        RAIL_MTU[$rr]=$(for k in "${ELIG[@]}"; do rail_ok $k $rr && echo "${RMTU[$k,$rr]:-1500}"; done | sort -n | tail -n1)
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

    # line rate: per rail only when declared (FS_LINE_GBPS=A,B); otherwise the faster rail's most common
    # speed for both, so a whole rail that came up slow is not judged against itself
    local LINE_A=${FS_LINE_GBPS%,*} LINE_B=${FS_LINE_GBPS#*,} LINE_GBPS k MODE_A MODE_B
    for k in "${ELIG[@]}"; do echo "${RIP[$k,0]} A"; echo "${RIP[$k,1]} B"; done > "$WORK/iprail"
    if [[ -z $FS_LINE_GBPS ]]; then
        read -r MODE_A MODE_B <<<"$(awk 'NR == FNR {rail[$1] = $2; next}
            ($3 in rail) && $4 ~ /^[0-9]+Mb\/s$/ {s = $4; sub(/Mb\/s/, "", s); n[rail[$3] " " s / 1000]++}
            END {for (k in n) {split(k, p, " "); r = p[1]; v = p[2] + 0
                     if (n[k] > c[r] || (n[k] == c[r] && v > m[r])) {c[r] = n[k]; m[r] = v}}
                 a = ("A" in m) ? m["A"] : m["B"]; b = ("B" in m) ? m["B"] : a; print a, b}' "$WORK/iprail" "$NIC_DIAG")"
        LINE_A=$(( ${MODE_A:-0} > ${MODE_B:-0} ? ${MODE_A:-0} : ${MODE_B:-0} )); (( LINE_A )) || LINE_A=; LINE_B=$LINE_A
        [[ -n $MODE_A && $MODE_A != "$MODE_B" ]] && log "WARNING: rails run at different speeds (most NICs: rail A ${MODE_A}G, rail B ${MODE_B}G): both judged at ${LINE_A}G. If that is by design, set FS_LINE_GBPS=$MODE_A,$MODE_B"
    fi
    LINE_GBPS=$(( ${LINE_A:-0} > ${LINE_B:-0} ? ${LINE_A:-0} : ${LINE_B:-0} )); (( LINE_GBPS )) || LINE_GBPS=
    if [[ -n $LINE_GBPS ]]; then
        cutoffs() { awk -v l="$1" -v o="$FS_OK_PCT" -v s="$FS_SLOW_PCT" 'BEGIN {printf "%gG (OK >= %gG, SLOW >= %gG)", l, l * o / 100, l * s / 100}'; }
        if [[ $LINE_A == "$LINE_B" ]]; then log "Link speed for cut-offs: $(cutoffs "$LINE_A")"
        else log "Link speed for cut-offs: rail A $(cutoffs "$LINE_A"), rail B $(cutoffs "$LINE_B")"; fi
        awk -v a="$(( LINE_A * 1000 ))Mb/s" -v b="$(( LINE_B * 1000 ))Mb/s" 'NR == FNR {rail[$1] = $2; next}
            $4 ~ /^[0-9]+Mb\/s$/ && ($3 in rail) && $4 != (rail[$3] == "A" ? a : b) {printf "#   %s %s %s (rail %s)\n", $1, $2, $4, rail[$3]}' \
            "$WORK/iprail" "$NIC_DIAG" > "$WORK/offspeed"
        if [[ -s $WORK/offspeed ]]; then
            if [[ $LINE_A == "$LINE_B" ]]; then log "NICs not at ${LINE_A}G:"; else log "NICs not at their rail's speed:"; fi
            cat "$WORK/offspeed" >&2
        fi
    else
        log "WARNING: no link speed from ethtool and FS_LINE_GBPS unset; no OK/SLOW status"
    fi

    lock_all touch   # preflight can be long (mesh); refresh before load
    collect_sysinfo
    rx_config > "$WORK/rxcfg"
    log "Rail NIC receive config: $(awk '{ n++; if (split($4, x, "/") == 2 && x[1] + 0 < x[2] + 0) r++
        if (split($5, y, "/") == 2) { split(y[1], c, "x"); split(y[2], m, "x"); if (c[1] + 0 < m[1] + 0 || c[2] + 0 < m[2] + 0) p++ } }
        END { printf "%d NICs read; rx ring below its maximum on %d, PCIe link below its maximum on %d", n, r, p }' "$WORK/rxcfg")"
    # --- 5. iperf3 servers ---
    LOADED=1
    if (( FS_SKIP_IPERF )); then
        log "FS_SKIP_IPERF=1: no iperf3 servers, no load; path checks, counters and system info only"; save_state
    else
        log "Stopping stray iperf3 and starting servers on port $FS_PORT..."
        for k in "${ELIG[@]}"; do STARTED[$k]=1; done; save_state
        for k in "${ELIG[@]}"; do
            local ips=()
            for r in 0 1; do rail_ok $k $r && ips+=("${RIP[$k,$r]}"); done
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
    fi

    # --- 6. iterations ---
    local RESULTS=$COLLECT_DIR/iperf3_results.txt DROP_TOTALS=$COLLECT_DIR/packet_drops.txt
    PATH_EXCL=$COLLECT_DIR/paths_excluded.txt
    : > "$RESULTS"; : > "$DROP_TOTALS"; : > "$COLLECT_DIR/link_flaps.txt"; : > "$PATH_EXCL"
    ORDER=($(for k in "${ELIG[@]}"; do echo "$k ${T_HOST[$k]}"; done | sort -V -k2 | awk '{print $1}'))
    local FIRST_HOST=${T_HOST[${ORDER[0]}]}
    local n=${#ORDER[@]} p ck sk
    ROT=("${ORDER[@]}"); (( n % 2 )) && ROT+=(-)
    local rounds=$(( ${#ROT[@]} - 1 )) per=$(( n / 2 )) total=$(( n * (n - 1) / 2 ))
    (( ITER_ALL )) && FS_ITER=$(( 2 * rounds ))
    local used=$(( FS_ITER < rounds ? FS_ITER : rounds ))
    PAIRS_COVERED=$(( used * per )); PAIRS_TOTAL=$total
    PATHS_PLANNED=0; DROP_READS_MIN=-1
    log "Pairing: round-robin, $per pairs per iteration; $FS_ITER iterations cover $PAIRS_COVERED of $total host pairs$( (( FS_ITER < rounds )) && echo " (all pairs need FS_ITER=$rounds)")"
    # a pair's 8 directed NIC paths: cycle 1 runs 4, cycle 2 (same pairings, client and server swapped) the other 4
    local -A DIRECTED=(); local dper=$(( FS_CROSS_RAIL == 0 ? 2 : 4 ))
    DIRECTED_TOTAL=$(( n * (n - 1) * dper ))
    log "Directed NIC paths: $(( (FS_ITER < 2 * rounds ? FS_ITER : 2 * rounds) * per * dper )) of $DIRECTED_TOTAL planned$( (( FS_ITER < 2 * rounds )) && echo " (every direction on every NIC pair needs FS_ITER=$(( 2 * rounds )), or FS_ITER=all)")"
    (( FS_ITER > rounds && FS_ITER <= 2 * rounds )) && log "Iterations $(( rounds + 1 ))-$FS_ITER repeat the pairings with client and server swapped"
    (( FS_ITER > 2 * rounds )) && log "Iterations past $(( 2 * rounds )) repeat the pairings from the start"
    [[ -n $FS_TOS ]] && log "Marking: iperf3 -S $FS_TOS = DSCP $(( FS_TOS >> 2 )), ECN bits $(( FS_TOS & 3 )) (TCP: the kernel owns the ECN bits)"
    : > "$COLLECT_DIR/pairs.txt"; : > "$COLLECT_DIR/prio_counters.txt"; : > "$COLLECT_DIR/fec_rates.txt"; : > "$COLLECT_DIR/host_counters.txt"
    : > "$WORK/hc_reads"; HC_READS=0; : > "$WORK/paths_ok"
    # rail IP -> host/rail, and host_nic -> host, for the summary and UDP loss placement
    for k in "${ELIG[@]}"; do
        [[ ${RIP[$k,0]} != none ]] && echo "${RIP[$k,0]} ${T_HOST[$k]} A"
        [[ ${RIP[$k,1]} != none ]] && echo "${RIP[$k,1]} ${T_HOST[$k]} B"
    done > "$WORK/ipmap"
    for k in "${ELIG[@]}"; do for r in 0 1; do
        [[ ${RNIC[$k,$r]} != - ]] && echo "${T_HOST[$k]}_${RNIC[$k,$r]} ${T_HOST[$k]} $( (( r )) && echo B || echo A)"
    done; done > "$WORK/nicmap"
    UDP_RESULTS=$COLLECT_DIR/iperf3_udp_results.txt
    if [[ $FS_UDP == 1 ]]; then
        : > "$UDP_RESULTS"; : > "$COLLECT_DIR/udp_host_counters.txt"; : > "$COLLECT_DIR/udp_nic_drops.txt"
        log "UDP pass on: phases U1/U2 after the TCP phases, ${FS_UDP_DURATION}s each, no rate cap"
    fi
    # cross-rail phase: on, or off only when the operator says the rails are separate fabrics
    CROSS=on; CROSS_UNROUTED=0; [[ $FS_CROSS_RAIL == 0 ]] && { CROSS=off; log "Cross-rail phase off (FS_CROSS_RAIL=0): A<->B is not tested"; }
    local cross_decided=; [[ $CROSS == on ]] || cross_decided=1
    for (( ITER = 1; ITER <= FS_ITER; ITER++ )); do
        RND=$(( (ITER - 1) % rounds )); round_pairs $RND
        if (( (ITER - 1) / rounds % 2 )); then local -a tmp=("${PC[@]}"); PC=("${PS[@]}"); PS=("${tmp[@]}"); fi
        lock_all touch
        local per=4; [[ $CROSS == on ]] || per=2
        PATHS_PLANNED=$(( PATHS_PLANNED + per * ${#PC[@]} ))
        log "============ Iteration $ITER of $FS_ITER (${#PC[@]} pairs) ============"
        [[ -n $SITOUT ]] && log "Sits out this iteration (odd host count): ${T_HOST[$SITOUT]}"
        for (( p = 0; p < ${#PC[@]}; p++ )); do echo "$ITER ${T_HOST[${PC[p]}]} ${T_HOST[${PS[p]}]}"; done >> "$COLLECT_DIR/pairs.txt"
        PATHS=$WORK/paths.$ITER; mkdir -p "$PATHS"
        for (( p = 0; p < ${#PC[@]}; p++ )); do
            ck=${PC[p]}; sk=${PS[p]}
            check_path p1a_$p $ck 0 $sk 0; check_path p1b_$p $sk 1 $ck 1
            [[ $CROSS == on ]] && { xpaths $p; check_path p2a_$p "${X1[@]}"; check_path p2b_$p "${X2[@]}"; }
            DIRECTED["$ck 0 $sk 0"]=1; DIRECTED["$sk 1 $ck 1"]=1
            [[ $CROSS == on ]] && { DIRECTED["${X1[*]}"]=1; DIRECTED["${X2[*]}"]=1; }
        done
        wait
        if [[ -z $cross_decided && ${#PC[@]} -gt 0 ]]; then
            cross_decided=1
            local xn xr sr
            xn=$(ls "$PATHS" | grep -c '^p2'); xr=$(cat "$PATHS"/p2* | grep -c '^ROUTE'); sr=$(cat "$PATHS"/p1* | grep -c '^ROUTE')
            if (( xn > 0 && xr == xn && sr == 0 )); then
                CROSS_UNROUTED=1   # still counted: a site missing its inter-rail routes looks the same
                log "WARNING: rails are not routed to each other (all $xn A<->B path checks failed on routing, no same-rail one did): either separate fabrics by design (rerun with FS_CROSS_RAIL=0) or inter-rail routing missing on every host. The skips count until you say which."
            fi
        fi
        local bad nchk; bad=$(grep -Lx OK "$PATHS"/* | wc -l | tr -d ' '); nchk=$(ls "$PATHS" | wc -l | tr -d ' ')
        log "Path checks (egress route, ping, MTU no-fragment): $(( nchk - bad )) OK, $bad excluded"
        if (( FS_SKIP_IPERF )); then   # every planned path's check is recorded; the counters get one window, at the end
            for (( p = 0; p < ${#PC[@]}; p++ )); do
                ck=${PC[p]}; sk=${PS[p]}; PHASE=1; run_path p1a_$p $ck 0 $sk 0 check; run_path p1b_$p $sk 1 $ck 1 check
                [[ $CROSS == on ]] && { PHASE=2; xpaths $p; run_path p2a_$p "${X1[@]}" check; run_path p2b_$p "${X2[@]}" check; }
            done
            (( ITER < FS_ITER )) && { echo; continue; }
        fi

        local DROPS_PRE=$WORK/drops_pre DROPS_POST=$WORK/drops_post
        collect_drops "$DROPS_PRE"
        collect_counters "$PRIO_SCRIPT" "$WORK/prio_pre"
        collect_counters "$FEC_SCRIPT" "$WORK/fec_pre"; local fec_t0; fec_t0=$(date +%s)
        collect_counters "$HOSTCTR_SCRIPT" "$WORK/hc.pre"; local hc_prev=$WORK/hc.pre
        if (( FS_SKIP_IPERF )); then
            log "Observation window: ${FS_DURATION}s with no test load (FS_SKIP_IPERF=1); the counter changes below are the cluster's own traffic"
            sleep "$FS_DURATION"
            collect_counters "$HOSTCTR_SCRIPT" "$WORK/hc.obs"; hostctr_delta "iter${ITER}_obs" "$hc_prev" "$WORK/hc.obs"
            hc_log "the observation window" "$WORK/hc.obs"
        else
            for PHASE in 1 2; do
                PHASE_OUT=$WORK/phase.$ITER.$PHASE; : > "$PHASE_OUT"
                if [[ $PHASE == 2 && $CROSS != on ]]; then log "Phase 2: skipped (cross-rail $CROSS)"; continue; fi
                [[ $PHASE == 1 ]] && log "Phase 1: A->A and B->B at once" || log "Phase 2: cross-rail, A->B and B->A at once"
                if [[ $PHASE == 1 ]]; then
                    echo "### iteration:${ITER} phase:${PHASE}" >> "$RESULTS"
                    for (( p = 0; p < ${#PC[@]}; p++ )); do
                        ck=${PC[p]}; sk=${PS[p]}; run_path p1a_$p $ck 0 $sk 0; run_path p1b_$p $sk 1 $ck 1
                    done
                    wait
                    column -t < "$PHASE_OUT" | tee -a "$RESULTS"
                else xwaves "$RESULTS"; fi
                local errs; errs=$(grep -c ',ERROR' "$PHASE_OUT")
                [[ $errs -gt 0 ]] && log "WARNING: $errs runs in phase $PHASE returned no result (lines with ERROR above)"
                collect_counters "$HOSTCTR_SCRIPT" "$WORK/hc.$PHASE"; hostctr_delta "iter${ITER}_p$PHASE" "$hc_prev" "$WORK/hc.$PHASE"; hc_prev=$WORK/hc.$PHASE
                hc_log "phase $PHASE" "$WORK/hc.$PHASE"
            done
        fi
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
            # which priority carried the bytes, per rail (shows where each rail's DSCP map put the traffic)
            log "Traffic by priority in iteration $ITER (rx+tx bytes): $(awk '
                NR == FNR { rail[$1] = $3; next }
                { l = tolower($3) } l ~ /byte/ && match(l, /pri(ority|o)?_?[0-9]/) {
                    p = substr(l, RSTART, RLENGTH); gsub(/[^0-9]/, "", p); r = ($2 in rail) ? rail[$2] : "?"
                    b[r " " p] += $4; n++ }
                END { for (r = 1; r <= 3; r++) { R = substr("AB?", r, 1); t = ""
                          for (p = 0; p <= 7; p++) if ((R " " p) in b) t = t sprintf(" prio%d %s", p, b[R " " p] < 5e7 ? "<0.1GB" : sprintf("%.1fGB", b[R " " p] / 1e9))
                          if (t != "") printf "rail %s:%s  ", R, t }
                      if (!n) printf "no per-priority byte counters" }' "$WORK/nicmap" "$WORK/prio_delta")"
            awk 'tolower($3) !~ /byte|packet/ || $3 ~ /^rdma:/' "$WORK/prio_delta" | sort -k4 -rn > "$WORK/prio_events"
            if [[ -s $WORK/prio_events ]]; then
                local ne; ne=$(wc -l < "$WORK/prio_events" | tr -d ' ')
                log "Pause/ECN/discard/RDMA counters that rose ($( (( ne > 10 )) && echo "top 10 of $ne" || echo "$ne")):"
                head -n 10 "$WORK/prio_events" | column -t | sed 's/^/#   /' >&2
            else
                log "No pause/ECN/discard/RDMA counter rose in iteration $ITER ($(wc -l < "$WORK/prio_post" | tr -d ' ') counters read, $(awk '$2 ~ /^rdma:/' "$WORK/prio_post" | wc -l | tr -d ' ') of them RDMA)"
            fi
        else
            log "No priority/pause/ECN/RDMA counter rose in iteration $ITER ($(wc -l < "$WORK/prio_post" | tr -d ' ') counters read, $(awk '$2 ~ /^rdma:/' "$WORK/prio_post" | wc -l | tr -d ' ') of them RDMA)"
        fi
        local iter_drops; iter_drops=$(compute_drops "$DROPS_PRE" "$DROPS_POST" "iter${ITER}")
        if [[ -n $iter_drops ]]; then
            log "Drops during iteration $ITER:"; echo "$iter_drops" | awk '{NF--; print}' | column -t | sed 's/^/#   /' >&2
            echo "$iter_drops" >> "$DROP_TOTALS"
        else
            log "No drop counter increases in iteration $ITER ($(wc -l < "$DROPS_POST" | tr -d ' ') NICs read)"
        fi
        # a rail link that went down during the iteration: its runs measured a flap, not the fabric
        local flaps; flaps=$(awk -v it="iter$ITER" 'NR == FNR {c[$1] = $6; next}
            ($1 in c) && $6 ~ /^[0-9]+$/ && c[$1] ~ /^[0-9]+$/ && $6 > c[$1] {print it, $1, $2, $6 - c[$1]}' "$DROPS_PRE" "$DROPS_POST")
        if [[ -n $flaps ]]; then
            log "WARNING: rail links went down during iteration $ITER (host_nic ip carrier-down count):"
            echo "$flaps" | cut -d' ' -f2- | column -t | sed 's/^/#   /' >&2
            echo "$flaps" >> "$COLLECT_DIR/link_flaps.txt"
        fi
        echo
    done

    collect_klog
    host_rx "$RESULTS"

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
            echo "Per-host throughput, worst first (Gbps; Rail_A/Rail_B: same-rail runs; Cross: A<->B runs, judged at the slower rail's rate):"
            # A cross-rail run measures a path, not either rail (routes decide which NIC carries it), so it gets its own
            # column. Status: the worst column, each its average judged at its own line rate (Cross: the slower rail's);
            # (cross) = only Cross is that bad, the same-rail paths were better.
            grep 'Gbits/sec' "$RESULTS" | awk -F'[, ]+' -v la="${LINE_A:-0}" -v lb="${LINE_B:-0}" -v ok="$FS_OK_PCT" -v slow="$FS_SLOW_PCT" '
                NR==FNR { host[$1]=$2; rail[$1]=$3; next }
                { for (i = 1; i <= NF; i++) if ($i == "Gbits/sec") { s = $(i-1) + 0; break }
                  for (j = 1; j <= 2; j++) { ip = $j; r = rail[$1] == rail[$2] ? rail[ip] : "X"
                                             sum[host[ip], r] += s; cnt[host[ip], r]++; seen[host[ip]] = 1 } }
                END {
                    L["A"] = la; L["B"] = lb; L["X"] = la < lb ? la : lb; N[0] = "OK"; N[1] = "SLOW"; N[2] = "CRITICAL"
                    print "Host Avg_Gbps Rail_A Rail_B Cross Status"
                    for (h in seen) {
                        t = 0; m = 0; w = 0; ws = -1; o = ""
                        for (c = 1; c <= 3; c++) { r = substr("ABX", c, 1); v[r] = cnt[h,r] ? sum[h,r] / cnt[h,r] : -1
                            if (v[r] >= 0) { t += v[r]; m++; g = L[r] ? 100 * v[r] / L[r] : 0; lv = g >= ok ? 0 : (g >= slow ? 1 : 2)
                                             if (lv > w) w = lv; if (r != "X" && lv > ws) ws = lv }
                            o = o " " (v[r] < 0 ? "-" : sprintf("%.1f", v[r])) }
                        avg = t / m
                        st = (la == 0 || lb == 0) ? "-" : N[w] (ws >= 0 && w > ws ? "(cross)" : "")
                        if (v["A"] < 0 || v["B"] < 0) st = st "(1rail)"
                        printf "%s %.1f%s %s\n", h, avg, o, st
                    }
                }' "$map" - | { read -r hdr; echo "$hdr"; sort -k2 -n; } | column -t | sed 's/^/  /'
            cross_summary "$map" "$RESULTS"
            uplink_summary "$map" "$LLDP_DATA" "$NIC_DIAG" "$RESULTS"
        else
            if (( FS_SKIP_IPERF )); then
                echo "Bandwidth not tested (FS_SKIP_IPERF=1). Path checks (route, ping, MTU no-fragment): $(wc -l < "$WORK/paths_ok" | tr -d ' ') of $PATHS_PLANNED planned OK; the rest are in paths_excluded.txt."
            else echo "  No iperf3 results collected."; fi
        fi
        echo ""
        # receive side: flagged hosts only; every host's row is in host_rx.txt and on the dashboard
        local nrx nfl; nrx=$(( $(wc -l < "$COLLECT_DIR/host_rx.txt") - 1 )); nfl=$(awk 'NR > 1 && $NF != "-"' "$COLLECT_DIR/host_rx.txt" | wc -l | tr -d ' ')
        echo "Host-side receive: $nfl of $nrx hosts flagged (host_rx.txt; PCIe as GT/s x width, current/max; CPU: iperf3 process %, max over runs, and per thread (iperf3 3.16+: one thread per stream), flagged at 90):"
        (( nfl > 0 )) && awk 'NR == 1 || $NF != "-"' "$COLLECT_DIR/host_rx.txt" | column -t | sed 's/^/  /'
        echo ""
        echo "  Hosts on the rails: ${#ELIG[@]}, $( (( FS_SKIP_IPERF )) && echo "with a passed path check: $(awk 'NR==FNR {h[$1]=$2; next} {print h[$1]; print h[$2]}' "$WORK/ipmap" "$WORK/paths_ok" | sort -u | grep -c .)" || echo "with a result: $(grep 'Gbits/sec' "$RESULTS" | awk -F'[, ]+' 'NR==FNR {h[$1]=$2; next} {print h[$1]; print h[$2]}' "$WORK/ipmap" - | sort -u | grep -c .)") | Rails unusable: $(awk 'NR > 1 {n += ($6 != "ok") + ($10 != "ok")} END {print n + 0}' "$COLLECT_DIR/rails.txt") (rails.txt) | TCP paths skipped: $(awk '$2 ~ /^[12]$/' "$PATH_EXCL" | wc -l | tr -d ' ') (paths_excluded.txt)"
        echo "  Runs with no result: $(grep -c ',ERROR' "$RESULTS")"
        echo "  Directed NIC paths planned: ${#DIRECTED[@]} of $DIRECTED_TOTAL$( (( ${#DIRECTED[@]} < DIRECTED_TOTAL )) && echo " (all of them: FS_ITER=all)")"
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
                echo "  Lost datagrams ${r[0]} of ${r[1]}: receiver socket ${r[2]}, NIC ${r[3]}, kernel backlog ${r[4]}, unaccounted (likely fabric) ${r[5]}$( (( r[6] > 0 )) && echo "; host counters exceed the loss by ${r[6]} (they count all of the phase's traffic, not only these flows)")"
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
    if (( FS_SKIP_IPERF )); then   # no load: a path counts once its check passed
        hosts_tested=$(awk 'NR==FNR {h[$1]=$2; next} {print h[$1]; print h[$2]}' "$WORK/ipmap" "$WORK/paths_ok" | sort -u | grep -c .)
        paths_ok=$(wc -l < "$WORK/paths_ok" | tr -d ' ')
    else
        hosts_tested=$(grep 'Gbits/sec' "$RESULTS" | awk -F'[, ]+' 'NR==FNR {h[$1]=$2; next} {print h[$1]; print h[$2]}' "$WORK/ipmap" - | sort -u | grep -c .)
        paths_ok=$(grep -c 'Gbits/sec' "$RESULTS")
    fi
    skipped=$(awk '$2 ~ /^[12]$/' "$PATH_EXCL" | wc -l | tr -d ' ')
    noresult=$(grep -c ',ERROR' "$RESULTS")
    if (( paths_ok == 0 )); then coverage=NONE; cov_rc=4
    elif (( hosts_tested >= expect && paths_ok >= PATHS_PLANNED )); then coverage=COMPLETE; cov_rc=0
    else coverage=PARTIAL; cov_rc=3; fi
    local RESULT_LINE="RESULT coverage=$coverage hosts=$hosts_tested/$expect paths=$paths_ok/$PATHS_PLANNED skipped=$skipped no_result=$noresult"
    RESULT_LINE+=" cross_rail=$( (( CROSS_UNROUTED )) && echo unrouted || echo "$CROSS")"
    (( FS_SKIP_IPERF )) && RESULT_LINE+=" iperf=skipped (FS_SKIP_IPERF=1: paths = path checks passed, no bandwidth tested)"
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
        echo "line_rate_a_gbps=${LINE_A:-unknown}"
        echo "line_rate_b_gbps=${LINE_B:-unknown}"
        echo "ok_pct=$FS_OK_PCT"
        echo "slow_pct=$FS_SLOW_PCT"
        echo "spines=${FS_SPINES:-none}"
        echo "spine_links=${FS_SPINE_LINKS:-none}"
        echo "spine_gbps=${FS_SPINE_GBPS:-none}"
        echo "busy_hosts=${#BUSY[@]}"
        echo "port=$FS_PORT"
        echo "tos=${FS_TOS:-none}"
        echo "pairing=round-robin"
        echo "pairs_covered=$PAIRS_COVERED"
        echo "pairs_total=$PAIRS_TOTAL"
        echo "udp=$FS_UDP"
        echo "iperf=$( (( FS_SKIP_IPERF )) && echo skipped || echo run)"
        echo "udp_duration=$FS_UDP_DURATION"
        echo "coverage=$coverage"
        echo "hosts_expected=$expect"
        echo "hosts_tested=$hosts_tested"
        echo "paths_planned=$PATHS_PLANNED"
        echo "directed_paths=${#DIRECTED[@]}"
        echo "directed_paths_total=$DIRECTED_TOTAL"
        echo "cross_max=${FS_CROSS_MAX:-none}"
        echo "sysinfo_hosts=$( [[ -d $SI ]] && ls "$SI" | wc -l | tr -d " " || echo 0)"
        echo "cross_rail=$( (( CROSS_UNROUTED )) && echo unrouted || echo "$CROSS")"
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

    local tarball=$FS_OUT_DIR/fabric_sleuth_${LABEL}_${ts}.tgz
    stop_servers
    DONE=1; save_state
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
# tee ignores INT/TERM/HUP (Ctrl-C, group kill, dropped session) so cleanup can still write.
if [[ ${#BASH_SOURCE[@]} -eq 0 || ${BASH_SOURCE[0]} == "$0" ]]; then
    FS_RUNLOG=$(mktemp "${TMPDIR:-/tmp}/fs_runlog.XXXXXX") || exit 2
    STATE_FILE=$FS_RUNLOG.state
    trap ':' INT TERM HUP   # keep waiting for main's cleanup on Ctrl-C or a group kill (a no-op trap, so main gets its own)
    { main "$@" 2>&1 1>&3 3>&- | ( trap '' INT TERM HUP; exec tee -a "$FS_RUNLOG" >&2 3>&- ); rc=${PIPESTATUS[0]}; } 3>&1
    if [[ -s $STATE_FILE ]]; then   # main ended without finishing its cleanup: do it here, with main's state and exit code
        echo "# Run ended (rc=$rc) without its cleanup; finishing it now" | tee -a "$FS_RUNLOG" >&2
        ( source "$STATE_FILE"; (exit "$rc"); cleanup )
    fi
    rm -f "$FS_RUNLOG" "$STATE_FILE.tmp"
    exit "$rc"
fi
