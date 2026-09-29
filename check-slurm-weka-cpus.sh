#!/bin/bash
# check-slurm-weka-cpus.sh — verify Slurm CpuSpecList vs Weka core pinning on
# every DPDK/pinned POSIX client of issweka1, skipping the isv* VMs
# (ethernet/UDP mounts, not Slurm compute).
#
# One file, two modes. It replaces check-cpu-alldpdkclients.sh (fan-out) AND
# /admin/weka/scripts/check-cpuspeclist.sh (per-node collector): the fan-out
# ships THIS file to each host over ssh, so nothing depends on /admin.
#
# Fan-out — run from isvwmon01 as your own user (password SSH, one prompt):
#   ./check-slurm-weka-cpus.sh                     # auto-generate client list
#   ./check-slurm-weka-cpus.sh 16                  # parallelism 16 (default 64)
#   ./check-slurm-weka-cpus.sh clients.txt 16      # pre-generated list; any order
#   ./check-slurm-weka-cpus.sh --exclude skip.txt  # hosts to mark EXCLUDED
# The first target runs alone as a canary. A rejected password or a collector
# that stops early ends the run before the fleet (hundreds of parallel failed
# logins risk an AD lockout); an unreachable or hung canary moves on to the
# next host, three at most. isvwmon01 has no Slurm client, so the canary also
# runs ONE "scontrol show node -o"; when that works, every host it lists gets
# its spec line from it instead of calling scontrol itself.
#
# Re-run only the reporting pass over a results dir written by this script
# (no SSH):
#   ./check-slurm-weka-cpus.sh --summarize results-20260929-102618 [--exclude skip.txt]
#
# Per-node collector — run by hand on a compute node (needs dzdo):
#   ./check-slurm-weka-cpus.sh --local
# Prints the same human-readable sections as check-cpuspeclist.sh plus
# machine-readable "@@KEY=value" lines, "@@STEP=<name>" before each step and
# "@@DONE" at the end. Order: cgroup and fstab (plain file reads that cannot
# hang), lscpu, scontrol (the two steps a verdict needs), then weka and hwloc.
# Every external command runs under STEP_TIMEOUT (default 20s); a timed-out
# step prints "@@TIMEOUT=<step>" and the remaining steps still run. Only an
# lscpu or scontrol timeout blocks the verdict; weka and hwloc timeouts are
# noted and the host is still judged. HOST_TIMEOUT (fan-out, per host)
# defaults to 4 x (STEP_TIMEOUT + 5) + 30s so every step can expire first.
#
# Auto-generation runs locally on isvwmon01 (it's a Weka client):
#   dzdo weka cluster container -c --no-header -o hostname,cores
# (-c = client containers only; cores>0 = pinned/DPDK clients where this
#  check matters). isv* hosts are always filtered out regardless of source.
#
# Requires sshpass on isvwmon01 (EPEL: dnf install sshpass).
#
# Verdicts (ground truth = cgroup cpusets, OS CPU IDs; the slurm.conf string
# is judged against them). Background: Slurm's CpuSpecList takes Slurm
# *abstract* CPU IDs: core * ThreadsPerCore + thread, cores numbered socket by
# socket (slurm xcpuinfo.c), i.e. hwloc "PU L#"; slurmd reserves every thread
# of core (ID / ThreadsPerCore). At 1 thread/core that is hwloc "Core L#".
# On interleaved-NUMA boxes (socket0 = even OS IDs, socket1 = odd) L# != P#,
# and a slurmd restart can flip a working OS-ID string into a logical-ID
# interpretation (iscg001/008). Not handled: a node whose slurm.conf CPUs=
# equals its core count, where Slurm reads the list as core IDs.
# MSK runs TaskPluginParam=SlurmdOffSpec, so the slurm/system cgroup holds the
# JOB-allowed CPUs, i.e. the complement of the reservation
# (|all - system| == CoreSpecCount x ThreadsPerCore).
#   PASS           weka-client and slurm/system cpusets disjoint AND the
#                  configured CpuSpecList == recommended logical IDs
#   AT-RISK        disjoint today, but the string != recommendation — works only
#                  because of how the running slurmd resolved it (or a stale
#                  reservation); will break on the next slurmd restart
#   FAIL           cpusets overlap — Slurm schedules jobs onto Weka FE cores
#   LAYOUT?        |all - slurm_system| != CoreSpecCount x ThreadsPerCore and the
#                  excluded set is not the Weka set either — cgroup semantics
#                  unclear, verify (or SMT with no P#->L# map)
#   NOSPEC         slurm cgroup present but scontrol shows no CPUSpecList
#   NOSLURM        no slurm/system cgroup (login/xfer/non-Slurm hosts)
#   WEKA-UNPINNED  FE resources <auto>, or fstab core= set != weka cgroup —
#                  a WEKA-side problem; do NOT change Slurm for these
#   WEKA-EMPTY     weka-client cgroup exists but is empty
#   NOWEKA         no weka-client cgroup (UDP-mode / unpinned client)
#   EXCLUDED       listed in --exclude FILE (verdict still shown in NOTE)
#   HUNG(<step>)   host stopped before its scontrol step finished, or its
#                  lscpu/scontrol step timed out — step named; cgroup-based
#                  verdict in NOTE when the cgroup step did complete
#   UNREACHABLE    ssh transport failed (exit 255) or no output at all
#   INCOMPLETE     per-host file empty, host never attempted, or the file was
#                  not written by this collector (no @@FORMAT line)
# NOTE also carries "reads-as": how the running slurmd resolved the string
# (os-ids | logical-ids | both = sequential layout | neither/stale).
#
# A non-zero remote exit is NOT treated as failure (missing hwloc-ls, absent
# slurm cgroup etc. exit non-zero with perfectly usable output).
#
# Testing hooks (never set in production): CSWC_CGROUP_ROOT, CSWC_FSTAB,
# CSWC_SYSNET override /sys/fs/cgroup, /etc/fstab, /sys/class/net in --local.
# The fan-out itself sets CSWC_FLEET_SPEC (canary) and CSWC_SPEC (the rest).
#
# Portable to RHEL bash 4/5 + GNU tools and macOS bash 3.2 + BSD tools.

set -u

_CR=$'\r'; _NL=$'\n'; _WS=$'\r\t '

# ---- portability shims ----------------------------------------------------

# timeout(1) stand-in when coreutils is missing (perl exists on RHEL and macOS)
perl_timeout() {
    perl -e '$t=shift; $p=fork; if(!$p){exec @ARGV or exit 127}
             $SIG{ALRM}=sub{kill "TERM",$p; sleep 2; kill "KILL",$p; exit 124};
             alarm $t; waitpid $p,0; exit($?>>8)' "$@"
}
if command -v timeout >/dev/null 2>&1; then TMO_CMD="timeout -k 5"; else TMO_CMD=perl_timeout; fi

# ---- cpulist helpers (fork-free) -------------------------------------------
# Lists are "0-55,57,59" style; ranges may carry a stride ("0-62:2"), CR and
# blanks are tolerated, non-numeric items ("<auto>") are ignored. A set is a
# sparse indexed array whose indices iterate in ascending order, so it is
# sorted and unique for free. Results come back in R ("norm" list "a,b,c", a
# count, or a map string), never through $(...), so judging a host forks
# nothing.

_parse() {  # $1 cpulist -> _S (set: _S[cpu]=1)
    local IFS=",$_WS" item lo hi st i
    _S=()
    set -f
    for item in $1; do
        case "$item" in
            *-*:*) lo=${item%%-*}; hi=${item#*-}; st=${hi#*:}; hi=${hi%%:*} ;;
            *-*)   lo=${item%%-*}; hi=${item#*-}; st=1 ;;
            *)     lo=$item; hi=$item; st=1 ;;
        esac
        case "$lo:$hi:$st" in *[!0-9:]*|:*|*::*|*:) continue ;; esac
        [ "$((10#$st))" -gt 0 ] || st=1
        for ((i=10#$lo; i<=10#$hi; i+=10#$st)); do _S[i]=1; done
    done
    set +f
}

_join() {  # _S -> R "a,b,c"
    local IFS=,
    R="${!_S[*]}"
}

norm() {  # $1 cpulist -> R "a,b,c" sorted unique ("" if empty)
    _parse "$1"; _join
}

count() {  # $1 cpulist -> R number of cpus
    _parse "$1"; R=${#_S[@]}
}

compress() {  # $1 cpulist -> R ranged "0-55,57,59,61,63"
    local out="" s="" p="" c
    _parse "$1"
    for c in ${!_S[@]}; do
        if [ -n "$p" ] && (( c == p + 1 )); then p=$c; continue; fi
        if [ -n "$s" ]; then
            if [ "$s" = "$p" ]; then out="$out${out:+,}$s"; else out="$out${out:+,}$s-$p"; fi
        fi
        s=$c; p=$c
    done
    if [ -n "$s" ]; then
        if [ "$s" = "$p" ]; then out="$out${out:+,}$s"; else out="$out${out:+,}$s-$p"; fi
    fi
    R=$out
}

set_diff() {  # $1 - $2 -> R norm list
    local c out=""; local -a b=()
    _parse "$2"; for c in ${!_S[@]}; do b[c]=1; done
    _parse "$1"
    for c in ${!_S[@]}; do [ -n "${b[c]:-}" ] || out="$out${out:+,}$c"; done
    R=$out
}

set_inter() {  # $1 ∩ $2 -> R norm list
    local c out=""; local -a b=()
    _parse "$2"; for c in ${!_S[@]}; do b[c]=1; done
    _parse "$1"
    for c in ${!_S[@]}; do [ -n "${b[c]:-}" ] && out="$out${out:+,}$c"; done
    R=$out
}

abs_to_cores() {  # $1 Slurm abstract CPU IDs, $2 threads/core -> R core IDs
    local IFS=' ' ids c
    _parse "$1"; ids="${!_S[*]}"; _S=()
    for c in $ids; do _S[c / $2]=1; done
    _join
}

cores_to_abs() {  # $1 core IDs, $2 threads/core -> R abstract IDs of every thread
    local IFS=' ' ids c i
    _parse "$1"; ids="${!_S[*]}"; _S=()
    for c in $ids; do for ((i=0; i<$2; i++)); do _S[c * $2 + i]=1; done; done
    _join
}

# Maps are "key:val key:val ..." strings (P#:L#). A key may map to several
# values (SMT inverse map: one Core L# -> two PUs).
map_fwd() {  # $1 map, $2 cpulist -> R mapped values (norm); rc=1 if any key unmapped
    local IFS=' ' kv k v c ids miss=0; local -a m=()
    set -f
    for kv in $1; do
        case "$kv" in *[!0-9:]*|:*|*:|*:*:*) continue ;; esac
        k=$((10#${kv%%:*})); m[k]="${m[k]:-} $((10#${kv#*:}))"
    done
    set +f
    _parse "$2"; ids="${!_S[*]}"; _S=()
    for c in $ids; do
        if [ -n "${m[c]:-}" ]; then for v in ${m[c]}; do _S[v]=1; done; else miss=1; fi
    done
    _join
    return $miss
}

map_inv() {  # $1 "p:l ..." -> R "l:p ..."
    local IFS=' ' kv out=""
    set -f
    for kv in $1; do case "$kv" in *:*) out="$out${out:+ }${kv#*:}:${kv%%:*}" ;; esac; done
    set +f
    R=$out
}

map_conflict() {  # $1 map A, $2 map B -> R first "k:v" of A that B maps differently ("" if none)
    local IFS=' ' kv k; local -a b=()
    R=""
    set -f
    for kv in $2; do
        case "$kv" in *[!0-9:]*|:*|*:|*:*:*) continue ;; esac
        b[10#${kv%%:*}]=${kv#*:}
    done
    for kv in $1; do
        case "$kv" in *[!0-9:]*|:*|*:|*:*:*) continue ;; esac
        k=$((10#${kv%%:*}))
        if [ -n "${b[k]:-}" ] && [ "${b[k]}" != "${kv#*:}" ]; then R=$kv; break; fi
    done
    set +f
}

# numa_map — P#->L# map derived from NUMA node order (hwloc numbers cores
# depth-first: node0's CPUs get L#0.., then node1's ...). Only meaningful for
# 1 thread/core; used when hwloc-ls was missing or did not cover a CPU.
numa_map() {  # $1 "n:list;n:list" -> R "p:l p:l ..."
    local rest="$1;" ent n out="" l=0 c; local -a node=()
    while [ -n "$rest" ]; do
        ent=${rest%%;*}; rest=${rest#*;}
        case "$ent" in *:*) ;; *) continue ;; esac
        n=${ent%%:*}
        case "$n" in ''|*[!0-9]*) continue ;; esac
        node[10#$n]=${ent#*:}
    done
    for n in ${!node[@]}; do
        _parse "${node[n]}"
        for c in ${!_S[@]}; do out="$out${out:+ }$c:$l"; l=$((l + 1)); done
    done
    R=$out
}

# ---- --local: per-node collector ------------------------------------------

STEP_TIMEOUT="${STEP_TIMEOUT:-20}"
STEP_OUT=""

# tstep NAME CMD... — run CMD under STEP_TIMEOUT with stdout in $STEP_OUT
# (file); on expiry print the @@TIMEOUT marker and return 1 so the caller
# carries on with the next step.
tstep() {
    local name="$1" rc; shift
    $TMO_CMD "$STEP_TIMEOUT" "$@" >"$STEP_OUT" </dev/null
    rc=$?
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        echo "@@TIMEOUT=$name"
        return 1
    fi
    return 0
}

# cgroup key: "PRESENT:<list>" (list may be empty) or "ABSENT"
cg_key() {  # $1 path
    if [ -e "$1" ]; then echo "PRESENT:$(tr -d '[:space:]' <"$1" 2>/dev/null)"; else echo ABSENT; fi
}

local_mode() {
    local CG="${CSWC_CGROUP_ROOT:-/sys/fs/cgroup}"
    local FSTAB="${CSWC_FSTAB:-/etc/fstab}"
    local SYSNET="${CSWC_SYSNET:-/sys/class/net}"
    local tpc numa_all fe ibs ib c cores hwmap specline v1s v1w v2s v2w cgver probed s w p line n v pat
    STEP_OUT=$(mktemp "${TMPDIR:-/tmp}/cswc.XXXXXX")
    [ -n "$STEP_OUT" ] || { echo "@@ERROR=mktemp failed"; exit 1; }
    trap '[ -n "$STEP_OUT" ] && rm -f -- "$STEP_OUT"' EXIT

    echo "@@FORMAT=2"
    echo "@@HOST=$(hostname -s)"
    echo "@@STEP_TIMEOUT=$STEP_TIMEOUT"

    # -- cgroups first: sysfs reads that cannot hang. v1 paths as in Seth's
    #    script; v2 = Slurm's <slurmstepd scope>/system (cgroup_v2.c) and
    #    Weka's /weka-client (wcgroup_v2.d), probed when v1 is missing --
    echo "@@STEP=cgroup"
    v1s="$CG/cpuset/slurm/system/cpuset.effective_cpus"
    v1w="$CG/cpuset/weka-client/cpuset.effective_cpus"
    v2s="$CG/system.slice/slurmstepd.scope/system/cpuset.cpus.effective"
    for p in "$CG"/system.slice/*slurmstepd.scope/system/cpuset.cpus.effective; do
        [ -e "$p" ] && { v2s=$p; break; }
    done
    v2w="$CG/weka-client/cpuset.cpus.effective"
    probed=""
    if [ -e "$v1s" ] || [ -e "$v1w" ]; then
        cgver=v1; s=$v1s; w=$v1w
    elif [ -e "$v2s" ] || [ -e "$v2w" ]; then
        cgver=v2; s=$v2s; w=$v2w; probed="$v1s $v1w"
    else
        cgver=none; s=$v1s; w=$v1w; probed="$v1s $v1w $v2s $v2w"
    fi
    echo "Weka & Slurm cgroup effective cpusets:"
    grep "" "$s" "$w" 2>&1
    echo "--"
    echo "@@CG_SLURM_SYSTEM=$(cg_key "$s")"
    echo "@@CG_WEKA=$(cg_key "$w")"
    echo "@@CG_VERSION=$cgver"
    echo "@@CG_PROBED=$probed"

    # -- fstab --
    echo "@@STEP=fstab"
    echo "adminfs as specified in /etc/fstab:"
    grep adminfs "$FSTAB" 2>/dev/null
    echo "--"
    # core= from the NON-commented adminfs line(s) only
    cores=$(grep adminfs "$FSTAB" 2>/dev/null | grep -v '^[[:space:]]*#' | grep -o 'core=[0-9]*' | cut -d= -f2 | paste -sd, -)
    echo "@@FSTAB_CORES=$cores"

    # -- lscpu --
    echo "@@STEP=lscpu"
    echo
    echo "lscpu selected output:"
    tstep lscpu lscpu
    grep -E 'Thread|NUMA' "$STEP_OUT"
    echo "--"
    tpc=$(sed -n 's/^Thread(s) per core:[[:space:]]*//p' "$STEP_OUT" | head -1)
    echo "@@THREADS_PER_CORE=$tpc"
    numa_all=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        n=${line#NUMA node}; n=${n%% *}
        v=${line#*:}; v=${v//[$_WS]/}
        echo "@@NUMA_NODE=$n:$v"
        numa_all="${numa_all:+$numa_all,}$v"
    done <<EOF
$(grep -E '^NUMA node[0-9]+ CPU\(s\):' "$STEP_OUT")
EOF
    compress "$numa_all"
    echo "@@NUMA_CPUS=$R"

    # -- scontrol: the spec string; a verdict needs it, so it runs before weka
    #    and hwloc. CSWC_SPEC (set, possibly empty) = the fan-out already has
    #    this node's line from the canary's one fleet-wide scontrol. --
    echo "@@STEP=scontrol"
    if [ -n "${CSWC_SPEC+x}" ]; then
        specline=$CSWC_SPEC
        echo "@@SPEC_SOURCE=canary"
    else
        if tstep scontrol scontrol show node "$(hostname -s)"; then :; fi
        specline=$(grep CPUSpec "$STEP_OUT" | head -1 | sed 's/^[[:space:]]*//')
        echo "@@SPEC_SOURCE=local"
    fi
    echo "Slurm CPUSpecList setting in effect: $specline"
    echo "--"
    echo "@@SLURM_SPEC=$specline"

    # -- weka: ONE call to dzdo weka local resources, reused below --
    echo "@@STEP=weka"
    if tstep weka dzdo weka local resources; then :; fi
    ibs=$(grep ib "$STEP_OUT" | awk '{print $1}')
    fe=$(grep FRONT "$STEP_OUT" | awk '{print $3}' | paste -s -d',' -)
    for ib in $ibs; do
        echo "${ib} NUMA-local CPUs: $(cat "$SYSNET/${ib}/device/local_cpulist" 2>/dev/null)"
    done
    echo "--"
    echo "Weka resources frontend CPUs: $fe"
    echo "--"
    echo "@@WEKA_NETDEVS=$(printf '%s\n' "$ibs" | paste -sd, -)"
    echo "@@WEKA_FE_CPUS=$fe"

    # -- hwloc: ONE hwloc-ls run; show the FE rows like Seth's script (one
    #    grep), then emit the full P#->Core L# map (single-line and SMT
    #    multi-line layouts) --
    echo "@@STEP=hwloc"
    echo "Weka frontend CPUs selected from hwloc-ls:"
    if tstep hwloc hwloc-ls; then :; fi
    _parse "$fe"; pat=""
    for c in ${!_S[@]}; do pat="$pat${pat:+|}$c"; done
    [ -n "$pat" ] && grep -E "P#($pat)\)" "$STEP_OUT"
    echo "--"
    hwmap=$(awk '
        /Core L#[0-9]+/ {
            match($0, /Core L#[0-9]+/); core=substr($0, RSTART+7, RLENGTH-7)
            if (match($0, /P#[0-9]+/)) print substr($0, RSTART+2, RLENGTH-2) ":" core
            next
        }
        core!="" && /PU L#[0-9]+ \(P#[0-9]+\)/ {
            match($0, /P#[0-9]+/); print substr($0, RSTART+2, RLENGTH-2) ":" core
        }' "$STEP_OUT" | sort -t: -k1,1n | paste -sd' ' -)
    echo "@@HWLOC_MAP=$hwmap"

    # -- canary only: every node's spec line from ONE scontrol call, in the
    #    same "CoreSpecCount=.. CPUSpecList=.. MemSpecLimit=.." form as above
    #    ("" for a node with no CPUSpecList) --
    if [ -n "${CSWC_FLEET_SPEC:-}" ]; then
        echo "@@STEP=fleetspec"
        if tstep fleetspec scontrol show node -o; then
            awk '{
                n=""; s=""
                for (i=1; i<=NF; i++) {
                    if ($i ~ /^NodeName=/) n=substr($i, 10)
                    else if ($i ~ /^(CoreSpecCount|CPUSpecList|MemSpecLimit)=/) s=s (s==""?"":" ") $i
                }
                if (s !~ /CPUSpecList=/) s=""
                if (n != "") print "@@FLEET_NODE=" n "|" s
            }' "$STEP_OUT"
        fi
    fi
    echo "@@DONE"
}

# ---- per-host file -> K_<KEY> shell vars -------------------------------------

load_keys() {  # $1 file -> K_<KEY> for each @@KEY=value; NUMA_NODE/STEP/TIMEOUT accumulate
    local line k v
    unset "${!K_@}"
    K_NUMA_NODES=""; K_STEPS=""; K_TIMEOUTS=""; K_DONE=""; K_FORMAT=""
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%"$_CR"}
        case "$line" in
            @@DONE|@@DONE[[:space:]]*) K_DONE=yes ;;
            @@FLEET_NODE=*) ;;
            @@?*=*)
                k=${line%%=*}; k=${k#@@}; v=${line#*=}
                case "$k" in *[![:upper:][:digit:]_]*) continue ;; esac
                case "$k" in
                    NUMA_NODE) K_NUMA_NODES="${K_NUMA_NODES:+$K_NUMA_NODES;}$v" ;;
                    STEP)      K_STEPS="${K_STEPS:+$K_STEPS,}$v" ;;
                    TIMEOUT)   K_TIMEOUTS="${K_TIMEOUTS:+$K_TIMEOUTS,}$v" ;;
                    *)         eval "K_$k=\$v" ;;
                esac ;;
        esac
    done <"$1"
}

# ---- verdict for one host ----------------------------------------------------
# Inputs: host name + per-host file (+ suffix). Appends rows to the summary
# and to the remediation / unpinned / hung tables.

judge_host() {
    local h="$1" f="$2" status="" note="" hung_step="" errf
    local tpc all fe fstab hwmap spec cgw cgs weka slurm cgw_state cgs_state
    local curlist csc excluded overlap rec recsrc nmap lmap pofl reads_as expect_after
    local fstab_ok n_exc n_cur wcores scores wfull cscn last b tok fe_auto cw cf

    # -- empty file: the host was never really collected --
    if [ ! -s "$f" ]; then
        case "$f" in
            *.hung)        status="HUNG(ssh)";   note="no output within HOST_TIMEOUT" ;;
            *.unreachable) status="UNREACHABLE"; errf="${f%.unreachable}.err"
                           [ -r "$errf" ] && IFS= read -r note <"$errf" ;;
            *)             status="INCOMPLETE";  note="never collected (run interrupted?)" ;;
        esac
        emit_row "$h" "$status" "-" "-" "$note"
        [ "$status" = "HUNG(ssh)" ] && printf '%-28s %-12s %s\n' "$h" "ssh" "no output" >>"$HUNGT"
        return
    fi

    load_keys "$f"
    if [ -z "$K_FORMAT" ]; then
        emit_row "$h" INCOMPLETE "-" "-" "no @@FORMAT line: not written by this collector (legacy check-cpuspeclist.sh output is no longer read)"
        return
    fi
    case "$f" in
        *.unreachable) note="recovered from .unreachable (remote rc<>0)" ;;
    esac

    tpc=${K_THREADS_PER_CORE:-}
    case "$tpc" in ''|*[!0-9]*|0) tpc=1 ;; esac
    norm "${K_NUMA_CPUS:-}"; all=$R
    fe=${K_WEKA_FE_CPUS:-}
    norm "${K_FSTAB_CORES:-}"; fstab=$R
    hwmap=${K_HWLOC_MAP:-}
    spec=${K_SLURM_SPEC:-}
    cgw=${K_CG_WEKA:-}; cgs=${K_CG_SLURM_SYSTEM:-}

    weka=""; cgw_state=ABSENT
    case "$cgw" in PRESENT:*)
        norm "${cgw#PRESENT:}"; weka=$R
        if [ -n "$weka" ]; then cgw_state=OK; else cgw_state=EMPTY; fi ;;
    esac
    slurm=""; cgs_state=ABSENT
    case "$cgs" in PRESENT:*)
        norm "${cgs#PRESENT:}"; slurm=$R
        if [ -n "$slurm" ]; then cgs_state=OK; else cgs_state=EMPTY; fi ;;
    esac

    # -- did the collector get what the verdict needs? Only lscpu (the CPU
    #    universe) and scontrol (the spec string) block; weka and hwloc are
    #    noted. A step is complete once a later @@STEP follows it. --
    last=${K_STEPS##*,}
    for b in lscpu scontrol; do
        case ",$K_TIMEOUTS," in *",$b,"*) hung_step=${hung_step:-$b} ;; esac
        [ -n "$K_DONE" ] && continue
        case ",$K_STEPS," in
            *",$b,"*) [ "$b" = "$last" ] && hung_step=${hung_step:-$b} ;;
            *)        hung_step=${hung_step:-${last:-ssh}} ;;
        esac
    done
    [ -n "$K_DONE" ] || note="${note:+$note; }no @@DONE (stopped in step ${last:-ssh})"
    [ -n "$K_TIMEOUTS" ] && note="${note:+$note; }step(s) timed out after ${K_STEP_TIMEOUT:-?}s: $K_TIMEOUTS"

    # -- cgroup-only verdict (used for HUNG notes) --
    overlap=""
    if [ "$cgw_state" = OK ] && [ "$cgs_state" = OK ]; then
        set_inter "$weka" "$slurm"; overlap=$R
    fi

    if [ -n "$hung_step" ]; then
        status="HUNG($hung_step)"
        local cgv="cgroups not collected"
        if [ "$cgw_state" = OK ] && [ "$cgs_state" = OK ]; then
            if [ -n "$overlap" ]; then
                compress "$overlap"; cgv="cgroups OVERLAP $R (FAIL today)"
            else
                cgv="cgroups disjoint (no overlap today)"
            fi
        elif [ "$cgw_state" != ABSENT ] || [ "$cgs_state" != ABSENT ]; then
            cgv="cgroups: weka=$cgw_state slurm=$cgs_state"
        fi
        note="${note:+$note; }$cgv"
        printf '%-28s %-12s %s\n' "$h" "$hung_step" "$cgv" >>"$HUNGT"
        emit_row "$h" "$status" "${weka:--}" "${slurm:--}" "$note"
        return
    fi

    # -- L# map: hwloc first, NUMA-derived fill-in (1 thread/core only) --
    nmap=""
    if [ "$tpc" = 1 ] && [ -n "$K_NUMA_NODES" ]; then
        numa_map "$K_NUMA_NODES"; nmap=$R
        if [ -n "$hwmap" ] && [ -n "$nmap" ]; then
            # the two must agree wherever hwloc has an entry
            map_conflict "$hwmap" "$nmap"
            if [ -n "$R" ]; then note="${note:+$note; }hwloc/NUMA L# maps disagree at P#${R%%:*} — NUMA map not used"; nmap=""; fi
        fi
    fi
    lmap="$hwmap${nmap:+ $nmap}"   # union; safe, disagreeing maps were dropped above

    # -- recommendation: every thread of the weka cgroup's cores, as Slurm
    #    abstract IDs (Core L# x tpc + thread; = Core L# at 1 thread/core) --
    rec=""; recsrc=""; wcores=""
    if [ -n "$weka" ]; then
        if [ -n "$hwmap" ] && map_fwd "$hwmap" "$weka"; then
            wcores=$R; recsrc=hwloc
        elif [ -n "$nmap" ] && map_fwd "$nmap" "$weka"; then
            wcores=$R; recsrc=numa-derived
        fi
        if [ -n "$wcores" ]; then cores_to_abs "$wcores" "$tpc"; rec=$R; fi
    fi

    # -- Slurm spec fields (any order / spacing; first occurrence wins) --
    curlist=""; csc=""
    set -f
    for tok in $spec; do
        case "$tok" in
            CPUSpecList=*)   [ -n "$curlist" ] || curlist=${tok#*=} ;;
            CoreSpecCount=*) [ -n "$csc" ] || csc=${tok#*=} ;;
        esac
    done
    set +f
    case "$csc" in *[!0-9]*) csc="" ;; esac
    norm "$curlist"; curlist=$R
    scores=""; if [ -n "$curlist" ]; then abs_to_cores "$curlist" "$tpc"; scores=$R; fi   # cores slurmd reserves
    cscn="CoreSpecCount=$csc"; [ "$tpc" = 1 ] || cscn="$cscn x $tpc threads"

    excluded=""; reads_as=""
    if [ "$cgs_state" = OK ] && [ -n "$all" ]; then
        set_diff "$all" "$slurm"; excluded=$R
    fi
    if [ -n "$excluded" ] && [ -n "$curlist" ]; then
        # how did the running slurmd resolve the string? It reserves whole
        # cores; read as os IDs (linear map) or logical IDs (hwloc/NUMA map)?
        local os_eq=no lg_eq=no lg_part=no sfull
        cores_to_abs "$scores" "$tpc"; sfull=$R
        [ "$excluded" = "$sfull" ] && os_eq=yes
        map_inv "$lmap"
        if map_fwd "$R" "$scores"; then
            pofl=$R
            [ -n "$pofl" ] && [ "$excluded" = "$pofl" ] && lg_eq=yes
        else
            # partial map: every mapped P# must be excluded and the counts match
            pofl=$R
            count "$excluded"; n_exc=$R; count "$sfull"; n_cur=$R
            if [ -n "$pofl" ] && [ "$n_exc" = "$n_cur" ]; then
                set_diff "$pofl" "$excluded"; [ -z "$R" ] && lg_part=yes
            fi
        fi
        if [ $os_eq = yes ] && [ $lg_eq = yes ]; then reads_as="both (sequential)"
        elif [ $os_eq = yes ]; then reads_as="os-ids"
        elif [ $lg_eq = yes ]; then reads_as="logical-ids"
        elif [ $lg_part = yes ]; then reads_as="logical-ids (partial map)"
        elif [ -z "$lmap" ]; then reads_as="unknown (no L# map)"
        else reads_as="neither/stale"; fi
    fi

    # -- fstab vs cgroup (SMT: cgroup carries sibling threads, compare cores) --
    fstab_ok=yes
    if [ -n "$fstab" ] && [ -n "$weka" ] && [ "$fstab" != "$weka" ]; then
        fstab_ok=no
        if [ "$tpc" != 1 ] && set_diff "$fstab" "$weka" && [ -z "$R" ]; then
            if [ -n "$hwmap" ]; then
                local fl="" wl=""
                map_fwd "$hwmap" "$fstab" && fl=$R
                map_fwd "$hwmap" "$weka" && wl=$R
                if [ -n "$fl" ] && [ "$fl" = "$wl" ]; then
                    fstab_ok=yes; note="${note:+$note; }SMT: cgroup includes sibling threads of fstab cores"
                fi
            else
                fstab_ok=yes; note="${note:+$note; }SMT: cgroup ⊇ fstab cores (siblings unverified, no hwloc)"
            fi
        fi
    fi

    case ",$K_TIMEOUTS," in *,weka,*) note="${note:+$note; }weka local resources timed out: FE <auto> pinning not checked" ;; esac

    fe_auto=no; case "$fe" in *auto*) fe_auto=yes ;; esac
    cw=""; [ -n "$weka" ] && { compress "$weka"; cw=$R; }
    cf=""; [ -n "$fstab" ] && { compress "$fstab"; cf=$R; }

    # -- verdict chain, in precedence order --
    if [ "$cgw_state" = ABSENT ]; then
        status=NOWEKA
    elif [ "$cgw_state" = EMPTY ]; then
        status=WEKA-EMPTY
    elif [ $fe_auto = yes ]; then
        status=WEKA-UNPINNED
        note="${note:+$note; }FE resources <auto>, cgroup has $cw${cf:+, fstab asks core=$cf}"
        printf '%-28s %-22s %-18s %s\n' "$h" "$fe" "$cf" "$cw" >>"$UNPINT"
    elif [ $fstab_ok = no ]; then
        status=WEKA-UNPINNED
        note="${note:+$note; }fstab asks core=$cf but cgroup has $cw (FE=${fe:-none returned by weka local resources})"
        compress "$fe"
        printf '%-28s %-22s %-18s %s\n' "$h" "$R" "$cf" "$cw" >>"$UNPINT"
    elif [ "$cgs_state" = ABSENT ]; then
        status=NOSLURM
    elif [ -z "$curlist" ]; then
        status=NOSPEC
        compress "$slurm"
        note="${note:+$note; }slurm cgroup $R but scontrol shows no CPUSpecList${spec:+ ($spec)}"
    else
        count "$excluded"; n_exc=$R
        if [ -n "$all" ] && [ -n "$csc" ] && [ "$n_exc" != "$(( csc * tpc ))" ] && [ "$excluded" != "$weka" ]; then
            status="LAYOUT?"
            compress "$excluded"
            note="${note:+$note; }|all-slurm_system|=$n_exc != $cscn and excluded ($R) != weka set — cgroup semantics unclear"
            [ -n "$overlap" ] && { compress "$overlap"; note="$note; overlap $R"; }
        elif [ -z "$rec" ]; then
            status="LAYOUT?"
            note="${note:+$note; }no P#->L# map (SMT + no hwloc-ls): "
            [ -n "$overlap" ] && { compress "$overlap"; note="${note}overlap $R; "; }
            note="${note}CpuSpecList semantics unverifiable — derive manually"
        elif [ -n "$overlap" ]; then
            status=FAIL
            compress "$overlap"
            note="${note:+$note; }overlap $R"
        elif [ "$scores" != "$wcores" ]; then
            status=AT-RISK
            note="${note:+$note; }string $curlist != rec $rec"
            if [ -n "$csc" ] && [ "$n_exc" != "$(( csc * tpc ))" ]; then
                note="$note; stale reservation: cgroup excludes exactly the $n_exc weka CPUs while scontrol says $cscn"
            fi
        else
            status=PASS
        fi
        [ -n "$reads_as" ] && note="${note:+$note; }reads-as: $reads_as"
        [ "$recsrc" = numa-derived ] && note="${note:+$note; }L# map NUMA-derived (no usable hwloc-ls output)"

        if [ "$status" = FAIL ] || [ "$status" = AT-RISK ]; then
            # CpuSpecList only: Slurm errors when a node sets CoreSpecCount too;
            # scontrol derives CoreSpecCount from the list.
            local should nwc
            should="CpuSpecList=$rec"
            count "$wcores"; nwc=$R
            [ -n "$csc" ] && [ "$csc" != "$nwc" ] && note="$note; scontrol CoreSpecCount should then read $nwc (now $csc)"
            # slurmd reserves whole cores: every thread of the weka cores leaves slurm/system
            map_inv "$lmap"
            if map_fwd "$R" "$wcores"; then wfull=$R; else wfull=$weka; fi
            if [ -n "$all" ]; then set_diff "$all" "$wfull"; compress "$R"; expect_after=$R; else expect_after="?"; fi
            printf '%-28s %-14s %-66s %-48s %s\n' "$h" "$cw" "$spec" "$should" "$expect_after" >>"$REMED"
        fi
    fi

    # -- --exclude: verdict computed, but reported as EXCLUDED --
    if is_excluded "$h"; then
        note="excluded (would be $status)${note:+; $note}"
        status=EXCLUDED
        # drop any remediation/unpinned row we just wrote for this host
        for t in "$REMED" "$UNPINT"; do
            [ -s "$t" ] && { grep -v "^$h " "$t" >"$t.tmp"; mv -f "$t.tmp" "$t"; }
        done
    fi

    emit_row "$h" "$status" "${weka:--}" "${slurm:--}" "$note"
}

emit_row() {  # host status weka slurm note  (cpusets shown range-compressed)
    local w="$3" s="$4"
    [ "$w" = "-" ] || { compress "$w"; w=$R; }
    [ "$s" = "-" ] || { compress "$s"; s=$R; }
    printf '%-26s %-14s %-16s %-30s %s\n' "$1" "$2" "$w" "$s" "$5" >>"$SUMMARY"
    SEEN="$SEEN$1$_NL"
}

is_excluded() {  # $1 host (short or FQDN)
    [ -n "$EXCL" ] || return 1
    local s="${1%%.*}" rc=1
    shopt -s nocasematch
    case "$_NL$EXCL$_NL" in *"$_NL$s$_NL"*) rc=0 ;; esac
    shopt -u nocasematch
    return $rc
}

load_exclude() {  # $1 file -> EXCL (short names, lowercase, one per line)
    EXCL=$(grep -Ev '^[[:space:]]*(#|$)' "$1" | tr -d '\r' | awk '{print $1}' | sed 's/\..*//' | tr 'A-Z' 'a-z' | sort -u)
}

# ---- summary / report ---------------------------------------------------------

summarize() {
    SUMMARY="$OUTDIR/summary.txt"; REMED="$OUTDIR/remediation.txt"
    UNPINT="$OUTDIR/unpinned.txt"; HUNGT="$OUTDIR/hung.txt"
    : >"$SUMMARY"; : >"$REMED"; : >"$UNPINT"; : >"$HUNGT"
    SEEN=""

    # exclude list recorded by the collecting run, unless overridden now
    [ -n "$EXCL" ] || { [ -r "$OUTDIR/exclude.txt" ] && load_exclude "$OUTDIR/exclude.txt"; }

    local f h
    for f in "$OUTDIR"/*.txt "$OUTDIR"/*.unreachable "$OUTDIR"/*.hung; do
        [ -e "$f" ] || continue
        h=${f##*/}
        case "$h" in
            targets.txt|summary.txt|remediation.txt|unpinned.txt|hung.txt|report.txt|exclude.txt|fleet-spec.txt) continue ;;
        esac
        h="${h%.txt}"; h="${h%.unreachable}"; h="${h%.hung}"
        judge_host "$h" "$f"
    done

    # Hosts in targets.txt with no file at all (run killed before ssh started).
    if [ -s "$OUTDIR/targets.txt" ]; then
        while IFS= read -r h; do
            [ -n "$h" ] || continue
            case "$_NL$SEEN" in *"$_NL$h$_NL"*) continue ;; esac
            emit_row "$h" INCOMPLETE "-" "-" "not attempted (run interrupted)"
        done <"$OUTDIR/targets.txt"
    fi

    REPORT="$OUTDIR/report.txt"
    {
        printf '%-26s %-14s %-16s %-30s %s\n' HOST STATUS WEKA_CPUSET SLURM_SYSTEM_CPUSET NOTE
        sort -k2,2 -k1,1 "$SUMMARY"
        echo
        awk '{s=$2; sub(/\(.*/, "", s); n[s]++; t++} END {
            split("PASS AT-RISK FAIL LAYOUT? NOSPEC NOSLURM WEKA-UNPINNED WEKA-EMPTY NOWEKA EXCLUDED HUNG UNREACHABLE INCOMPLETE", o, " ")
            for (i=1; i<=13; i++) if (o[i] in n) printf "%s=%d ", o[i], n[o[i]]
            printf "TOTAL=%d\n", t }' "$SUMMARY"
        if [ -s "$REMED" ]; then
            echo
            echo "REMEDIATION — slurm.conf CpuSpecList changes needed (FAIL + AT-RISK; MemSpecLimit unchanged):"
            printf '%-28s %-14s %-66s %-48s %s\n' HOST 'WEKA_CORES(OS)' TODAY SHOULD_BE EXPECT_AFTER
            sort "$REMED"
            echo
            echo "SHOULD_BE lists the Slurm abstract CPU IDs of every thread on the Weka cgroup's"
            echo "cores (Core L# x threads/core + thread: hwloc PU L#, = Core L# at 1 thread/core);"
            echo "on sequential layouts these equal the OS IDs. EXPECT_AFTER is the slurm/system"
            echo "cpuset that must appear after the restart (= all CPUs minus the Weka cores)."
            echo "Apply per host <h>:"
            echo "  1. scontrol update nodename=<h> state=drain reason=cpuspeclist   # wait for jobs to end"
            echo "  2. edit slurm.conf: NodeName=<h> ... CpuSpecList=<SHOULD_BE>; delete any CoreSpecCount="
            echo "     on that line (Slurm errors when a node sets both)"
            echo "  3. restart slurmd on <h> (systemctl restart slurmd)"
            echo "  4. scontrol show node <h> | grep -i spec                      # must show the new list"
            echo "  5. cat /sys/fs/cgroup/cpuset/slurm/system/cpuset.effective_cpus \\"
            echo "         /sys/fs/cgroup/cpuset/weka-client/cpuset.effective_cpus  # slurm/system == EXPECT_AFTER"
            echo "     (cgroup v2: /sys/fs/cgroup/system.slice/*slurmstepd.scope/system/cpuset.cpus.effective"
            echo "      and /sys/fs/cgroup/weka-client/cpuset.cpus.effective)"
            echo "  6. scontrol update nodename=<h> state=resume"
        fi
        if [ -s "$UNPINT" ]; then
            echo
            echo "WEKA-UNPINNED — WEKA-side pinning drift, do not touch Slurm:"
            printf '%-28s %-22s %-18s %s\n' HOST WEKA_FE_RESOURCES FSTAB_ASKS CGROUP_HAS
            sort "$UNPINT"
        fi
        if [ -s "$HUNGT" ]; then
            echo
            echo "HUNG — collector stopped before scontrol, or lscpu/scontrol timed out (step named); re-check the host / its /admin mount:"
            printf '%-28s %-12s %s\n' HOST STEP CGROUP_VERDICT
            sort "$HUNGT"
        fi
    } | tee "$REPORT"
    echo "Report: $REPORT — full per-host output in $OUTDIR/"
}

# ---- fan-out ------------------------------------------------------------------

# run_one HOST — always returns 0: xargs stops the whole run when a command
# exits 255 (ssh's unreachable code). The status goes to RUN_RC for the canary.
run_one() {
    local h="$1" rc envs line
    envs="STEP_TIMEOUT=$STEP_TIMEOUT"
    [ -n "${CSWC_FLEET_SPEC:-}" ] && envs="$envs CSWC_FLEET_SPEC=1"
    if [ -s "$OUTDIR/fleet-spec.txt" ]; then
        line=$(grep -i -m1 "^${h%%.*}|" "$OUTDIR/fleet-spec.txt")
        [ -n "$line" ] && envs="$envs CSWC_SPEC='$(printf '%s' "${line#*|}" | LC_ALL=C tr -cd 'A-Za-z0-9=,._:() -')'"
    fi
    timeout --kill-after=10 "$HOST_TIMEOUT" \
        sshpass -e ssh $SSH_OPTS "$h" "env $envs bash -s -- --local" <"$SELF" \
            >"$OUTDIR/$h.txt" 2>"$OUTDIR/$h.err"
    rc=$?
    RUN_RC=$rc
    # ssh reserves 255 for its own transport errors; timeout(1) uses 124.
    # Any other non-zero is the REMOTE status and is not a failure.
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        mv -f "$OUTDIR/$h.txt" "$OUTDIR/$h.hung" 2>/dev/null
        echo "HUNG         $h  (no response in ${HOST_TIMEOUT}s — last step: $(grep '^@@STEP=' "$OUTDIR/$h.hung" | tail -1 | cut -d= -f2))"
    elif [ "$rc" -eq 255 ] || [ ! -s "$OUTDIR/$h.txt" ]; then
        mv -f "$OUTDIR/$h.txt" "$OUTDIR/$h.unreachable" 2>/dev/null
        echo "UNREACHABLE  $h  ($(head -1 "$OUTDIR/$h.err" 2>/dev/null))"
    elif [ "$rc" -ne 0 ]; then
        echo "done         $h  (remote rc=$rc: $(head -1 "$OUTDIR/$h.err" 2>/dev/null))"
    else
        echo "done         $h"
    fi
    return 0
}

collect() {
    command -v sshpass >/dev/null 2>&1 || { echo "ERROR: sshpass not found (EPEL: sudo dnf install sshpass)" >&2; exit 1; }
    command -v timeout >/dev/null 2>&1 || { echo "ERROR: timeout(1) not found (coreutils)" >&2; exit 1; }

    read -rs -p "SSH password for $(whoami): " SSHPASS; echo
    export SSHPASS

    local TOTAL HOSTS SKIPPED COUNT
    RAW_LIST=$(mktemp)          # global: the EXIT trap runs after this function returns
    [ -n "$RAW_LIST" ] || { echo "ERROR: mktemp failed" >&2; exit 1; }
    trap '[ -n "${RAW_LIST:-}" ] && rm -f -- "$RAW_LIST"' EXIT

    if [ -n "$HOSTS_FILE" ]; then
        grep -Ev '^[[:space:]]*(#|$)' "$HOSTS_FILE" | tr -d '\r' >"$RAW_LIST"
    else
        echo "Generating client list locally (dzdo weka cluster container)..."
        if ! dzdo weka cluster container -c --no-header -o hostname,cores \
                | awk '$2 ~ /^[0-9]+$/ && $2>0 {print $1}' | sort -u >"$RAW_LIST" \
                || [ ! -s "$RAW_LIST" ]; then
            echo "ERROR: could not auto-generate the client list on this host." >&2
            echo "Generate it manually and re-run with it as \$1:" >&2
            echo "  dzdo weka cluster container -c --no-header -o hostname,cores \\" >&2
            echo "    | awk '\$2>0 {print \$1}' | sort -u > clients.txt" >&2
            exit 1
        fi
    fi

    TOTAL=$(wc -l <"$RAW_LIST" | tr -d ' ')
    HOSTS=$(grep -Ev '^isv' "$RAW_LIST")
    SKIPPED=$(grep -Ec '^isv' "$RAW_LIST" || true)
    COUNT=$(printf '%s\n' "$HOSTS" | grep -c . || true)

    echo "Targets: $COUNT DPDK/pinned clients ($SKIPPED isv* VMs skipped of $TOTAL listed)"
    [ "$COUNT" -gt 0 ] || { echo "ERROR: no target hosts left after filtering" >&2; exit 1; }

    mkdir -p "$OUTDIR"
    printf '%s\n' "$HOSTS" >"$OUTDIR/targets.txt"
    [ -n "$EXCL" ] && printf '%s\n' "$EXCL" >"$OUTDIR/exclude.txt"
    echo "Writing per-host output to $OUTDIR/ (each host runs: bash -s -- --local < $SELF)"

    export OUTDIR SSH_OPTS HOST_TIMEOUT STEP_TIMEOUT SELF
    export -f run_one

    # -- canary: the first host that answers, alone (three tries at most). It
    #    also runs the one fleet-wide scontrol, so it gets one more step. --
    local h tries=0 canary=""
    while IFS= read -r h; do
        [ -n "$h" ] || continue
        tries=$((tries + 1))
        echo "Canary: $h"
        CSWC_FLEET_SPEC=1 HOST_TIMEOUT=$((HOST_TIMEOUT + STEP_TIMEOUT + 5)) run_one "$h"
        # A rejected login leaves no remote output at all; .err also carries
        # the remote commands' stderr, so only an EMPTY .unreachable counts.
        if [ -e "$OUTDIR/$h.unreachable" ] && [ ! -s "$OUTDIR/$h.unreachable" ] &&
           { [ "$RUN_RC" -eq 5 ] || grep -q 'Permission denied' "$OUTDIR/$h.err"; }; then
            echo "ERROR: canary $h rejected the password; stopping before the fleet (one failed login per host risks an AD lockout)." >&2
            exit 1
        fi
        if [ -s "$OUTDIR/$h.txt" ]; then
            if ! grep -q '^@@DONE' "$OUTDIR/$h.txt"; then
                echo "ERROR: canary $h answered but its collector stopped early (remote rc=$RUN_RC); see $OUTDIR/$h.txt and $h.err. Stopping before the fleet." >&2
                exit 1
            fi
            canary=$h
            break
        fi
        [ "$tries" -lt 3 ] || { echo "ERROR: 3 canary hosts unreachable or hung; stopping before the fleet." >&2; exit 1; }
    done <"$OUTDIR/targets.txt"

    if [ -n "$canary" ]; then
        sed -n 's/^@@FLEET_NODE=//p' "$OUTDIR/$canary.txt" >"$OUTDIR/fleet-spec.txt"
        if [ -s "$OUTDIR/fleet-spec.txt" ]; then
            echo "Canary scontrol works: one scontrol show node -o listed $(wc -l <"$OUTDIR/fleet-spec.txt" | tr -d ' ') Slurm nodes; hosts it lists skip their own scontrol"
        else
            rm -f -- "${OUTDIR:?}/fleet-spec.txt"
            echo "Canary scontrol listed no nodes: every host runs its own scontrol"
        fi
    fi

    tail -n +$((tries + 1)) "$OUTDIR/targets.txt" | xargs -P "$PAR" -I{} bash -c 'run_one "$@"' _ {}
}

# ---- main ---------------------------------------------------------------------

main() {
    HOSTS_FILE=""; PAR=64; SUMMARIZE_DIR=""; EXCL=""; MODE=fanout; RUN_RC=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --local)        MODE=local; shift; continue ;;
            --summarize|-s) SUMMARIZE_DIR="${2:?--summarize needs a results directory}"; shift 2; continue ;;
            --exclude|-x)   load_exclude "${2:?--exclude needs a file}"; shift 2; continue ;;
            -h|--help)      sed -n '2,/^$/p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
        esac
        case "$1" in
            ''|*[!0-9]*)
                if [ -r "$1" ]; then
                    HOSTS_FILE="$1"
                else
                    echo "ERROR: '$1' is neither a readable hosts file nor a parallelism number" >&2
                    echo "usage: $0 [clients.txt] [parallelism] [--exclude FILE]" >&2
                    echo "       $0 --summarize <results-dir> [--exclude FILE]" >&2
                    echo "       $0 --local" >&2
                    exit 1
                fi ;;
            *) PAR="$1" ;;
        esac
        shift
    done

    if [ "$MODE" = local ]; then
        local_mode
        exit 0
    fi

    # Post-auth watchdogs. ConnectTimeout only covers the TCP handshake; these
    # bound a session that authenticates and then stalls. HOST_TIMEOUT lets all
    # 4 timed steps (lscpu scontrol weka hwloc) expire, each after
    # STEP_TIMEOUT + 5s kill grace, plus 30s for ssh.
    HOST_TIMEOUT="${HOST_TIMEOUT:-$(( 4 * (STEP_TIMEOUT + 5) + 30 ))}"
    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=7 -o NumberOfPasswordPrompts=1 -o LogLevel=ERROR -o ServerAliveInterval=15 -o ServerAliveCountMax=3"

    if [ -n "$SUMMARIZE_DIR" ]; then
        OUTDIR="${SUMMARIZE_DIR%/}"
        [ -d "$OUTDIR" ] || { echo "ERROR: no such results dir: $OUTDIR" >&2; exit 1; }
        echo "Summarize-only mode: reporting over $OUTDIR (no SSH)"
    else
        OUTDIR="results-$(date +%Y%m%d-%H%M%S)"
        collect
    fi
    summarize
}

# Absolute path to this file: the fan-out streams it to every host.
# (Under "bash -s" on a remote host $0 is "bash"; --local never needs $SELF.)
SELF="$0"
case "$SELF" in /*) ;; *) [ -f "$SELF" ] && SELF="$(cd "$(dirname "$SELF")" && pwd)/$(basename "$SELF")" ;; esac

main "$@"
