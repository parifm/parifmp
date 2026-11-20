# Tuning the OS for a WEKA UDP-mode client with 19 cores

- **Personal notes, not WEKA documentation.** Ask WEKA Support before you change a production client.
- **Basis:** WEKA 5.1.42, with 4.4 checked at 4.4.37 and every claim checked again at 6.0.1 (differences: §2.6a); docs.weka.io, *Networking* and *Mounting filesystems*.
- **Prepared** 2026-10-21. **Lab-tested** 2026-10-24 (§7). **Extended 2026-11-20** with the lab of 2026-11-10 to 11-12: frontend roaming (§3.7), the November results (§8), and dated amendments. Each changed line carries "Amended 2026-11-20", "Added 2026-11-20" or "Corrected 2026-11-20".
- **Lab:** OCI. The client is BM.Standard3.64: 2× Xeon 8358, ConnectX-6 Dx 2×50G on NUMA 0, Ubuntu 22.04, kernel 6.8.0-1060-oracle. Backends are 6, then 8, VM.DenseIO.E5.Flex, 16 OCPU, VFIO, 4+2. WEKA 6.0.1. The November lab was a new build of the same shapes (8 backends, WEKA 6.0.1, cgroup v2).

**How to read the labels.** Every recommendation is tagged with one of three labels:
- **sourced:** taken from WEKA source or docs.
- **general practice:** standard Linux tuning, not WEKA-specific.
- **measured:** taken from the 2026-10-24 lab (§7). These are single 60 s fio runs per variant. The noise band from two same-state repeats (T2, T3) is under 1%. The lab's 50G port caps sequential read, so read gains show as CPU saved, not as throughput.
- **measured (November)**, added 2026-11-20: taken from the 2026-11-10 to 11-12 lab (§8). One run per cell unless a cell gives two. The noise band there is wider: two same-state runs were 1.5% to 2.4% apart, and the same arm was about 3% lower on 11-12 than on 11-10. Compare §8 figures inside one table only.

**Which reading of "19 cores" I chose.** I read it as `mount -t wekafs -o net=udp,core=<id>×19` (or `num_cores=19`). That is the maximum: 19 IO processes per host. It gives one client container with:
- 19 **FRONTEND** processes on slots 1–19;
- 1 **MANAGEMENT** process on slot 0.

---

## TL;DR: the commands

These are for the §4 example host: a 128-CPU, 2-socket machine with the NIC `ens1f0np0` (IP `<client-ip>`) on NUMA 0. The layout puts housekeeping on CPUs 0-1, the IRQs on 2-9, the 19 FEs on 10-28 and the application on 29-31 plus node 1. Run them as root with the client unmounted, then swap in your own NIC, IPs and CPU lists. §3 gives the verify and undo command for each one; §1 says why.

```bash
# Unmount first: changing the channel count resets the link
umount /mnt/weka

# Save the NIC's current settings so each change can be undone
mkdir -p ~/udptune-before; ethtool -l ens1f0np0 > ~/udptune-before/channels; cat /sys/class/net/ens1f0np0/tx_queue_len > ~/udptune-before/txqlen

# Set MTU 9000 on the WEKA port (every hop to the backends must match)
ip link set ens1f0np0 mtu 9000

# Check that a full 9000-byte packet reaches a backend without fragmenting
ping -M do -s 8972 -c 3 <backend-ip>

# Stop irqbalance so it can't move NIC IRQs back onto the FE cores
systemctl disable --now irqbalance

# Use 8 NIC queues, one per IRQ core (8 measured enough at 50G; 4 cost 34% of IOPS)
ethtool -L ens1f0np0 combined 8

# Deepen each TX queue so 8 queues don't silently drop WEKA packets (WEKA can't see these drops)
ip link set dev ens1f0np0 txqueuelen 10000

# Hash UDP on IPs and ports so the 20 WEKA sockets spread over all queues
ethtool -N ens1f0np0 rx-flow-hash udp4 sdfn

# Pin the NIC's IRQs round-robin onto CPUs 2-9, saving the old affinity first
i=0; for q in $(ls /sys/class/net/ens1f0np0/device/msi_irqs); do echo "$q $(cat /proc/irq/$q/smp_affinity_list)" >> ~/udptune-before/irq_affinity; echo $((2 + i++ % 8)) > /proc/irq/$q/smp_affinity_list; done

# Send any new IRQ to CPUs away from the FE cores and their siblings (0-1, 29-65, 93-127 on 128 CPUs)
echo ffffffff,e0000003,ffffffff,e0000003 > /proc/irq/default_smp_affinity

# Allow the 16 MiB socket buffers WEKA asks for, and turn off NUMA balancing, across reboots
printf 'net.core.rmem_max = 16777216\nnet.core.wmem_max = 16777216\nkernel.numa_balancing = 0\n' > /etc/sysctl.d/90-weka-udp.conf

# Load the new sysctl file now
sysctl --system

# Run the IRQ and FE cores at full clock speed
cpupower -c 2-28 frequency-set -g performance

# Keep the IRQ and FE cores out of deep C-states (optional: the lab measured no effect)
cpupower -c 2-28 idle-set -D 10

# cgroup v1 only: stop weka-agent widening application cpusets back to all CPUs every 5 minutes
sed -i 's/^isolate_cpusets=.*/isolate_cpusets=false/' /etc/wekaio/service.conf

# cgroup v1 only: restart the agent so the setting takes effect
systemctl restart weka-agent

# Keep logins and user jobs off the FE cores and their HT siblings
systemctl set-property --runtime user.slice AllowedCPUs=0-9,29-73,93-127

# Mount with the 19 FEs pinned to CPUs 10-28, on the NIC's NUMA node
mount -t wekafs -o net=udp,mgmt_ip=<client-ip>,$(printf 'core=%d,' {10..28} | sed 's/,$//') <backend>/<fs> /mnt/weka

# Start the application off the FE cores (measured: +25% randread IOPS against fio pinned on top of the FEs; §8.4 has the unpinned case)
taskset -c 29-31,93-95,32-63,96-127 <application command>

# Check that each of the 19 FEs landed on its own CPU in 10-28
for p in $(pgrep wekanode); do taskset -cp "$p"; done
```

---

## 1. Summary: the top 10 settings, in priority order

| # | Setting | Why (one line) | Expected effect | Risk | Label |
|---|---------|----------------|-----------------|------|-------|
| 1 | **Pin all 19 FE cores on the NIC's NUMA node** with explicit `core=` IDs, **only together with rows 2 and 8** | In UDP mode the automatic core picker ignores the NIC and alternates between NUMA nodes. Measured: 10 FEs on node 0, 9 on node 1 | Measured as a bundle with rows 2, 5, 8, 9 against stock: randread 4k **+27% IOPS (mean −21%)**, and **−25% FE CPU** at the same seqread throughput. **Done alone it made things worse:** −11% IOPS, −24% seqwrite, QD1 +16%. Measured: stock irqbalance put every NIC IRQ on node 0, which includes the FE cores. That this is the cause is a hypothesis, not tested on its own | Low. Needs about 19 free physical cores on that node | sourced + **measured** |
| 2 | **Keep NIC IRQs off the FE cores.** Stop irqbalance (or ban the FE CPUs), set N channels, and pin them to N IRQ cores on the NIC node. **With fewer channels, also raise `txqueuelen` to 10000** | WEKA does *not* mask IRQs or build a cpuset in UDP mode. With 8 channels, mlx5 maps 3 FEs onto some TX queues, and the default 1000-packet qdisc then overflows. WEKA can't see those drops (no `IP_RECVERR`), so they only show up as resends | No softirq stealing FE cycles (measured: FE `%soft` 7.7% → 0). `txqueuelen 10000` measured: 377k qdisc drops/min → 0. Measured at 50G: 8 IRQ cores = 12; 4 cost −34% IOPS; IRQs on the FE cores with RFS cost −6% IOPS (§7.7) | Medium. A channel change resets the link, so do it unmounted | sourced + general practice + **measured** |
| 3 | **Set `mgmt_ip=` to the IP on the fast NIC, and check the route** | UDP traffic uses the management IP(s), and egress follows the routing table | Stops traffic silently going out a slower NIC | Low | sourced |
| 4 | **MTU 9000 end to end** (IP MTU of at least 4056 at minimum) | WEKA packets reach 4056 B with DF set; a bigger packet is dropped, never fragmented | One 4 KiB block per packet; no `DROPPED_LARGE_PACKETS` | Medium. Every hop must match | sourced |
| 5 | **Shallow C-states and the `performance` governor on FE and IRQ cores** | A UDP FE sleeps in epoll the moment it goes idle, and WEKA sets no governor for a mount. Amended 2026-11-20: that holds for an FE with no IO. An FE with IO in flight does not sleep: its main thread polls in user space (§8.3) | Expected: lower wake-up latency. **Measured as part of the bundle: QD1 4k mean latency unchanged** (T 633 µs vs stock 635 µs). Measured on its own (§7.7): C1E or C6 enabled made no difference with `performance`, QD1 included. The governor half was not split out | Low. Costs some power | sourced + general practice + measured (bundle) |
| 6 | **Check that `rmem_max`/`wmem_max` ≥ 16 MiB and that each socket got it** | Each socket asks for exactly 16 MiB; WEKA raises the max only from the mgmt process, and only if it is lower | No `UdpRcvbufErrors` from a capped buffer. Raising above 16 MiB gains nothing | Low | sourced |
| 7 | **RSS hashes UDP on the 4-tuple** (`rx-flow-hash udp4 sdfn`) | All 20 sockets share one IP and differ only by port | Load spread across all IRQ queues instead of a few | Low | sourced + general practice |
| 8 | **Keep the application and its HT siblings off the FE cores** (cgroup `AllowedCPUs`, `taskset`, and optionally `isolcpus`). **On cgroup v1, first set `isolate_cpusets=false`**, or weka-agent widens every non-WEKA cpuset back to all CPUs every 5 min | No WEKA cpuset in UDP mode, and FEs run at normal priority | Measured: pinning fio off the FE cores gave **+25% randread IOPS and −11% QD1 mean**. Measured on v1: the sweep widened an app cpuset 29-31 → 0-127 within 5 min, which reset its tasks' affinity. **Amended 2026-11-20:** the baseline of the +25% was fio pinned one job per CPU on CPUs 0-31, on top of the FEs. It was not an application that the scheduler places. Measured (November, 8 FEs, §8.4): fio left to the scheduler on a host with about 100 idle CPUs cost pinned FEs nothing (668.1 against 671.4 kIOPS). A busy loop pinned on 4 of the 8 FE CPUs cost 26% of IOPS and tripled p99. So this row matters when something is pinned to, or has nowhere to run but, the FE CPUs | Low (cgroup) / Medium (`isolcpus` needs a reboot) | sourced + general practice + **measured** |
| 9 | **`kernel.numa_balancing=0`** | WEKA disables it only on "dedicated" containers, not on a UDP mount | No page-migration stalls on FE memory | Low | sourced + general practice |
| 10 | **Act only when a counter says so:** rings (`rx_out_of_buffer`), `netdev_budget` (`time_squeeze`), coalescing (latency A/B), XPS | Each fixes one specific bottleneck | Situational | Low | general practice |

**Added 2026-11-20, not a top-10 setting:** when other load cannot be kept off the FE cores (row 8), §3.7 describes how to let the FEs move to idle CPUs. It is optional, it is not a WEKA feature, and WEKA R&D has not been asked about it.

---

## 2. What WEKA does in UDP mode (from source)

### 2.1 How a UDP mount becomes 19 single-core processes
- **UDP mode is chosen by `net=udp`.** It is also inferred on a remount when no NICs are stored. In UDP mode no NIC is assigned.
- **Core count:** the larger of `num_cores` and the number of `core=` options. `num_cores=0` is allowed only in UDP mode and is treated as 1. The docs say not to combine `num_cores` with `core=` and that core 0 is reserved (docs.weka.io *Mounting filesystems*).
- **Cores are not dedicated in UDP mode,** whatever the dedicated-mode setting is. Same at 4.4.37.
- **Ports:** each FE listens on `base_port + slot`, the mgmt process on `base_port`. `base_port` is picked automatically from a free range unless given.
- **Cores are chosen even without dedication**:
  - **Manual (`core=`):** the IDs are taken as given.
  - **Automatic:** a slot with no DPDK NIC or no dedicated core has no NUMA preference. The allocator then **round-robins across NUMA nodes**. So an automatic 19-core UDP mount lands roughly 10/9 across two sockets, whatever NUMA node the NIC is on. Same at 4.4.37.
- **Pinning:** each FE opens the DPDK EAL without NICs (only for its mbuf/hugepage pool) when it has a core, and the EAL gets `-l<core>`, one pinned core. **Result: each FE is pinned to its one CPU but owns nothing else.**
- **Amended 2026-11-20: the pin is set in two more places, both in shell scripts inside the client container** (the two scripts are identical at 4.4.37, 5.1.42.17 and 6.0.1):
  - **At start:** the start script `wekanode.sh` runs `exec taskset -c $core /weka/wekanode --slot …`, so every thread of the process inherits the one-CPU mask. Measured: 6 of 6 threads per FE on the FE's CPU (§8.2).
  - **Every 60 s, on a cgroup v2 host:** `weka_cores_protector.sh` (same directory; run by supervisord in the container) compares each slot's affinity with `/tmp/slot.cores` and puts the main thread back on its CPU. Measured: an outside `taskset` widen was undone 28 to 53 s later (§8.2). The script acts only when the container has a cgroup2 mount at `/mnt/unified`, so by source it does nothing on a cgroup v1 host and nothing with `cgroups_mode=none`. It is present from 4.4.9, 5.0.4 and 5.1.0 on.
  - **With `cgroups_mode=none`:** `wekanode.sh` skips the `taskset` and only the EAL pin of the main thread is left (§8.5).

### 2.2 What WEKA does *not* do for a UDP mount (and does for dedicated cores)
| Mechanism | Dedicated (DPDK) | UDP mount |
|---|---|---|
| Cpuset that moves other tasks off the FE cores | yes | **no**: only dedicated-core slots go into the set, so the set is empty |
| Mask all PCI-MSI IRQs off the FE cores (and `default_smp_affinity`) | when `mask_interrupts` is set | **no**: the attached-core list is empty, and `mask_interrupts` is set only by `weka local setup container --dedicate`, which a mount does not use |
| `kernel.numa_balancing=0` | when `disable_numa_balancing` is set | **no** (same flag path) |
| CPU governor `performance` | when `cpu_governor=PERFORMANCE` | **no**: `UNCONFIGURED` is the enum default, so it is skipped |
| Userland busy-polling | yes, with a dedicated core | **no**: the reactor sleeps in epoll when idle |
| Spin before sleeping | 500 µs when the slot has DPDK NICs | **0 µs**: "a socket backend node will … immediately go to sleep in poll" |
| Amended 2026-11-20: what the two rows above mean under IO | not measured | **They describe an FE with nothing to do.** The reactor sleeps only when nothing is scheduled. Measured: with one IO in flight at a time, the serving FE's main thread used 64.97 s of CPU in about 66 s, 97% of it in wekanode user code that polls the driver and the network, while WEKA reported 2% for that process (§8.3) |
| Added 2026-11-20: re-pin after an outside affinity change | the same script reads every slot; not run in DPDK mode | **yes on cgroup v2**, every 60 s, main thread only; no on cgroup v1 or with `cgroups_mode=none` (by source; `none` measured) |
| Scheduling | SCHED_FIFO when the `ionode_scheduling` override is set | default policy `Legacy`, so nothing is changed. An override would give SCHED_OTHER with nice −5, never FIFO without a dedicated core |
| Voluntary `sched_yield()` | no | **yes, every 20 ms** (`cluster.core.yield.interval`) |
| weka-agent cpuset sweep, every `isolate_cpusets_interval_minutes` (5) while `isolate_cpusets=yes` (the default) | same | same, and it still runs. **cgroup v1:** moves every root-cpuset task except PID 1 into `/system`, and writes `/system`'s CPUs (in UDP mode, all CPUs) into every non-`/system`, non-WEKA cpuset. Both reset task affinity on v1. **cgroup v2:** no task moves and no rewrites |

**What follows:** in UDP mode the OS owns isolation, the IRQ layout, power state and NUMA balancing. WEKA only pins. Amended 2026-11-20: and on cgroup v2 it keeps the pin against outside changes (§2.1).

### 2.3 Sockets and packets
**Socket setup**
- **One socket per management IP:** each FE process opens one `SOCK_DGRAM` socket per management IP. With one IP that makes 20 sockets on the host (19 FE + mgmt). With `mgmt_ip=a+b` it makes 40 (docs: "multiple IPs in UDP mode uses their network interfaces for more bandwidth").
- **Non-blocking, epoll-driven:** readability is registered with the reactor, and receive runs only when the socket is readable.
- **DF always set (IPv4):** `IP_MTU_DISCOVER=IP_PMTUDISC_DO`, with no path-MTU discovery.
- **TOS:** `IP_TOS` is set from the configured DSCP value.
- **Buffers:** `SO_RCVBUF` and `SO_SNDBUF` are set to **16 MiB**. If the kernel grants less (it doubles the value and caps it at `rmem_max`/`wmem_max`), WEKA logs `ERROR "#UDP socket … failed to set #RCVBUF"`. `rmem_default` doesn't apply, because the size is set explicitly.
- **Binding:** to IP:port, with `SO_BINDTODEVICE` **off** unless the override `net.sock_backend.bind_to_interface` is set. So the **egress interface comes from the routing table**.

**Packet path**
- **Batch sizes:** receive uses `recvmmsg` with up to 128 messages; send uses `sendmmsg` with up to 33.
- **Copies:** receive copies into a WEKA mbuf; send gathers a 2-iovec (L6 header + payload). The **copy runs on the FE core**.
- **EAGAIN on send:** WEKA counts `UDP_SENDMSG_FAILED_EAGAIN` and *stalls* the TX queue rather than dropping.
- **Other send failures:** counted as `UDP_SENDMSG_FAILED_OTHER`; the first packet is dropped. A partial batch is counted as `UDP_SENDMSG_PARTIAL_SEND`.

**MTU**
- **Link MTU:** the payload ceiling is 4056 bytes, or 3864 on Azure, or with `enforce_max_mtu_3900`.
- **Too-big packets:** a packet larger than the netdev MTU is **dropped** and counted as `DROPPED_LARGE_PACKETS`.
- **Warning:** WEKA warns when the netdev MTU is below 4056.
- **Port liveness:** a port with no RX or TX for 30 s is declared dead, with WARN from 5 s.

### 2.4 Host sysctls WEKA writes itself
These are written from the management process only, only to *raise* a value, and file errors are tolerated:

| Key | Value | Override to skip |
|---|---|---|
| `net.core.rmem_max`, `net.core.wmem_max` | 16777216 | `net.proc.override.udp_socket[.clients]` |
| `net.ipv4.neigh.default.gc_thresh1/2/3`, `base_reachable_time`, `gc_stale_time` | 8192/16384/16384, 3600, 3600 | `net.proc.override.arp_gc` |
| `net.ipv4.conf.{all,default}.arp_announce` = 2, `arp_filter` = 1 | | `net.proc.override.arp_comm` |
| `ignore_routes_with_linkdown` = 1 (v4/v6), `ipv6.conf.all.use_oif_addrs_only` = 1 | | `…route`, `…ipv6_oif` |

Leave these alone. Your sysctl file must not set them lower. A `sysctl --system` that runs *after* WEKA starts can't shrink sockets that are already open, but it will cap the ones opened after the next restart.

### 2.5 Hugepages
UDP FEs still take a hugepage pool, as every IO slot does except a pure dataserv slot. It is sized per NUMA node from the FE's core. WEKA allocates the pool itself, so don't pre-reserve `nr_hugepages`. Instead, make sure the NIC's node has the free memory once all 19 cores sit there. I didn't trace the per-FE size for UDP; see §6.

### 2.6 What changes at 4.4 (4.4.37)
- **Same as 5.1:**
  - the socket backend: 16 MiB buffers, DF, 128/33 batches;
  - cores not dedicated under UDP, and the 19-core max;
  - the cross-NUMA round-robin;
  - the PCI-MSI mask pattern;
  - the `rmem_max` write;
  - userland polling only with a dedicated core;
  - idle-spin only with DPDK NICs;
  - the 20 ms yield.
- **Different:** for a client container whose version is below 5, the *agent* works out the management IP from the backends. 5.x leaves that to wekanode. On 4.4, always pass `mgmt_ip=` (row 3).

### 2.6a 6.0.1 differences (the lab runs 6.0.1)
Everything in §2.1-2.5 holds at 6.0.1. Behaviour changes:
- **New `mgmt_net=<if>[+<if>]` mount option:** wekanode works out the management IPs from the named interfaces at start. It is mutually exclusive with `mgmt_ip=` and rejected for client versions below 5. It's an alternative to `mgmt_ip=` in row 3; `ip route get` still decides egress.
- **`#UDPSTAT` trace every 5 s** (DEBUG): per-port rx/tx packets and bytes, sendmsg EAGAIN/error/partial, `DROPPED_LARGE_PACKETS` and free mbufs. Extra evidence for §5; the `weka stats` path is unchanged.
- **RX mbufs carry the real socket port id** (was `invalid`). No tuning effect.
- **No `CoreAllocated` / `DisabledNumaBalancing` / `Hugepages*` events** (5.1.42.17 has them). Check FE pinning with `taskset`, as row 1 already says.
- **Hugepages:** 5.1.42.17's spread override is absent; for a non-k8s client the per-NUMA sizing is the same.

---

## 3. OS tuning layered on top

Conventions:
- `IF` = the client data NIC; `FE` = the 19 FE CPUs; `IRQC` = the IRQ cores; `SIB` = the HT siblings of `FE`.
- **Save before you change.** Each "save" line writes to `~/udptune-before/`, so the undo step has the original values.
- Make channel, ring and MTU changes **with the client unmounted.** They reset the link, and a live FE sees port flaps and resends.

```bash
mkdir -p ~/udptune-before
IF=ens1f0np0
NODE=$(cat /sys/class/net/$IF/device/numa_node); echo "NIC NUMA node: $NODE"
lscpu -e=CPU,NODE,SOCKET,CORE,ONLINE        # map logical CPU -> node/core; siblings share CORE
numactl -H
```

### 3.1 CPU and NUMA layout
| Setting | Command | Verify | Undo | Label |
|---|---|---|---|---|
| FE cores on the NIC's node, one per physical core, siblings left idle | `mount -t wekafs -o net=udp,mgmt_ip=<ip-on-IF>,core=10,core=11,…,core=28 <backend>/<fs> /mnt/weka` | Primary: `ps -eo pid,psr,comm \| grep wekanode` (expect 20 processes), then `taskset -cp <pid>` on each FE (one CPU each). Secondary: `/tmp/slot.cores` (`slot=N,cpu`, written by wekanode). I haven't checked whether that path is the host's `/tmp` or inside a container mount namespace. Amended 2026-11-20, measured: it is inside the container; `weka local exec -C <container> cat /tmp/slot.cores` printed `slot=1,10`, `slot=2,11`, … on the lab client. Also: `taskset -cp <pid>` reads the main thread only; `for t in /proc/<pid>/task/*; do taskset -cp ${t##*/}; done` shows all 6 | Remount without `core=` | sourced |
| Leave the FE cores' HT siblings unused (or turn SMT off) | No direct command; keep `SIB` out of every app/IRQ mask below. SMT off: `echo off > /sys/devices/system/cpu/smt/control` | `cat /sys/devices/system/cpu/smt/active` | `echo on > …/smt/control` | general practice |
| Keep the app off `FE`+`SIB` (cgroup v2, runtime) | `systemctl set-property --runtime user.slice AllowedCPUs=<all minus FE,SIB>`; for a service: `AllowedCPUs=` in a drop-in; ad hoc: `taskset -c <list> <cmd>` / `numactl --physcpubind=<list>` | `cat /sys/fs/cgroup/user.slice/cpuset.cpus.effective` | `systemctl set-property --runtime user.slice AllowedCPUs=` | general practice |
| **cgroup v1 hosts only:** stop the agent's 5-min cpuset sweep, or it undoes an app cpuset | `stat -fc %T /sys/fs/cgroup` (`cgroup2fs` means v2: skip this row). On v1, save `cp /etc/wekaio/service.conf ~/udptune-before/`, set `isolate_cpusets=false` (the installed file uses `true`/`false`), then run `systemctl restart weka-agent` with the client unmounted | `grep isolate_cpusets /etc/wekaio/service.conf`; 10 min later, `taskset -cp <app pid>` and `cat <app cpuset>/cpuset.cpus` are unchanged | Restore the saved `service.conf`, then `systemctl restart weka-agent` | sourced + **measured** (§7.5). With `true`, a cpuset `udpapp` 29-31 became 0-127 at the first sweep, and its task's affinity went with it. A `taskset` 29-31 process in `/system` kept its mask, and so did the 19 FEs: in UDP mode they live in `/system`, and `/weka-client` has no CPUs. With `false` (after an agent restart), nothing changed over 12 min: the cpuset, its task, the `taskset` task and the FE pins all held. The FEs then sat in the root cpuset `/`, because the agent no longer moves tasks to `/system`. In UDP mode WEKA builds no cpuset, so for a host whose only container is this UDP client the sweep protects nothing (§2.2). Check first that no dedicated WEKA container shares the host |
| Don't restrict `system.slice` | No command. WEKA's processes may live there, and an `AllowedCPUs` there would block the FE's own `sched_setaffinity` | No verify step | No undo needed | general practice (caution) |
| `kernel.numa_balancing=0` | `sysctl -w kernel.numa_balancing=0` (persist in the sysctl file, §3.4) | `sysctl kernel.numa_balancing` | `sysctl -w kernel.numa_balancing=1` | sourced (WEKA does it for dedicated hosts) + general practice |
| Optional step B: boot-time isolation | Kernel args `isolcpus=managed_irq,domain,<FE>` (`grubby --update-kernel=ALL --args=…`) | `cat /sys/devices/system/cpu/isolated` | `grubby --update-kernel=ALL --remove-args=isolcpus` | general practice, **lab first** (§6) |

### 3.2 IRQs, RSS, RPS/RFS, XPS
| Setting | Command | Verify | Undo | Label |
|---|---|---|---|---|
| Stop irqbalance (or ban CPUs) | `systemctl stop irqbalance; systemctl disable irqbalance`. Ban instead: `IRQBALANCE_BANNED_CPULIST=<FE>,<SIB>` in `/etc/sysconfig/irqbalance` (irqbalance ≥1.8), then restart | `systemctl is-active irqbalance` | `systemctl enable --now irqbalance` | sourced (no WEKA mask in UDP) + general practice |
| Channels = number of IRQ cores | Save `ethtool -l $IF > ~/udptune-before/channels`, then `ethtool -L $IF combined 8` | `ethtool -l $IF` | `ethtool -L $IF combined <saved>` | general practice |
| **With fewer channels: `txqueuelen 10000`** | Save `cat /sys/class/net/$IF/tx_queue_len > ~/udptune-before/txqlen`, then `ip link set dev $IF txqueuelen 10000` (persist: a udev rule or the NetworkManager/netplan link setting) | `ip -d link show $IF` (qlen); under write load, `tc -s qdisc show dev $IF` shows `dropped 0`, and `nstat -z UdpSndbufErrors` stays 0 | `ip link set dev $IF txqueuelen <saved>` | **measured** (§7.3) + sourced. mlx5's default XPS sends CPU n to tx-(n mod channels), so 19 FEs on 8 queues put 3 FEs on tx2–tx4. The default 1000-packet `pfifo_fast` overflowed on seqwrite. WEKA sets no `IP_RECVERR` (checked at 6.0.1), and Linux `udp_send_skb()` (`net/ipv4/udp.c`, v6.8) then reports the `-ENOBUFS` as success and only counts `UdpSndbufErrors`. So WEKA sees resends, not send errors. A bigger TX ring alone (4096) didn't stop it |
| Pin the NIC's IRQs to `IRQC` (see the script below) | Script below | `for i in $(ls /sys/class/net/$IF/device/msi_irqs); do echo "$i $(cat /proc/irq/$i/effective_affinity_list)"; done` | Replay `~/udptune-before/irq_affinity`, or re-enable irqbalance | general practice |
| Default affinity for new IRQs (WEKA does this when dedicated) | Save `cat /proc/irq/default_smp_affinity > ~/udptune-before/default_smp_affinity`, then write a hex mask without `FE`+`SIB` | `cat /proc/irq/default_smp_affinity` | Write the saved mask back | sourced + general practice |
| RSS on the UDP 4-tuple | `ethtool -n $IF rx-flow-hash udp4` should list "L4 bytes 0 & 1 … 2 & 3". If not: `ethtool -N $IF rx-flow-hash udp4 sdfn` (and `udp6`) | `ethtool -n $IF rx-flow-hash udp4` | `ethtool -N $IF rx-flow-hash udp4 sd` | sourced (20 ports, 1 IP) + general practice |
| RSS indirection spread evenly | `ethtool -X $IF equal 8` (usually the default after `-L`) | `ethtool -x $IF` | `ethtool -X $IF default` | general practice |
| RPS off (default), RFS off (default) | `cat /sys/class/net/$IF/queues/rx-*/rps_cpus` should all be 0 | Same command | No change needed | general practice; RFS is the lab alternative (§6) |
| XPS: map FE cores to TX queues (optional) | `echo <hexmask of 2-3 FE cpus> > /sys/class/net/$IF/queues/tx-N/xps_cpus` for N=0..7. Masks are hex, comma-grouped every 32 CPUs | `grep . /sys/class/net/$IF/queues/tx-*/xps_cpus` | Write back the saved values (the driver sets its own on `-L`) | general practice, low priority |

IRQ pin script. It is driver-neutral (it reads `msi_irqs`), saves the old affinity first, and says so when a write fails, which happens for kernel-managed IRQs:
```bash
#!/usr/bin/env bash
# Pin every MSI IRQ of $IF round-robin onto IRQC; save old affinity for undo.
set -u
IF=${1:?netdev}; shift
IRQC=("$@")                                  # e.g. 2 3 4 5 6 7 8 9
SAVE=~/udptune-before/irq_affinity; mkdir -p ~/udptune-before; : > "$SAVE"
i=0
for irq in $(ls /sys/class/net/$IF/device/msi_irqs); do
  echo "$irq $(cat /proc/irq/$irq/smp_affinity_list)" >> "$SAVE"
  cpu=${IRQC[$(( i % ${#IRQC[@]} ))]}
  if ! echo "$cpu" > /proc/irq/$irq/smp_affinity_list; then
    echo "irq $irq: write refused (kernel-managed?) - left as is"
  fi
  i=$((i+1))
done
echo "saved $(wc -l < "$SAVE") entries to $SAVE"
# undo: while read irq cpus; do echo "$cpus" > /proc/irq/$irq/smp_affinity_list; done < ~/udptune-before/irq_affinity
```

**Why I chose separate IRQ cores over RFS co-location.**
- **The trade-off:** every FE socket is reached by many RSS queues, because the backends' ports and the 19 local ports all hash differently. So no queue maps to one FE. Each received packet is processed in softirq on an IRQ core, which then wakes a sleeping FE on another core (an IPI plus C-state exit).
- **The RFS option:** setting `net.core.rps_sock_flow_entries` and per-queue `rps_flow_cnt` would move that softirq onto the consuming FE core. It saves the IPI but takes cycles from an FE that is already the documented bottleneck.
- **My choice:** separate IRQ cores as the default, because it is predictable and easy to see in `mpstat`. RFS is the first lab A/B.

### 3.3 Rings, coalescing, offloads, MTU
| Setting | Command | Verify | Undo | Label |
|---|---|---|---|---|
| MTU 9000 on `IF` (and switch ports and backends) | `ip link set $IF mtu 9000` (persist in NetworkManager: `nmcli con mod <con> 802-3-ethernet.mtu 9000`) | `ip -d link show $IF`; path check: `ping -M do -s 8972 <backend-ip>` | `ip link set $IF mtu <saved>` | sourced (4056 B + DF + drop) |
| Route check: egress goes out `IF` | `ip route get <backend-ip> from <mgmt_ip>` should show `dev $IF` | Same command | No change | sourced (no `SO_BINDTODEVICE` by default) |
| RX/TX rings larger, **only if** `rx_out_of_buffer`/`rx_dropped` climbs | Save `ethtool -g $IF > ~/udptune-before/rings`, then `ethtool -G $IF rx 8192 tx 8192` (mlx5 max 8192; ice shows its own max in `-g`) | `ethtool -g $IF` | `ethtool -G $IF rx <saved> tx <saved>` | general practice |
| Coalescing: keep adaptive (default) and A/B a fixed low value | Save `ethtool -c $IF > ~/udptune-before/coalesce`. A/B: `ethtool -C $IF adaptive-rx off rx-usecs 8 rx-frames 64` | `ethtool -c $IF` | `ethtool -C $IF adaptive-rx on` (or the saved values) | general practice; matters because FEs sleep (§2.2) |
| Offloads: keep RX/TX checksum on; nothing else to tune | `ethtool -k $IF \| grep -E 'rx-checksumming\|tx-checksumming'` should be `on` | Same command | `ethtool -K $IF rx on tx on` | general practice. WEKA uses the UDP checksum as end-to-end protection; it sets no `UDP_GRO`/`UDP_SEGMENT`, so GRO/GSO/LRO don't apply |

### 3.4 Socket and backlog sysctls
Persistent file `/etc/sysctl.d/90-weka-udp.conf`:
```
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
kernel.numa_balancing = 0
# only if /proc/net/softnet_stat col 3 (time_squeeze) climbs on IRQ cores:
# net.core.netdev_budget = 600
# net.core.netdev_budget_usecs = 8000
# only if col 2 (dropped) climbs, i.e. RPS/RFS in use:
# net.core.netdev_max_backlog = 16384
```

| Setting | Command | Verify | Undo | Label |
|---|---|---|---|---|
| `rmem_max`/`wmem_max` ≥ 16 MiB. Higher gains nothing: each socket asks for exactly 16 MiB | `sysctl --system` | `sysctl net.core.rmem_max net.core.wmem_max`; **per socket:** `ss -uampn \| grep -A1 wekanode` should show `rb33554432` and `tb33554432` on 20 sockets per IP (19 FE + mgmt). Fewer sockets, or a smaller `rb`, needs a look. Also check the WEKA trace for `failed to set #RCVBUF` | Delete the file and run `sysctl -w` with the old values | sourced |
| `net.ipv4.udp_mem` has room for the worst case: 20 sockets × 32 MiB per IP ≈ 164k 4K pages | No change normally | `sysctl net.ipv4.udp_mem` (pages; the 3rd value must be well above 164k, or 328k with 2 IPs); `cat /proc/net/sockstat` (`UDP: mem`) | No undo needed | general practice |
| `rmem_default`/`wmem_default`: leave alone | No command | No verify step | No undo needed | sourced (WEKA sets the size explicitly) |
| `netdev_budget`, `netdev_budget_usecs`: only on evidence | `sysctl -w net.core.netdev_budget=600 net.core.netdev_budget_usecs=8000` | `/proc/net/softnet_stat` col 3 delta per IRQ CPU | `sysctl -w net.core.netdev_budget=300 net.core.netdev_budget_usecs=2000` (kernel defaults) | general practice |
| `netdev_max_backlog`: only with RPS/RFS | `sysctl -w net.core.netdev_max_backlog=16384` | softnet col 2 | `sysctl -w net.core.netdev_max_backlog=1000` | general practice |
| `busy_poll`/`busy_read`: don't set | No command | No verify step | No undo needed | general practice (epoll busy-poll needs one NAPI per epoll set; here every FE is fed by many queues). Gap in §6. **Amended 2026-11-20, measured (November, §8.6):** `net.core.busy_read=50` with `busy_poll=50` changed no profile outside the noise band, so the row stands: don't set. The knob does reach the FEs (the kernel busy-poll loop ran on about 3% of an idle FE's sleeps), so the reason given first is only part of it. If someone set it: verify `sysctl net.core.busy_read net.core.busy_poll`; undo `sysctl -w net.core.busy_read=0 net.core.busy_poll=0` |

### 3.5 C-states, governor, tuned
| Setting | Command | Verify | Undo | Label |
|---|---|---|---|---|
| Shallow idle on `FE`+`IRQC` only | `cpupower -c <FE>,<IRQC> idle-set -D 10` (turns off states with exit latency above 10 µs) | `cpupower -c 10 idle-info`; `turbostat --quiet --interval 5 --show CPU,Busy%,Bzy_MHz,C1%,C6%` (FE cores: C6% ≈ 0 under load) | `cpupower -c <list> idle-set -E` | sourced (FE epoll-sleeps) + general practice. Lab (§7): `-D 2` (C1 only; Xeon 8358 exposes C1 1 µs, C1E 4 µs, C6 170 µs) together with `performance` left QD1 4k mean latency unchanged. Not A/B'd on its own |
| `performance` governor on `FE`+`IRQC` | Save `grep . /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor > ~/udptune-before/governor`, then `cpupower -c <FE>,<IRQC> frequency-set -g performance` | `cat /sys/devices/system/cpu/cpu10/cpufreq/scaling_governor`; turbostat `Bzy_MHz` | `cpupower -c <list> frequency-set -g <saved>` | sourced (not set for a mount) + general practice |
| Persistent, whole host (simpler, more power): tuned `latency-performance` | Save `tuned-adm active > ~/udptune-before/tuned`, then `tuned-adm profile latency-performance` | `tuned-adm active; tuned-adm verify` | `tuned-adm profile <saved>` | general practice. Not `network-latency`, which also sets `busy_read`/`busy_poll` |
| BIOS: power profile "Maximum Performance", C-states ≤ C1 if allowed | Vendor BIOS | `turbostat` C-state residency | BIOS | general practice |

`cpupower` settings don't survive a reboot. Persist them with a oneshot systemd unit ordered before `weka-agent.service`, or use the tuned profile.

### 3.6 Hugepages
| Setting | Command | Verify | Undo | Label |
|---|---|---|---|---|
| No manual `nr_hugepages`; leave room on the NIC's node | `numastat -m` before mounting: check free memory on `$NODE` | After mount: `grep -E 'HugePages_(Total\|Free)' /sys/devices/system/node/node$NODE/meminfo` | No undo needed | sourced |
| Transparent hugepages: no WEKA-specific need found. Amended 2026-11-20: leave the distribution default | No command | `cat /sys/kernel/mm/transparent_hugepage/enabled` (the lab's Ubuntu 22.04 default is `madvise`) | If it was changed: `echo madvise > /sys/kernel/mm/transparent_hugepage/enabled`, then remount so the FEs start under it | Gap in §6. **Amended 2026-11-20, measured (November, §8.6):** under `madvise` no wekanode process had anonymous huge pages (0 of 20), so `madvise` and `never` are the same for the FEs. Under `always` (with `defrag=madvise`), after a remount, each wekanode process had 248-274 MiB of them and no profile moved outside the noise band. The host had free, unfragmented memory (`compact_stall` 0); a fragmented or nearly full host and `defrag=always` were not tested |

### 3.7 Optional: let the frontends roam (added 2026-11-20)

**Read this first.**
- **Use row 8 first.** The normal fix is to keep other load off the FE CPUs. This section is for a host where something else uses the FE CPUs and cannot be moved.
- **Status: not a WEKA feature.** WEKA pins each FE and, on cgroup v2, re-pins it (§2.1). The steps below stop the re-pin with a documented agent setting and then change the affinity from outside WEKA. WEKA R&D has not been asked about either step.
- **What `cgroups_mode=none` costs:**
  - WEKA raises the WARNING alert `NoCgroupsConfigured` for the host (measured).
  - The setting is host-wide: one agent setting for every WEKA container on the host (sourced).
  - The cores protector does nothing in this mode (measured). It was added after wekanode processes lost their core pinning in the field. Whether that failure can occur when WEKA uses no cgroups was not traced.
- **Scope of the measurement.** `none` plus the widen was measured with 8 FEs (mount `core=10..17`, roam set 10-28), in state T of §7, on cgroup v2, kernel 6.8, a stateless client and WEKA 6.0.1, with one run per arm. With 19 FEs, roaming was measured only with a lab-only switch that stops the protector, one run per arm. There it gave back 43% of the IOPS that the competing load cost, and with nothing competing the resend rate of the widened FEs was 2.5× that of the pinned FEs in the one pair that was run (not repeated, not explained).

**What roaming gave** (measured, November; randread 4k; tables in §8.4 and §8.5). Rows 1, 2, 4 and 5 used the lab-only switch in `auto` mode; row 3 used `cgroups_mode=none`.

| # | Case | Pinned FEs | Widened FEs |
|---|---|---|---|
| 1 | 8 FEs, nothing competes | 656.2-671.4 kIOPS | 667.1 kIOPS: no cost outside the band |
| 2 | 8 FEs, a busy loop pinned on 4 of the FE CPUs, 11 idle whole cores in the roam set | 479.9-493.9 kIOPS, p99 7.4-7.6 ms | 661.7-665.6 kIOPS, p99 2.2-2.3 ms: all of the loss back |
| 3 | The same in `none` mode, at the lower level of 11-12 (no-load 644.8-644.9) | 469.7 kIOPS, p99 8.1 ms | 637.1 kIOPS, p99 2.4 ms |
| 4 | 8 FEs, roam set over-committed (23 busy threads on 19 CPUs) | 582.3 kIOPS | 579.5 kIOPS: no gain |
| 5 | 19 FEs, busy loops on 10 of the FE CPUs, spare CPUs mostly sibling threads (no-load 1,024.0) | 800.8 kIOPS, p99 5.7 ms | 897.7 kIOPS, p99 1.9 ms: 43% of the IOPS loss back, nearly all of the tail |

Roaming helps only when the roam set has idle CPUs, and whole cores help more than sibling threads. An FE with IO in flight uses a whole CPU (§8.3). So do not count an FE CPU as spare because WEKA shows that FE as idle.

**How to choose the roam set** (general practice unless marked)
- Keep it on the NIC's NUMA node. Measured: after the widen, each FE's hugepage memory was still all on node 0, where the FE started. A roam set that crosses nodes was not tested.
- Leave out the IRQ cores and the housekeeping CPUs.
- Prefer whole cores to sibling threads (measured: row 5 against row 2).
- The §4 masks (`default_smp_affinity`, `AllowedCPUs`) assume FEs on CPUs 10-28 only. If the roam set is larger, decide for each added CPU whether IRQs and user tasks may use it, and recompute both masks.
- In the §4 layout, 19 FEs on 10-28 leave only CPUs 29-31 and sibling threads to spare on node 0. Roaming fits a mount with fewer FEs than the roam set has cores. The measured shape was 8 FEs on 19 cores.
- Keep `txqueuelen 10000` (row 2). mlx5's default XPS maps CPU n to tx-(n mod channels), so an FE that moves also changes its TX queue. Every measured arm had `txqueuelen 10000`. HYPOTHESIS: the TX queue change is behind the 19-FE resend figure; the other candidate is run-to-run variation. Check: three pinned and three widened runs with 19 FEs; not run.

**Steps**

| Step | Command | Verify | Undo | Label |
|---|---|---|---|---|
| 1. Is the re-pin active on this host? | `stat -fc %T /sys/fs/cgroup`; `weka local status \| grep -i cgroups`; `pgrep -af weka_cores_protector` | `cgroup2fs`, `mode=auto, version=V2, enabled=true` and a protector process: the re-pin is active, so do step 2. On cgroup v1, or on a release before 4.4.9, 5.0.4 or 5.1.0, there is no re-pin by source: skip step 2. A widen on such a host was not tested | Nothing to undo | sourced + **measured (November)** on cgroup v2 at 6.0.1 |
| 2. Stop the re-pin with `cgroups_mode=none` | With the client unmounted: `cp -p /etc/wekaio/service.conf ~/udptune-before/service.conf`; `grep -c '^cgroups_mode=' /etc/wekaio/service.conf` (must print 1); `sed -i 's/^cgroups_mode=auto$/cgroups_mode=none/' /etc/wekaio/service.conf`; `grep -n '^cgroups_mode=' /etc/wekaio/service.conf` (must now show `none`; the `sed` changes nothing, and says nothing, if the line held another value such as `force`); `systemctl restart weka-agent`; then mount as before | `weka local status \| grep -i cgroups` shows `mode=none, version=V2, enabled=false`. `weka alerts` shows `NoCgroupsConfigured` for the host. `grep -c mismatch /opt/weka/logs/<container>/weka/weka-cores-protector-stdout.log` no longer grows | Unmount; `sed -i 's/^cgroups_mode=none$/cgroups_mode=auto/' /etc/wekaio/service.conf`; `cmp /etc/wekaio/service.conf ~/udptune-before/service.conf` (no output means identical); `systemctl restart weka-agent`; mount. The status line is back to `mode=auto, version=V2, enabled=true` | **measured (November)**: apply, verify and undo, each once, on one host + sourced (docs.weka.io *Add clients*, "cgroups configuration") |
| 3. Widen each FE's main thread, after every mount | The script below | `for p in $(pgrep -f 'wekanode --slot'); do taskset -cp "$p"; done` shows the roam list for each FE, and still shows it 2 minutes later. With the re-pin active, the list is back to one CPU within 60 s | The undo script below: it puts each FE that still runs back on its first CPU and skips the records of processes that are gone. Or remount: a remount starts new, pinned processes (measured) | **measured (November)** with a lab script that makes the same `taskset -c -p` call for each thread. The two short scripts below were not run on a host. Corrected 2026-11-20: the first version lost undo records on some second runs (note below the scripts). The versions below were parsed with bash 5 and run against stand-ins for `pgrep`, `taskset` and `/proc` in the second-run cases listed there |
| 4. See that the FEs move under load | `pidstat -u -t -p <FE pid> 5` (the CPU column of the main thread) | An FE whose CPU is busy with something else runs on another CPU of the roam set | Nothing to undo | general practice. The lab sampled the last CPU of every thread once a second |

Notes on step 2:
- The docs page shows the line added bare. The installed file is an INI file that the agent writes at install with every setting (sourced, at 6.0.1). On the lab client the line was already there, under `[cgroups]`. Change it in place. A bare line added at the end of the file falls under the last section; whether the agent reads it there was not tested.
- Do not paste `service.conf` into a ticket or a chat. It also holds the distribution-server and proxy settings.
- For a persistent client container, the docs add `weka local restart` after the agent restart. That path was not tested: a stateless mount's container is removed at unmount.

```bash
# Step 3. Run as root after each mount. ROAM is the CPU list the FEs may use (the lab's list included the mount's core= CPUs).
ROAM=10-28
PROC=/proc
S=~/udptune-before/fe_affinity; mkdir -p ~/udptune-before; touch "$S"
start_of() { [[ -r $PROC/$1/stat ]] && sed 's/.*) //' "$PROC/$1/stat" | cut -d' ' -f20; }   # process start time, in clock ticks since boot
n=0
for p in $(pgrep -f 'wekanode --slot'); do
  m=$(taskset -cp "$p" | sed 's/.*: //')
  [[ $m =~ ^[0-9]+$ ]] || continue        # main thread not on one CPU: the management process, or an FE already widened
  t=$(start_of "$p")
  [[ $t =~ ^[0-9]+$ ]] || { echo "pid $p: no start time read, left alone"; continue; }
  grep -q "^$p $t " "$S" || echo "$p $t $m" >> "$S"   # one record per process (pid + start time): written once, never rewritten
  if taskset -cp "$ROAM" "$p"; then n=$((n+1)); fi
done
echo "widened $n frontends; $S holds $(wc -l < "$S") records (pid, start time, first CPU), old mounts included"
```

```bash
# Undo of step 3. Run as root. A record is used only when its pid still has the saved start time.
PROC=/proc
S=~/udptune-before/fe_affinity
start_of() { [[ -r $PROC/$1/stat ]] && sed 's/.*) //' "$PROC/$1/stat" | cut -d' ' -f20; }
while read -r p t m; do
  if [[ -n $t && $(start_of "$p") == "$t" ]]; then taskset -cp "$m" "$p"; else echo "pid $p: not the saved process (remount or restart), skipped"; fi
done < "$S"
```

**Corrected 2026-11-20.** The first script of this section started a new save file on each run that found a pinned FE, and a record held only a pid and a CPU. A second run on the same mount then lost undo records in these cases (each one reproduced against stand-ins):
- One FE process restarted between the runs: the records of all the other FEs were lost.
- The first run stopped part way: the records of the FEs that it had widened were lost.
- The roam set was one CPU: each record was replaced with the roam CPU.
- The undo after a remount set the affinity of whatever process had a saved pid.

The first script also counted an FE before `taskset` answered: it printed "widened 8" when `taskset` refused 4 of the 8. The script above counts an FE only after `taskset` succeeds.

A second run with all FEs still widened kept the file. The script above never rewrites or removes a record. A record is a pid, the start time of that process and its first CPU. The undo skips a record when the pid has a different start time. The file grows by one line for each FE for each mount; delete it only when no widened FE runs. Delete it after a reboot too: the start time counts from boot, so an old record can match a new process.

Notes on step 3:
- Paste the scripts into a root shell or run them from a file. Under `bash -c '…'` or `ssh host '…'`, `pgrep -f` also finds the shell that carries the command text (general practice). The one-CPU test skips that shell unless it is itself pinned to one CPU.
- The script widens the main thread only. In `none` mode that is the whole job: the other 5 threads of each FE are already free on all CPUs (measured: 40 such threads used 0.71 CPU-seconds in 65 s). In `auto` mode all 6 threads start on the one CPU, and the lab's `auto`-mode arms (rows 1, 2, 4 and 5 above) widened all 6. So on a host that skips step 2 (cgroup v1, or an older release), this script leaves the 5 helper threads pinned; that case was not measured.
- In `none` mode all wekanode processes are in the cgroup `/system.slice/weka-agent.service` (measured). An `AllowedCPUs` limit on `system.slice` or on that unit therefore limits the roam set too. This is the §3.1 caution about `system.slice`. `non_datapath_cores` can confine them in this mode (sourced: present at 5.1.42.17, 6.0.0 and 6.0.1, absent at 5.1.0; not tested).
- Apply it again after every mount (measured: a remount gives new processes, pinned again). Apply it again after a wekanode process restart too (by source: the EAL pin is set at each start; not tested).
- The `cgroups_mode` line stays in the file until someone changes it. What a WEKA upgrade or an agent upgrade does with it was not tested.
- Cost of `none` with nothing competing (measured, same day, same layout, runs not interleaved): 644.8-644.9 kIOPS against 641.0-650.5 in `auto`, and QD1 mean 592-594 µs against 594-595 µs. No difference at the 1.5% resolution of that pair.

**Not tested:** `none` with 19 FEs; a roam set across NUMA nodes; a cgroup v1 host; DPDK mode; a persistent client container in `none` mode; a host with other WEKA containers; a WEKA or agent upgrade with `none` set; `non_datapath_cores`; a WEKA release other than 6.0.1 (the scripts are the same file at 4.4.37 and 5.1.42.17, but nothing was run there).

---

## 4. Worked example: 2-socket host, 100G mlx5 on NUMA 0

The host has 2 × 32 physical cores with SMT on. `lscpu` gives:
- node 0: CPUs 0–31, siblings 64–95;
- node 1: CPUs 32–63, siblings 96–127.

The NIC is a ConnectX-6 Dx 100G, `ens1f0np0`, `numa_node=0`, one port, one IP, MTU 9000.

```
NUMA 0 (NIC here)                                   NUMA 1
┌──────────────────────────────────────────────┐   ┌──────────────────────┐
│ 0-1   housekeeping: OS, weka-agent, WEKA mgmt │   │ 32-63, 96-127        │
│       (64-65 siblings: housekeeping)          │   │ application          │
│ 2-9   NIC IRQ cores, 8 channels, RSS 4-tuple  │   │ (bulk of app threads)│
│       (66-73 siblings: idle)                  │   │                      │
│ 10-28 WEKA FE x19  core=10..28                │   │                      │
│       (74-92 siblings: idle)                  │   │                      │
│ 29-31 app threads that issue the most I/O     │   │                      │
│       (93-95 siblings: app)                   │   │                      │
└──────────────────────────────────────────────┘   └──────────────────────┘
```

With this layout, 19 FE + 8 IRQ + 2 housekeeping uses 29 of the 32 cores on node 0. The application lives mostly on node 1, so every I/O hands over across the sockets (application ↔ wekafs driver ↔ FE shared memory). That is the price of putting all 19 FEs next to the NIC. The other option, about 10 FE cores on each node, puts half the network traffic across the socket link instead. §6 has the A/B.

Steps (client unmounted; all on the client host):
1. `mkdir -p ~/udptune-before; ip -d link show ens1f0np0 > ~/udptune-before/link; ethtool -l ens1f0np0 > ~/udptune-before/channels; ethtool -g ens1f0np0 > ~/udptune-before/rings; ethtool -c ens1f0np0 > ~/udptune-before/coalesce; cat /sys/class/net/ens1f0np0/tx_queue_len > ~/udptune-before/txqlen`
2. `ip link set ens1f0np0 mtu 9000`, then `ping -M do -s 8972 <backend-ip>`. Repeat for every backend data IP.
3. `systemctl disable --now irqbalance`
4. `ethtool -L ens1f0np0 combined 8; ip link set dev ens1f0np0 txqueuelen 10000`, then `ethtool -n ens1f0np0 rx-flow-hash udp4`. If the output doesn't list both L4 bytes, run `ethtool -N ens1f0np0 rx-flow-hash udp4 sdfn`. (On the lab's CX-6 Dx it was already `sdfn`.)
5. `./pin_irqs.sh ens1f0np0 2 3 4 5 6 7 8 9` (the §3.2 script).
6. Write `default_smp_affinity`, excluding 10–28 and 74–92:
   ```bash
   cat /proc/irq/default_smp_affinity > ~/udptune-before/default_smp_affinity
   echo ffffffff,e0000003,ffffffff,e0000003 > /proc/irq/default_smp_affinity   # CPUs 0-1,29-65,93-127 for 128 CPUs
   ```
   Recompute the mask for your CPU count. Each comma group is 32 CPUs, the high group first.
7. Install `/etc/sysctl.d/90-weka-udp.conf` (§3.4), then run `sysctl --system`.
8. `cpupower -c 2-28 idle-set -D 10; cpupower -c 2-28 frequency-set -g performance`. The lab used `-D 2` (C1 only) and saw no QD1 difference in the bundle (§7.2). On Xeon 8358, `-D 10` also keeps C1E (4 µs).
9. On cgroup v1 only: set `isolate_cpusets=false` (§3.1), then run `systemctl restart weka-agent`. Then `systemctl set-property --runtime user.slice AllowedCPUs=0-9,29-73,93-127`. This keeps logins and jobs off the FE cores and their siblings; it doesn't keep them off the IRQ cores.
10. Mount:
    ```bash
    mount -t wekafs -o net=udp,mgmt_ip=<client-ip>,$(printf 'core=%d,' {10..28} | sed 's/,$//') <backend>/<fs> /mnt/weka
    ```
11. Verify:
    - `for p in $(pgrep wekanode); do taskset -cp "$p"; done` should show 19 FEs on CPUs 10–28, one each; the mgmt process floats;
    - `ss -uampn | grep -A1 wekanode` should show `rb33554432` on 20 sockets;
    - `ip route get <backend-ip> from <client-ip>` should show `dev ens1f0np0`;
    - `mpstat -P 2-9,10-28 5` under load.

**E810 (ice) differences**
- The same steps apply.
- Read the ring maximum from `ethtool -g` (ice allows up to 8160).
- Drop counters are named differently; `ethtool -S` usually shows `rx_dropped`, plus `rx_dropped.nic`/`rx_discards`-style names depending on the driver version.
- Older ice/i40e builds may hash UDP on L3 only, so the step-4 check matters more.
- Keep `ethtool --set-priv-flags` defaults unless you have a reason to change them.

**Two-port NIC:** put a second IP on port 2, in a different subnet that the backends can reach, and use `mgmt_ip=<ip1>+<ip2>`. That gives 40 sockets and twice the bandwidth (docs). Repeat steps 4–5 per port, with each port's IRQs on its own IRQ cores. The docs also say a UDP client can't use `ha` net mode, though it works with an HA cluster.

---

## 5. How to measure

Run the same workload before and after (for example fio, sequential 1M read, sequential 1M write and random 4k, 60 s each, fixed `numjobs` with the app pinned per §3.1). Capture the counters below during each run. Most are cumulative: take the delta over the run. Never read one sample on its own.

**WEKA side**
- `weka stats --category network --stat UDP_SENDMSG_FAILED_EAGAIN --stat UDP_SENDMSG_PARTIAL_SEND --stat UDP_SENDMSG_FAILED_OTHER --stat DROPPED_LARGE_PACKETS --stat RESENT_DATA_PACKETS --stat TIMELY_RESENDS --per-process --show-internal --process-ids <client pids> --interval 300`
  - The category is `network`.
- `weka stats --category network --stat PORT_RX_PACKETS --stat PORT_TX_PACKETS --stat PORT_RX_BYTES --per-process --show-internal` gives per-port UDP_PORT_n counters.
- `weka stats --category cpu --stat CPU_UTILIZATION --per-process` gives FE busy time, computed as `1 − IDLE_CYCLES/…`. Epoll sleep counts as idle, so this is real work. It doesn't include softirq that the kernel ran on the FE core.
  - **Amended 2026-11-20:** "real work" is WEKA's own count, and it is not what the OS sees. Measured (§8.3): at QD1, WEKA reported 2-3% for the serving FE while that FE's main thread used 98% of its CPU (64.97 s of about 66), polling in user space. So WEKA's figure counts that polling as idle. For what the scheduler and other tenants of the CPU see, use `pidstat -u -t -p <FE pid> 5` or `mpstat -P <FE cpus> 5`.
- `weka stats realtime` shows a live per-process view.
- The WEKA trace may log `#UDP … failed to set #RCVBUF`, `#PORTDEAD`, or `#NET #MTU`.

**OS side**
| Counter | Command | What a rise means |
|---|---|---|
| `UdpRcvbufErrors`, `UdpInErrors` | `nstat -n` before the run, then `nstat -z UdpRcvbufErrors UdpInErrors UdpSndbufErrors UdpInCsumErrors` after it (delta; **not `-a`, which prints absolute counters**) | Socket queue full: the FE isn't draining in time (wake-up latency, CPU contention), or `rb` is capped |
| Per-socket drops | `ss -uampn` → `skmem:(…,d<N>)` | Same as above, pinned to one FE port |
| `UdpSndbufErrors` / WEKA `UDP_SENDMSG_FAILED_EAGAIN` | As above; `tc -s qdisc show dev $IF` (drops, requeues); `ethtool -S $IF \| grep -E 'tx_queue_stopped\|tx[0-9]+_stopped'` | TX backpressure: sndbuf, qdisc or TX ring. **Measured: qdisc drops raise `UdpSndbufErrors` while WEKA's `UDP_SENDMSG_*` stays 0.** The kernel hides `-ENOBUFS` without `IP_RECVERR` (§3.2), so check the OS counter, not only WEKA's |
| `/proc/net/softnet_stat` col 2 (dropped), col 3 (time_squeeze), per CPU, hex | `awk '{print NR-1, strtonum("0x"$2), strtonum("0x"$3)}' /proc/net/softnet_stat` (gawk) | col 3 on IRQ cores: softirq budget too small, or too few IRQ cores; col 2: backlog (RPS) overflow |
| NIC drops | `ethtool -S $IF` and look at `rx_out_of_buffer`, `rx_discards_phy`, `rx_dropped`, `tx_dropped`. Read the full list once, because names vary by driver | `rx_out_of_buffer` (mlx5): RX ring empty, so raise the ring or IRQ capacity; `rx_discards_phy`: NIC/PCIe or pause limits |
| softirq per CPU | `mpstat -P ALL 5` (`%soft`, `%irq`, `%usr`, `%sys`) | IRQ cores near 100% `%soft`: add channels or cores. `%soft` on FE cores: IRQs leaked onto them (irqbalance back, or a new IRQ) |
| Wake-up / C-state | `turbostat --interval 5`; `perf sched latency -C <FE>` (short capture) | Deep C-state residency on FE cores under load, or long wake-up latency: tighten §3.5 |
| FE hotspots | `perf top -C 10` | Time in `copy_user*`/`__skb_datagram_iter` means the FE is copy-bound. The next step is more FE cores (see §6), not OS tuning |

**Reading the result**
- **19 FEs near 100% `CPU_UTILIZATION`, clean OS counters:** FE-bound. OS tuning is done.
- **Resends rising with clean OS counters:** loss on the fabric or late ACKs. To tell them apart, compare `RESENT_DATA_PACKETS` with `DOUBLY_RECEIVED` on the receivers, and do NIC-counter accounting per hop (§7.6). The L6 resend timer is `max(4×rtProp, 300 µs)`, so FE wake-up latency can trigger spurious resends.
- **`DROPPED_LARGE_PACKETS` above 0:** an MTU mismatch on the host.

---

## 6. Gaps: what needs a lab test

**Status after the 2026-10-24 lab** (details in §7):
| Gap | Status |
|---|---|
| 1 IRQ cores vs RFS | **closed (§7.7):** RFS alone has no effect. IRQs on the FE cores with RFS cost −6% IOPS and +16% FE CPU, so separate IRQ cores win |
| 2 IRQ core count | **closed at 50G (§7.7):** 4 = −34% IOPS; 8 = 12. 100G is untested |
| 3 coalescing | **closed (§7.7):** no measurable effect, QD1 included |
| 4 C-state depth | **closed (§7.7):** with `performance`, C1E or C6 enabled made no measurable difference, QD1 included |
| 5 NUMA | FE placement measured (§7.2). App socket: no effect with 6 fio CPUs (§7.7) |
| 6 isolcpus/nohz_full | open (skipped: low expected gain). Amended 2026-11-20: not run in the November lab either (gaps 13 and 9 were chosen) |
| 7 MTU 1500 | open. Amended 2026-11-20: not run in the November lab either (same choice) |
| 8 hugepages | **closed:** 704 × 2 MiB = 1,408 MiB per FE, allocated on each FE's node. The pool isn't shrunk on unmount (§7.4) |
| 9 persistent client | open. **Amended 2026-11-20: measured without `--dedicate` (2026-11-11, §8.7).** A persistent UDP client container behaved as the stateless mount does: same pins, same cores protector, `Mask Interrupts false`, governor `UNCONFIGURED`, NUMA balancing left on, and performance inside the baseline band. `--dedicate` was not tested, so the gap is not closed |
| 10 past 19 cores | out of scope (19 is the UDP mount maximum) |
| 11 FE pin under the v1 sweep | **closed:** FEs live in `/system` and keep their pins; an app cpuset is widened (§7.5) |
| 12 `ionode_scheduling` | out of scope (R&D override) |
| 13 busy_poll/THP | open. **Amended 2026-11-20: closed for this hardware (2026-11-11, §8.6).** `busy_read`/`busy_poll` 50 and THP `always` were both inside the noise band on every profile. THP on a fragmented or nearly full host, and `defrag=always`, were not tested |
| 14 sign-off | mlx5 only; no E810 exists on OCI. NIC firmware left stock (`NicPciSettingsMisconfigured`) |
| 15 frontend roaming (added 2026-11-20) | **measured in part (§3.7, §8.4, §8.5).** Open: `cgroups_mode=none` with 19 FEs; the resend rate of widened FEs at 19 FEs (2.5× in one pair, not repeated); a roam set that crosses NUMA nodes; cgroup v1; a persistent client in `none` mode; an upgrade with `none` set; WEKA R&D's view (not asked) |

The original gap list follows.

1. **IRQ cores vs RFS co-location.** §3.2 chose separate IRQ cores. A/B `rps_sock_flow_entries=32768` plus `rps_flow_cnt=4096` per queue, measuring throughput, p99 latency and FE `CPU_UTILIZATION`.
2. **Number of IRQ cores:** 6 vs 8 vs 12 at 100G, with 4k random and 1M sequential.
3. **Coalescing:** adaptive vs `rx-usecs 8/16/32`. FEs sleep at once when idle, so the latency gain may be large at low queue depth and zero at high.
4. **C-state depth:** `-D 10` vs `-D 2` vs BIOS C1 only, and their interaction with the 20 ms `sched_yield`.
5. **NUMA:** all 19 FEs on the NIC node (§4) vs a 10/9 split vs the automatic placement. Also the application on the same socket vs the remote one.
6. **`isolcpus`/`nohz_full`/`rcu_nocbs`.** I haven't confirmed whether the automatic core picker skips isolated CPUs; it doesn't matter with explicit `core=`. Whether `nohz_full` helps an FE that sleeps and yields is unknown.
7. **MTU 1500 links.** A minimum link MTU of 1408 exists, but I didn't trace whether L6 negotiates a smaller packet size per peer or just drops. Don't run UDP mode at 1500 until this is tested.
8. **Hugepage size per UDP FE,** and the free-memory need on one node with 19 FEs.
9. **The persistent-client path** (`weka local setup container --net udp [--dedicate]`). I didn't trace whether `mask_interrupts`, the governor and NUMA balancing apply there. Check with `weka local resources` (the "Mask Interrupts" row).
10. **Past 19 cores:** a second client container on the same host, as the multiple-client-containers feature implies, or DPDK. Not scoped here.
11. **FE pin under the v1 sweep.** The FE processes should sit in a `weka*` cpuset, which the sweep skips. With UDP-mode cores undedicated, I didn't confirm which cpuset they are in, so check `taskset -cp` on an FE after 10 minutes on a v1 host with `isolate_cpusets=yes`.
12. **`ionode_scheduling` override** (SCHED_OTHER with nice −5 for UDP FEs): an R&D override, so no field change without R&D.
13. **`busy_poll`** and **THP**: no WEKA guidance found; low priority.
14. **Sign-off:** a measured version of the §1 table needs one lab host with an mlx5 and an E810 NIC, a fixed fio profile, and the §5 capture before and after each row.

---

## 7. Lab results (OCI, 2026-10-24, WEKA 6.0.1)

### 7.1 Setup and method
- **Hosts.** The client is a BM.Standard3.64, 2× Xeon 8358 (32 cores per socket, SMT), node 0 = CPUs 0-31 + 64-95. It has a ConnectX-6 Dx 2×50G on node 0, fw 22.47.1088. Port 0 carries all WEKA traffic; port 1 stayed idle. Ubuntu 22.04, kernel 6.8.0-1060-oracle. The backends are VM.DenseIO.E5.Flex, 16 OCPU, mlx5 VFs via VFIO, 4+2: 6 until 06:51Z, then 8.
- **Workload.**  libaio, direct, 60 s plus a 5 s ramp, with the measured minute aligned to one WEKA stats minute. The profiles are:
  - seqread: 1M, 16 jobs × QD16;
  - seqwrite: 1M, 64 jobs × QD16;
  - randread4k: 32 jobs × QD32;
  - lat4k: QD1.
- **Captured per run.** nstat, softnet, `ethtool -S`, qdisc, mpstat, and WEKA network and CPU stats per process.
- **Noise.** T2 vs T3 (same state, back to back): randread 1,016.5 vs 1,019.4 kIOPS, and seqread/seqwrite/QD1 within 0.3%. Every variant is one sample.
- **Backend count.** B1 (6 backends) vs B1r (8): randread −3.6%, seqwrite, QD1 and FE CPU within 1%. So client-side comparisons across the 06:51Z expansion hold to about 4%.

### 7.2 Main comparison (all on 8 backends)
| Variant | FE cores | fio CPUs | OS state | randread4k kIOPS (mean µs, p99 µs) | QD1 mean µs | seqwrite GiB/s | Σ FE CPU % at seqread 5.53 GiB/s |
|---|---|---|---|---|---|---|---|
| B0r (stock) | automatic: 1-10 + 32-40 | 0-127 | stock | 802.5 (1,264, 3,195) | 635 | 3.58 | 558 |
| B1u | 10-28 (node 0) | 0-127 | stock | 714.9 (1,422, 3,588) | 740 | 2.71 | 642 |
| B1r | 10-28 | 29-63 | stock | 895.5 (1,130, 2,277) | 656 | 2.77 | 855 |
| **T** (T2/T3 mean) | 10-28 | 29-63 | §4: irqbalance off, 8 channels on IRQ cores 2-9, `performance`, C1 only, numa_balancing 0, txqueuelen 10000 | **1,018 (1,000, ~1,600)** | 633 | 3.67 | **418** |

**Measured:**
- **Full tuning vs stock (B0r → T):**
  - randread +27% IOPS, mean −21%, p99 −50%;
  - FE CPU at the read cap −25%;
  - seqwrite +2%;
  - QD1 unchanged.
- **Core placement alone (B0r → B1u) made everything worse:** IOPS −11%, seqwrite −24%, QD1 +16%. In the stock state, irqbalance put all NIC IRQs on node 0 (state readback: `irq_cpus` 0-31, 64-95), so the IRQs share the FE cores. That this is the cause is a HYPOTHESIS, consistent with FE `%soft` 10.3 vs 8.4.
- **Pinning the app off the FE cores (B1u → B1r):** IOPS +25%, QD1 mean −11%.
  - **Amended 2026-11-20:** this compares pinned-on with pinned-off, not unpinned with pinned. B1u's fio options were `cpus_allowed=0-127` with `cpus_allowed_policy=split`, which put the 32 jobs one per CPU on CPUs 0-31, on top of the FEs ( mpstat idle 1% on CPUs 10-28). No October run had an application the scheduler was free to place. §8.4 has that arm: it cost nothing on a host with idle CPUs.
- **The OS bundle on top (B1r → T):** IOPS +14%, FE CPU at the read cap −51%, seqwrite +32%.

**6-backend runs (B0/B1/T1) for reference:** same direction. B1 → T1, which changes only the OS knobs: FE CPU at the read cap 846 → 417, FE `%soft` 7.7 → 0.0, randread +5%.

### 7.3 Silent TX drops with 8 channels (seqwrite, state T)
| Variant | GiB/s | qdisc drops | UdpSndbufErrors | client resends/s |
|---|---|---|---|---|
| TXa: T, txqueuelen 1000, TX ring 1024 | 3.64 | 376,920 | 188,439 | 27,174 |
| TXq: txqueuelen 10000 | 3.65 | **0** | **0** | 27,767 |
| TXr: TX ring 4096 | 3.67 | 786,438 | 393,195 | 26,014 |
| TXqr: both | 3.67 | 0 | 0 | 19,275 |

**Measured:**
- The drops were on the TX queues that carry 3 FEs. mlx5 XPS maps CPU n to tx-(n mod 8). In T1, tx2 logged 1,436 queue stops.
- WEKA's `UDP_SENDMSG_FAILED_*` stayed 0 throughout. That's sourced: WEKA sets no `IP_RECVERR`, and Linux v6.8 `udp_send_skb()` turns `-ENOBUFS` into success.
- **Throughput didn't change at this load.** The remaining resends come from the lab network (§7.6). So `txqueuelen` removes a hidden loss source; it isn't a throughput fix here.

### 7.4 Other measured facts
- **Automatic core pick:** twice, on 6.0.1, `num_cores=19` gave slots 1,3,…,19 → CPUs 1-10 (node 0) and slots 2,…,18 → CPUs 32-40 (node 1). The MGMT slot floats on 0-127. This confirms the §2.1 source reading.
- **Sequential read is capped by the port:** 5.53 GiB/s ≈ 47.5 Gb/s on a 50G port in every variant. OS tuning shows up as FE CPU saved (558 → 418 %), not as throughput. A throughput test would need both ports plus bigger backends.
- **QD1 latency is bimodal:** about 500-580 µs and about 740 µs, and p50 flips between the two run to run. Use the mean and p90/p99: the mean was 621-740 µs across all variants.
- **fio jobs vs FEs:** 16 seqwrite jobs kept only 10 of the 19 FEs busy (B0: 2.51 GiB/s, the 10 at 99%). 64 jobs used 17 FEs, and slots 10 and 16 stayed at about 1% in every seqwrite run. That this comes from how WEKA maps files or threads to FEs is a HYPOTHESIS. Use at least 3-4× as many jobs as FEs when testing.
- **Hugepages:** 704 × 2 MiB = 1,408 MiB per FE, allocated on each FE's node (mount log: node 0 7,040 for 10 FEs, node 1 6,336 for 9). The pool isn't shrunk on unmount: after the 10/9 remount, node 0 still held 13,376 pages from the earlier 19-on-node-0 mount. Size free memory for the largest layout you'll mount.
- **Mount time:** first mount 2 m 55 s; later remounts 33-47 s.
- **FE CPU in UDP mode:** the FEs don't spin. QD1 used about 1% per FE, consistent with §2.2 (epoll sleep).
  - **Corrected 2026-11-20: this line is wrong for the FE that serves the IO.** The "about 1%" was WEKA's `CPU_UTILIZATION`. The OS view of the same October runs: the serving FE's CPU was 97.6% usr while WEKA reported 2.7% for that process; 17 of the other 18 FE CPUs were 96.6-97.1% idle and one was 87% idle (one FE CPU was 99% busy in each of the five QD1 runs). The November lab showed why (§8.3): the serving FE's main thread polls in user space while an IO is in flight. An FE with no IO at all does sleep (3.3% of its CPU in state T).

### 7.5 Row 11: the cgroup v1 cpuset sweep (`systemd.unified_cgroup_hierarchy=0`)
| Leg | `/udpapp` cpuset (cpus 29-31) | its task | `taskset 29-31` task in `/system` | 19 FEs (in `/system`, `/weka-client` has no CPUs) |
|---|---|---|---|---|
| `isolate_cpusets=true` (default) | **29-31 → 0-127 at the first sweep** (08:14Z, ~5 min after agent start) | **affinity reset 29-31 → 0-127** | kept 29-31 | each kept its one CPU |
| `isolate_cpusets=false` + agent restart | kept 29-31 for 12 min (no change in 13 samples) | kept 29-31 | kept 29-31 | each kept its one CPU; FEs in the root cpuset `/`, not `/system` |

### 7.6 Lab-specific effects (properties of this OCI lab, not of client tuning)
- **randwrite4k: OCI per-VNIC ingress throttling.**
  - VERIFIED: OCI `VnicIngressDropsThrottle` counted 38.8M drops on 2 of 6 backends in the 06:00-06:12Z window before the expansion, and 25.6M on 3 of 8 in the 07:12-07:13Z minute after it.
  - The throttled hosts moved from run to run, so it isn't host placement.
  - HYPOTHESIS, strongly supported: the 16 Gbps per-VM cap, since peak ingress on the throttled hosts was 16-20 Gbps.
  - Client resends were about 8% of TX. Treat randwrite numbers here as relative only.
- **seqwrite: about 0.8% loss between the client and backend NICs.**
  - VERIFIED by NIC counters: the client sent 102.77M on the wire (≥ kernel UDP out of 102.73M, with qdisc drops 0), and the backend NIC rx sum accounts for about 0.9M less.
  - VERIFIED: no host-side drop counter rose, and OCI throttle was 0.
  - HYPOTHESIS: the backends deliver everything their NICs receive to WEKA. It can't be proven at WEKA's 60 s stats resolution.
  - HYPOTHESIS: the loss is in OCI's SmartNIC/fabric path.
  - Two causes of client seqwrite resends were seen, and `tc -s qdisc show dev $IF` (`dropped`) over the run separates them:
    - client qdisc drops (§7.3: TXa/TXr, `dropped` above 0);
    - this NIC-to-NIC loss.
  - In the HOP run (txqueuelen 10000, qdisc `dropped` 0, VERIFIED), the ~0.9M NIC-to-NIC loss is the same size as the ~1.2M resends. HYPOTHESIS: with qdisc drops at 0, this loss is the main cause of the remaining 1.2-1.8%. The gap between 0.9M and 1.2M isn't explained; late-ACK resends are one candidate.
- **Known gap:** WEKA alert `NicPciSettingsMisconfigured` on port 0 of the client (ADVANCED_PCI_SETTINGS and PCI_WR_ORDERING not 1). Left as is. All results are on stock OCI NIC firmware.

### 7.7 Second pass: one knob at a time from T (19:42-21:30Z)
After the row 11 run, the client was rebooted back to cgroup v2 and remounted with `core=10..28`. Each variant starts from state T with txqueuelen 10000 and changes one thing. Each knob was read back after it was set. Each row is one run (measured); the noise band is <1% (T2/T3/T4).

**Base check:** T4 = 1,025.0k randread IOPS, against 1,016.5k and 1,019.4k for T2 and T3. seqread was 5.53 GiB/s and QD1 mean 631 µs. The baseline didn't move outside the band.

| Variant (the one change from T) | randread kIOPS (vs T4) | rr mean / p99 µs | WEKA FE CPU sum at rr | QD1 mean µs | Reading |
|---|---|---|---|---|---|
| T4 (base) | 1,025.0 | 993 / 1,450 | 1,401% | 631 | — |
| R1a: RFS on, IRQs still on 2-9 | 1,022.4 (−0.3%) | 996 / 1,450 | 1,401% | 630 | no effect |
| R1b: RFS on + 19 channels with IRQs on the FE cores 10-28 | 963.2 (**−6.0%**) | 1,057 / 1,630 | 1,621% (**+16%**) | 631 | **Separate IRQ cores win.** The FEs pick up 22% softirq |
| R2a: 4 channels, IRQs 2-5 | 672.9 (**−34%**) | 1,516 / 4,489 | 1,002% | 630 | **Too few.** Resends went from 117/s to 92,619/s |
| R2c: 12 channels, IRQs 2-9 + 64-67 | 1,024.1 (−0.1%) | 994 / 1,417 | 1,408% | 630 | same as 8. **8 IRQ cores are enough for 50G at ~1M IOPS** |
| R3_8: adaptive-rx off (readback rx-usecs **3**, not the 8 requested) | 1,041.0 (+1.6%) | 978 / 1,548 | 1,494% | 629 | just outside the band; p99 worse |
| R3_16: adaptive off, rx-usecs 16 | 1,019.1 (−0.6%) | 999 / 1,466 | 1,421% | 628 | no effect |
| R3_32: adaptive off, rx-usecs 32 | 1,022.4 (−0.3%) | 996 / 1,466 | 1,413% | 630 | no effect |
| R4_10: C1E enabled (readback C1E:0, C6:1) | 1,020.8 (−0.4%) | 997 / 1,450 | 1,402% | 630 | no effect |
| R4_all: C1E and C6 enabled | 1,017.3 (−0.8%) | 1,000 / 1,466 | 1,419% | 631 | no effect, QD1 included |
| R5n0: fio on 6 node-0 CPUs (29-31, 93-95) | 918.1 | 1,109 / 1,679 | 1,277% | 629 | compare with R5n1 only (fio has 6 CPUs, not 35) |
| R5n1: fio on 6 node-1 CPUs (32-34, 96-98) | 914.1 (−0.4% vs R5n0) | 1,114 / 1,614 | 1,238% | 627 | no socket effect at this load |

seqread was 5.53 GiB/s in every variant (the port cap). seqwrite was 3.66-3.67 GiB/s in every variant, with resends of 16-21k/s (the OCI loss in §7.6).

**What this changes in the guide:**
- Row 2 holds: IRQs on separate cores, 8 of them at 50G. Putting the IRQs on the FE cores with RFS costs 6% IOPS and 16% FE CPU.
- Gap 3: coalescing has no measurable effect here, QD1 included. The predicted low-QD gain didn't show.
- Gap 4: C-state depth has no measurable effect with the `performance` governor, QD1 included. Row 5's C-state half is optional on this hardware; the governor half wasn't split out.
- Gap 5: the application's socket made no difference with fio limited to 6 CPUs (HYPOTHESIS: fio was the limit, which hides any socket effect).

### 7.8 Not tested
Gaps 6 (isolcpus), 7 (MTU 1500), 9 (persistent client) and 13 (busy_poll, THP), plus the two-port mount, were scripted but stopped before they ran. The lab time ended. No E810 (none on OCI). Amended 2026-11-20: gaps 9 and 13 were run on 2026-11-11 (§8.6, §8.7); gaps 6 and 7 and the two-port mount are still not tested.
- Source for gap 7 (sourced, untested): peers start at the 4056 MTU, and switch a peer to the minimum link MTU of 1408 after a run of small-sync-only ACKs. So a 1500 link should run at 1408-byte packets rather than fail.
- Source for two-port (sourced, untested): `mgmt_ip=<ip1>+<ip2>`. A second subnet needs policy routing (`ip rule from <ip2> table N`) or the kernel sends from `<ip2>` out of port 1.
- Source for gap 6 (sourced, untested): the automatic core pick uses the root/system cpuset's `cpus.effective`. Whether isolated CPUs appear there was not checked.

---

## 8. Lab results, November (OCI, 2026-11-10 to 11-12, WEKA 6.0.1; added 2026-11-20)

This section is the short form of three lab rounds (2026-11-10, 11-11 and 11-12).

### 8.1 Setup and method
- **Hosts.** A new build of the October shapes: the client (BM.Standard3.64), 8 backends (VM.DenseIO.E5.Flex), WEKA 6.0.1, kernel 6.8, cgroup v2.
- **Baseline against October** (state T, 19 FEs; October T2 and T3 in brackets): seqread 5.52 GiB/s (5.53, 5.54), seqwrite 3.67 (3.67, 3.66), randread 1,022.1 kIOPS (1,016.5, 1,019.4). QD1 read mean was 591 µs against 633 µs in October, so QD1 figures are compared inside this lab only.
- **Layouts.**
  - L8: mount `core=10..17`, roam set 10-28 (11 idle whole cores to move to), busy loops on CPUs 10-13, fio pinned on 32-63 unless noted.
  - L19: mount `core=10..28` (the §4 layout), roam set 10-31,74-95 (mostly sibling threads), busy loops on CPUs 10-19.
- **Arms.** P = pinned as mounted; W = widened to the roam set. 0 = nothing competing; h = one busy loop pinned on each listed CPU; a = fio with no CPU options, placed by the scheduler; f = 15 busy loops free to run anywhere on the roam set.
- **Workload.** randread4k (32 jobs × QD32) and lat4k (QD1) from §7.1, in state T with `txqueuelen 10000`. Writes were left out because of the OCI ingress throttle (§7.6).
- **Noise.** Two same-state runs were 2.3% apart at L8 (671.4, 656.2 kIOPS) and 1.5% apart on 11-12 (641.0, 650.5). Three L19 baselines spanned 2.4% (998.4 to 1,022.1). The same L8 arm was about 3% lower on 11-12 than on 11-10 (mean 645.8 against 663.8); the cause was not looked for.
- **How the widen was kept in §8.4.** A lab-only step stopped the cores protector: an empty `PROTECTOR_ENABLED=` in the container's `weka_cores_protector.conf`, then a kill of the script so that supervisord restarted it. The file is lost at each remount of a stateless client. It is not a WEKA-supported setting and it is not a field recommendation. §8.5 replaced it with `cgroups_mode=none`.

### 8.2 The pin, and what puts it back
| Finding | Evidence |
|---|---|
| VERIFIED: each FE has 6 threads and all 6 are on the FE's one CPU. The management process's 4 threads are on 0-127 | 118 thread rows: 19 × 6 + 4 |
| VERIFIED: on cgroup v2 each FE's main thread is in `/weka-client`, a threaded cgroup with an empty `cpuset.cpus` (effective 0-127). The cgroup does not confine the FE; the affinity mask alone does | the cgroup files of each FE, same run |
| VERIFIED: every FE process starts in `/container/weka/client`. On its first pass, 60 s after the container starts, the protector moves the process into `/weka-client`, moves the helper threads to the root cgroup and sets the main thread's affinity | 19 `scope mismatch` lines per container start ( the same block after each stateless remount) |
| VERIFIED: an outside widen was undone for the main thread on the protector's next pass. Three widens at different seconds of the minute were undone at 22:53:12.9, 22:54:13.6 and 22:55:14.3: a 60.7 s cycle, 28 to 53 s after the widen. The helper threads stayed wide |  the protector log has one `affinity mismatch` line per slot at those times |
| VERIFIED, source: every 60 s the script reads `/tmp/slot.cores`, compares each slot's `taskset -cp <pid>` with the slot's core and, on a mismatch, runs `taskset -cp <core> <pid>` for the main thread. It acts only when `/mnt/unified` is a cgroup2 mount | the script, and its supervisord entry |
| VERIFIED: the hugepage mappings of every FE are all on node 0 (1,404 mapping lines each), before and after a widen | |

### 8.3 A frontend with IO in flight uses a whole CPU
| Run (65 s, state T) | IOs | Busiest wekanode thread | Its CPU s (of about 66) | WEKA `CPU_UTILIZATION` for it |
|---|---|---|---|---|
| No IO (two runs) | 0 | management main thread | 2.9 | 0 |
| QD1 read | 101,039 | first FE (slot 1), main thread | 64.97 | 2 |
| QD1 write (two runs, two other files) | 93,114 | sixth FE (slot 6), main thread | 64.95, 64.97 | 3 |
| QD1 read with a 2 ms pause between IOs | 24,376 | first FE, main thread | 29.54 | 1 |
| QD1 read with a 20 ms pause | 3,142 | first FE, main thread | 5.46 | 0 |
- VERIFIED: the CPU is used by the main thread of the FE that serves the IO. The other 5 threads of every FE total 0.0-0.1 s, and no FE used more than 2.2 s in the runs with no IO.
- VERIFIED: the thread polls in user space. `perf`: 97% of its samples are in wekanode itself and 3% in the kernel; the top entries are the driver poller, the reactor's idle callbacks and the network pump.
- VERIFIED: the cost is about 1.05 ms of CPU for one isolated IO whose latency is 0.61-0.63 ms. HYPOTHESIS for the 0.4 ms beyond the IO: (a) the thread keeps polling for a fixed time after the last request, or (b) each wake-up and return to sleep has a fixed cost. Check: a per-IO timeline of that thread at 20 ms spacing; not done.
- VERIFIED: an FE with no IO wakes about 1,040 times a second and uses 3.3% of its CPU in state T (6.8% on the stock OS).
- Sourced: at QD1 a read goes to the first FE that has no read in flight, and the scan starts at index 0, so light read load lands on the first FE every time. A write goes to the file's own FE.
- **For roaming:** under continuous light IO the serving FE looks CPU-bound to the scheduler. Anything that shares its CPU takes time from a thread that does not sleep.

### 8.4 Roaming with the re-pin switched off (lab-only switch, `auto` mode)
**L8** (8 FEs on 10-17, widened to 10-28). One run per cell; where two values are given, they are two runs.

| Competing load | Pinned: randread kIOPS / p99 µs | Widened: randread kIOPS / p99 µs | Pinned: QD1 mean / p99 µs | Widened: QD1 mean / p99 µs |
|---|---|---|---|---|
| none (P0, W0) | 671.4, 656.2 / 2,212, 2,277 | 667.1 / 2,245 | 597, 594 / 995, 758 | 599 / 995 |
| busy loop pinned on CPUs 10-13 (Ph, Wh) | 493.9, 479.9 / 7,373, 7,569 | 665.6, 661.7 / 2,245, 2,277 | 757, 757 / 3,654, 3,588 | 601, 599 / 995, 995 |
| fio left to the scheduler (Pa, Wa) | 668.1, 660.3 / 2,245, 2,343 | 661.1 / 2,310 | 596, 599 / 995, 995 | 600 / 995 |
| 15 busy loops free on 10-28 (Pf, Wf) | 582.3 / 5,079 | 579.5 / 5,210 | 596 | 599 |
- VERIFIED, moved: in Wh no FE main thread was sampled on CPUs 10-13 (0 of 520 one-second samples per profile; the control W0 had 140 and 130 of 520 there). They were off those CPUs at the first sample, 42 s after the busy loops started, and stayed inside 10-28.
- VERIFIED, helped: with the busy loops, widened FEs were inside the no-load band; pinned FEs lost 26% of IOPS and p99 tripled. Each contended pinned FE got 47% of its CPU.
- VERIFIED, no IOPS or latency cost with nothing competing: W0 is inside the P0 band.
- VERIFIED, no gain when the roam set has no idle CPU (Pf, Wf): both were about 13% under no load.
- VERIFIED: an application that the scheduler places freely cost pinned FEs nothing (Pa against P0). This host had about 100 idle CPUs for 32 fio jobs; a host with few idle CPUs is not covered by this arm.
- Resends in randread (client `RESENT_DATA_PACKETS`, packets per second): nothing competing W0 177 against P0 176 and 122; busy loops Wh 252 and 287 against Ph 1,731 and 1,829. `UdpSndbufErrors`, qdisc drops and softnet drops were 0 in the W arms.

**L19** (19 FEs on 10-28, widened to 10-31,74-95, busy loops on 10-19). One run per arm.

| Arm | randread kIOPS | p99 µs | QD1 mean / p99 µs | Resends, randread, packets/s |
|---|---|---|---|---|
| P0 | 1,024.0 | 1,630 | 597 / 995 | 1,654 |
| W0 | 1,033.6 | 1,548 | 597 / 995 | 4,086 |
| Ph | 800.8 | 5,734 | 689 / 3,260 | 6,015 |
| Wh | 897.7 | 1,909 | 606 / 995 | 392 |
- VERIFIED, moved: in Wh, 0 of 1,216 FE samples per profile were on the busy CPUs 10-19. In randread, 686 were on whole CPUs 20-31 and 530 on sibling threads 74-95.
- VERIFIED, helped in part: widening gave back 97 of the 223 kIOPS that the busy loops cost (43%) and nearly all of the tail. HYPOTHESIS for the IOPS not recovered: (a) FEs sharing a core with a busy sibling thread (29 busy threads on the 22 cores of the roam set); (b) more FEs sending through the same TX queue once they leave their own CPUs; (c) one run per arm. Check: a Wh arm with the busy loops on CPUs whose siblings are outside the roam set, and a repeat; not run.
- VERIFIED: no IOPS or latency cost with nothing competing (W0 against P0). **Resends are not cleared:** W0's rate is 2.5× P0's in this one pair. HYPOTHESIS: (a) run-to-run variation; (b) widened FEs change CPU, send through other TX queues, and reorder or delay packets. Check: three P0 and three W0 runs at L19; not run.

### 8.5 `cgroups_mode=none` (2026-11-12; L8)
| Check | `auto` | `none` |
|---|---|---|
| cgroup or cpuset lines in the container's `/proc/mounts` | 1 of 58 (`/mnt/unified cgroup2`) | 0 of 58 |
| wekanode start lines for the FE slots (`output.log`) | 19 of 19 "with core N" | 8 of 8 "without assigned core" |
| FE thread masks at mount + 20 s and after 130 s | all 6 threads on the slot's CPU | main thread on the slot's CPU, 5 helper threads on 0-127 |
| cgroup of the wekanode processes | `/weka-client` after the protector's first pass | all 9 in `/system.slice/weka-agent.service` |
| Protector log since the container start | 305 lines: 19 scope mismatches, 19 set-affinity | 1 line (its start line) in 28 minutes and four fio runs |
| Outside widen of the main threads | 0 of 8 still widened after 37 s (same day) | 8 of 8 still widened after 150 s, and after a five-minute run |
| `NoCgroupsConfigured` alert | absent (5 alert rows) | present (6 rows): WARNING "No cgroups configured warnings", raised within 20 s of the container start; absent again after the undo and remount |
- VERIFIED: **`none` removes the re-pin, not the pin.** The main thread still starts on its one CPU (the EAL `-l<core>`), and in the pinned arms every main-thread sample was on the mount CPU (520 of 520 per profile). The widen of §3.7 step 3 is still needed after every mount; nothing undid it here.
- Why the alert cleared was not separated: the alert named the client's host id, and each stateless mount registers a new host id. Candidates: the mode change, or the departure of that host entry.

| Arm (L8, state T, fio on 32-63) | randread kIOPS | p99 µs | QD1 mean / p99 µs | Resends, randread, packets/s |
|---|---|---|---|---|
| `none` P0, two runs | 644.9, 644.8 | 2,277, 2,212 | 592 / 758, 594 / 995 | 175, 84 |
| `auto` P0, same day, two runs | 641.0, 650.5 | 2,376, 2,310 | 595 / 995, 594 / 995 | 183, 179 |
| `none` Ph (busy loops pinned on 10-13) | 469.7 | 8,094 | 741 / 3,523 | 1,404 |
| `none` Wh (main threads widened to 10-28, same busy loops) | 637.1 | 2,376 | 596 / 995 | 308 |
- VERIFIED: no difference between the modes with nothing competing, at the 1.5% resolution of the same-day `auto` pair. The runs were two `none` and then two `auto`, not interleaved.
- VERIFIED, moved and helped: in Wh, 0 of 520 main-thread samples per profile were on CPUs 10-13 and 0 were outside 10-28. Wh was 1.2% under the `none` P0 runs, against 469.7 pinned. This is the same picture as §8.4 at that day's level.
- Undo, VERIFIED: with the line back to `auto`, `service.conf` was byte-identical to the copy taken before (`cmp` rc 0), and after the agent restart and a mount the status line, the container's cgroup2 mount, the protector's first pass (19 scope mismatches) and the alert list (5 rows) were as before.

### 8.6 Gap 13: busy_poll and THP (2026-11-11; L19, state T, fio on 29-63; one run per arm)
| Variant | seqread GiB/s | seqwrite GiB/s | randread kIOPS / p99 µs | QD1 mean / p99 µs |
|---|---|---|---|---|
| Baseline T5a (11-10) | 5.52 | 3.67 | 1,022.1 / 1,499 | 591 / 758 |
| Baseline T4 | 5.52 | 3.67 | 1,017.6 / 1,483 | 592 / 750 |
| Baseline T4b, after a remount | 5.52 | 3.65 | 998.4 / 1,761 | 611 / 1,004 |
| `net.core.busy_read=50`, `busy_poll=50` | 5.52 | 3.66 | 1,014.7 / 1,679 | 594 / 995 |
| THP `always`, FEs started under it | 5.52 | 3.64 | 1,014.5 / 1,516 | 592 / 758 |
- VERIFIED: both variants are inside the band of the three baselines on every profile.
- VERIFIED, busy_poll: the knob reaches the FEs, but rarely. `napi_busy_loop` was entered 0 times in 5 s with the knob off and 3,181 times with it on, about 32 a second per idle FE, against about 1,070 sleeps a second: about 3% of sleeps. HYPOTHESIS why loaded profiles show nothing either: (a) an FE with IO in flight polls in user space and seldom sleeps (§8.3); (b) the 3% share holds under load too. Check: count `napi_busy_loop` entries during a fio run with the knob on; not run.
- VERIFIED, THP: under `madvise` no wekanode process has anonymous huge pages (0 of 20). Under `always`, after a remount, each of the 20 has 248-274 MiB (4.9 GiB in all). The hugetlbfs pool is separate and unchanged. `compact_stall` and `thp_fault_fallback` stayed 0, so the case where `always` is known to cost (compaction stalls on a fragmented or nearly full host) was not exercised. `defrag` was `madvise`; `defrag=always` was not tested.
- Undo, VERIFIED in the job log: `sysctl -w net.core.busy_read=0 net.core.busy_poll=0`; `echo madvise > /sys/kernel/mm/transparent_hugepage/enabled` and a remount.

### 8.7 Gap 9: a persistent UDP client container (2026-11-11; no `--dedicate`)
Created on the stock host with `weka local setup container --name client --client --net udp --cores 19 --only-frontend-cores --core-ids 10 … --core-ids 28 --management-ips <client IP> --join-ips <backend IP>`, then `mount -t wekafs -o container_name=client <fs> /mnt/weka`. The mount source is the filesystem name alone; the stateless form `<backend>/<fs>` fails with "Permission denied to filesystem".

| Question | Persistent container | Stateless mount, same host |
|---|---|---|
| Does WEKA mask interrupts, set the governor or turn off NUMA balancing? | No: `Mask Interrupts false`, `Disable Numa Balancing false`, `Set CPU Governors UNCONFIGURED`. On the host the governor stayed `powersave`, `numa_balancing` stayed 1, irqbalance stayed active | the same three values |
| FE placement | 19 FEs, 6 threads each, all on the FE's one CPU; hugepage mappings all on node 0 | the same |
| Cores protector | running; a widen of all 19 FEs was undone 32.8-34.5 s later | the same script |
| randread kIOPS / p99 µs, two runs | 1,018.3 / 1,630 and 1,016.1 / 1,745 | baselines 998.4-1,022.1 / 1,483-1,761 |
| QD1 mean / p99 µs, two runs | 594 / 995 and 594 / 995 | 591-611 / 750-1,004 |
- VERIFIED: for these runs the persistent container behaves as the stateless mount does. As far as these runs show, nothing in this guide needs a different setting for it. `--dedicate` was not tested, so gap 9 is measured without it, not closed.
- Undo, VERIFIED: `umount`, `weka local stop client`, `weka local rm -f client`, then the stateless mount. The cluster then listed one container for the client and no leftover entry.

### 8.8 Not tested, and open
- Roaming: see the list at the end of §3.7 and gap row 15 in §6.
- The 0.4 ms of CPU beyond each isolated IO (§8.3), and which source constant sets it: not traced.
- Why the busy-poll loop runs on only 3% of an idle FE's sleeps: not traced.
- Why the L8 level was about 3% lower on 11-12 than on 11-10: not looked for.
- Gaps 6 (isolcpus/nohz_full) and 7 (MTU 1500): not run.
- WEKA R&D has not been asked about `cgroups_mode=none` on clients, about the outside widen, or about the user-space polling of §8.3.
