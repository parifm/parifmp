# Pinning a WEKA Operator client to cores on a specific NUMA node

Scope: how to configure the WEKA Operator and the node beneath it so a WEKA client runs on a
chosen set of cores on one NUMA node, on 4k-page and 64k-page kernels, and how to keep other
pods and OS processes off those cores on both hyper-threaded and non-hyper-threaded hosts.

Personal notes, not WEKA documentation. Applies to Operator v1.16.1. The CPU configuration is
identical on 4k and 64k kernels; the differences are all in hugepages.

**Read WEKA's own documentation first.** `weka/weka-operator` is a public repo and ships
`doc/operator/concepts/numa-alignment.md` (205 lines) and `cpu-policy.md`, which are the
authoritative reference. This guide is a companion: what it adds is the 4k-vs-64k page-size
material the official doc does not cover, the verified resource formulas, the silent traps, and
lab-measured behaviour. Where the two disagree, the official doc wins.

### The short version

Since **v1.15.5** the supported way to place a WEKA container on a chosen NUMA node is three
things together:

1. `cpuPolicy: auto` — leave it alone. WEKA's own guidance is explicit: "unless advised by Weka
   personal, avoid using any other policy rather then default `auto`."
2. `spec.numa: {single: true, region: N}` on the `WekaClient`, or `spec.numa` / `spec.roleNuma`
   on the `WekaCluster`. **Both `single` and `region` are required** — either alone silently does
   nothing.
3. kubelet configured per Step 3: `cpuManagerPolicy: static`, `topologyManagerPolicy: restricted`,
   `memoryManagerPolicy: Static`, and the device plugin enabled in the chart.

Everything else in this guide is either a prerequisite for that, a way to verify it, a trap that
makes it fail silently, or a fallback for versions before v1.15.5.

### Two caveats worth reading before you invest in this

**Naming exact cores means leaving every alignment guarantee behind.** `coreIds` requires
`cpuPolicy: manual`, and `manual` is the unsupported corner of this API in four independent
places: WEKA's own doc says "avoid using any other policy rather then default `auto`"; only
`dedicated`/`dedicated_ht`/`auto` containers are listed as receiving kubelet-enforced exclusive
CPUs; the DRA path rejects `manual` and `shared` outright; and in the operator source the SMT
alignment helper is called on the `dedicated` branches but **not** on the manual one. That is a
consistent shape rather than four separate quirks — the cost of choosing your own core IDs is
that every automatic guarantee stops applying and you provide them yourself. See *A warning about
naming exact cores*.

**Multi-NUMA placement is a partial solution today.** Aligning CPUs and hugepages to a node is
the part that works. Aligning the NIC and the NVMe drives to the same node is not driven by
`spec.numa` at all. Single-NUMA-per-container confinement — what this guide describes — is worth
doing. A symmetric multi-NUMA layout on one host is not supported.

---

## What has to agree

Pinning is not one setting. Five things must point at the same NUMA node, and if any one of them
disagrees the result is either silently unpinned or a client that will not start.

| # | Thing | Where it is set |
|---|---|---|
| 1 | Hugepage pool on the target node | kernel command line |
| 2 | Exclusive CPUs, and NUMA alignment of CPU, memory and hugepages | kubelet config |
| 3 | Core count and CPU policy | `WekaClient` / `WekaContainer` |
| 4 | Data-plane NIC on the target node | NIC selection, done by you |
| 5 | Everything else kept off those cores | kubelet config, kernel command line, systemd |

---

## Step 1: read the topology and choose the node

```bash
lscpu | grep -E 'NUMA|Socket|Thread'          # nodes, sockets, threads per core
lscpu -e=CPU,NODE,CORE,SOCKET                 # per-CPU map, including sibling pairs
cat /sys/class/net/<dev>/device/numa_node     # which node a NIC is on
```

Two things to note before going further.

**Threads per core decides your CPU policy.** 1 means non-hyper-threaded, use `dedicated`.
2 means hyper-threaded, use `dedicated_ht`, and read the sibling-leak section below.

**On a hyper-threaded host, `lscpu -e` tells you which logical CPUs are siblings.** Two logical
CPUs sharing a CORE id are the same physical core. This matters because exclusivity in
Kubernetes is granted per logical CPU, not per physical core.

---

## Step 2: hugepages on the target node

This is where 4k and 64k genuinely diverge.

The operator requests hugepages **by explicit size**, so the pool must exist at exactly the size
the operator asks Kubernetes for. That is `hugepages-2Mi` for a `WekaClient`, always: the `WekaClient` CRD has
no `hugepagesSize` field. A `WekaContainer` additionally accepts `hugepagesSize: 1Gi`. There is
no 512 MiB or 16 GiB option in the operator.

### Choosing the page size

On bare metal WEKA is normally given 1 GiB hugepages, for TLB reach. A 12-core container maps
roughly 18 GiB of hugepage memory: about 9,400 entries at 2 MiB against 19 at 1 GiB, where a
typical L2 TLB holds on the order of one to two thousand entries. Under the operator the default
is 2 MiB and most deployments never change it, so the data path runs well past TLB reach. The
cost is real but modest, in the region of a few percent on memory-bound access patterns, and it
only appears once the working set exceeds what the TLB can cover.

`hugepagesSize: 1Gi` is available on `WekaContainer` only, and only on a 4k kernel:

| | 4k kernel | 64k kernel |
|---|---|---|
| sizes the kernel offers | 2 MiB and 1 GiB on x86; 64 kiB, 2 MiB, 32 MiB and 1 GiB on ARM | 2 MiB, 512 MiB, 16 GiB |
| sizes the operator can ask for | 2 MiB, 1 GiB | 2 MiB, 1 GiB |
| usable intersection | 2 MiB or 1 GiB | **2 MiB only** |

On 64k there is no 1 GiB page size at all, and the operator cannot express the 512 MiB size that
would be its natural analogue. Setting `hugepagesSize: 1Gi` on a 64k node leaves the pod Pending
on `Insufficient hugepages-1Gi`, because kubelet never advertises a resource for a pool the
kernel does not support.

If you do use 1 GiB pages on 4k backends, the operator's `1564 MiB x cores` figure is not a
multiple of 1024, so every request rounds up to a whole gibibyte and that rounding is wasted per
container. Reserve the pool at boot, since 1 GiB pages cannot be allocated reliably at runtime
once memory has fragmented:

```
hugepagesz=1G hugepages=<node>:<count>
```

### On a 4k-page kernel

2 MiB is the platform default hugepage size, so the pool you need is the ordinary one. Place it
on the node you are targeting:

```
hugepagesz=2M hugepages=<node>:<count>
```

### On a 64k-page kernel

The available hugepage sizes are 2 MiB, 512 MiB and 16 GiB, and **the default is 512 MiB**. The
2 MiB pool the operator requires does not exist unless you create it explicitly. If it is
missing, kubelet advertises `hugepages-2Mi: 0` and the client pod sits Pending forever with
`Insufficient hugepages-2Mi`, a message that mentions neither WEKA nor hugepage sizing.

The command line is the same, and the size prefix is what does the work:

```
hugepagesz=2M hugepages=<node>:<count>
```

**Do not add `default_hugepagesz=2M`.** It would work, but it changes the platform default that
every other piece of software on the host assumes. The `hugepagesz=` prefix already creates the
pool WEKA needs while leaving the default alone.

### The 64k reporting trap

On a 64k kernel with a fully populated 2 MiB pool, `/proc/meminfo` reads:

```
HugePages_Total:       0
Hugepagesize:     524288 kB
```

Both fields describe the *default* pool, which is the 512 MiB one and is empty. Any check that
reads `HugePages_Total`, and any provisioning script that sets a bare `hugepages=N` without a
size prefix, will conclude the host has no hugepages while it in fact has exactly the right ones.
Only the size-specific sysfs paths tell the truth:

```bash
grep . /sys/devices/system/node/node*/hugepages/hugepages-2048kB/nr_hugepages
```

### Both kernels: use the node-qualified form

`hugepages=<node>:<count>` places pages on named nodes. A bare `hugepages=N` spreads them across
all nodes, which defeats the purpose. Use `hugepages=0:12288,1:12288` if you are pinning separate
instances to more than one node.

**Do not treat the pool location as the placement mechanism.** Use `spec.numa` — it is the
intended mechanism and it is proven working. Pool placement is a pre-v1.15.5 fallback, and if you
use it, verify `Mems_allowed_list` inside the container and the per-node `free_hugepages` delta
rather than trusting that the pod started. On a two-node host, the per-node `nr_hugepages` counts
were identical before and after a confined client was created: under Kubernetes the pool is
pre-provisioned, and the client used the free pages it found.

How many: the operator requests `1564 MiB x cores`, so a 12-core client needs 18768 MiB. Round
the pool up from there and leave headroom, especially on 64k.

---

## Step 3: kubelet

```yaml
# /var/lib/kubelet/config.yaml
cpuManagerPolicy: static
reservedSystemCPUs: "0,<node1-first-cpu>" # ONE whole physical core per NUMA node, siblings included
topologyManagerPolicy: single-numa-node   # restricted is WEKA's recommendation; best-effort on GPU nodes
topologyManagerScope: pod
memoryManagerPolicy: Static               # hosts with few NUMA nodes ONLY — None on a 34-node host, see below
reservedMemory:
  - numaNode: 0
    limits:
      memory: 1Gi
  - numaNode: 1
    limits:
      memory: 1Gi
```

- **`cpuManagerPolicy: static`** is what makes exclusive CPUs possible at all. Without it every
  pod lands in the shared pool regardless of its QoS class.
- **`topologyManagerPolicy`** defaults to `none`. WEKA's own documentation **recommends
  `restricted`**, not `single-numa-node`. Both work; `restricted` is the documented preference:

  | Policy | Effect |
  |---|---|
  | `single-numa-node` | admits only if all aligned resources fit one NUMA node, else rejected at admission |
  | `restricted` | admits only when the hint providers' preferred affinities can be met, else rejected. **Recommended** |
  | `best-effort` | records the preferred affinity but admits anyway when it cannot be met, so a WEKA pod may land split across nodes |

  A pod rejected at admission is left in a terminal state and **is not rescheduled** — the owning
  controller has to recreate it.

  > **Scope of what has been verified here.** The `spec.numa` confinement described in this guide
  > was measured end to end under **`single-numa-node`**. `restricted` is WEKA's recommendation
  > and is the better default on the reasoning above, but it has not been exercised in the same
  > way. The GPU carve-out below rests on WEKA's guidance, not on a measurement — no GPU operator
  > was present to produce the conflicting hint.

  **Carve-out for GPU nodes: use `best-effort` there.** A GPU operator publishes a multi-NUMA
  topology hint that a strict policy cannot satisfy, so `restricted` or `single-numa-node` refuses
  the pod at admission on a node with GPUs. `best-effort` records the preferred affinity and
  admits. NUMA confinement still holds under it, because `spec.numa` makes the pod request
  `weka.io/numa-region-<N>` — a hard scheduling constraint that is independent of the topology
  policy — and the device plugin's topology hint still steers the CPU manager. Verify on the pod
  rather than relying on the policy to enforce it.
- **`cpuManagerPolicyOptions: strict-cpu-reservation: "true"`** keeps pods of *every* QoS class
  off the reserved CPUs, and materially changes the `reservedSystemCPUs` section below. Use it.
  Resolved against the Kubernetes source (`pkg/kubelet/cm/cpumanager/policy_options.go`): it is a
  **beta** policy option on 1.34 and a **stable** one from 1.35. Beta options are gated on
  `CPUManagerPolicyBetaOptions`, which has defaulted to on since 1.23, so on 1.34 it works with no
  extra gate and needs no version-conditional handling.

  **`StrictCPUReservation` is not a feature gate at any version** — that is the trap. It exists
  only as a Go constant whose *value* is the string `strict-cpu-reservation`; it does not appear in
  `pkg/features/kube_features.go` at all. There is one mechanism with a kebab-case name and a
  CamelCase identifier, not two mechanisms. So putting `StrictCPUReservation` under `featureGates:`
  is an unknown gate and **kubelet refuses to start**. Put it under `cpuManagerPolicyOptions`,
  never under `featureGates`.
- **`topologyManagerPolicyOptions: max-allowable-numa-nodes`** is required on hosts with more than
  8 NUMA nodes — the topology manager refuses to run otherwise — **and on kubelet 1.34/1.35 it is a
  trap on hosts with many nodes.** The device manager generates hints by enumerating every subset
  of the machine's NUMA nodes, 2^N − 1 of them, for any pod requesting a device-plugin resource
  with NUMA topology — which `weka.io/numa-region-<N>` is. Some GPU trays expose 34 NUMA
  nodes (see the NVIDIA Grace tuning guide linked below), so
  the first confined WEKA pod hangs kubelet admission indefinitely (kubernetes/kubernetes#135541;
  KEP-4622 states the option does not remove this state explosion). The fix, PR #138244 —
  enumerate only the nodes that host the requested device — ships in **kubelet v1.36.0 and
  later** and is in no 1.34.x/1.35.x release. Below 1.36 on such a host the only admission-safe
  setting is `topologyManagerPolicy: none`, under which `spec.numa` steers nothing (the operator
  runtime does not read `WEKA_NUMA_REGION`; placement is whatever cpuset kubelet hands the pod).
  The memory manager's Static policy has the same enumeration and is **not** fixed — leave it
  `None` on such hosts. On 2-node hosts, where this guide's measurements were made, none of this
  applies: three subsets. References: https://github.com/kubernetes/kubernetes/issues/135541 ·
  https://github.com/kubernetes/kubernetes/pull/138244 ·
  https://github.com/kubernetes/kubernetes/blob/release-1.34/pkg/kubelet/cm/devicemanager/topology_hints.go ·
  https://github.com/kubernetes/kubernetes/blob/master/pkg/kubelet/cm/memorymanager/policy_static.go ·
  https://github.com/kubernetes/enhancements/blob/master/keps/sig-node/4622-topologymanager-max-allowable-numa-nodes/README.md ·
  https://docs.nvidia.com/dccpu/grace-perf-tuning-guide/system.html
- Changing the CPU manager policy or its options needs kubelet stopped, `/var/lib/kubelet/cpu_manager_state`
  removed, then a restart. Otherwise kubelet crash-loops on the checkpoint mismatch.
  **Removing the checkpoint is the load-bearing step; the drain is not.** WEKA's documentation
  calls for a drain as well, and on a node holding backend containers that is the expensive part.
  Measured on a worker holding a drive and a compute container, adding and then removing the
  option without draining: node Ready on the first poll, **zero restarts** on every WEKA container
  across both transitions, Guaranteed exclusive pins preserved exactly, cluster healthy
  throughout. Kubelet re-admits running Guaranteed pods and rebuilds the checkpoint from them.
  Drain if you want the margin; know that it is margin, not mechanism.
- **`topologyManagerScope: pod`** aligns the whole pod rather than each container independently,
  which is what you want for a multi-container WEKA pod.
- **`memoryManagerPolicy: Static`** is the setting most people miss — **on hosts with a small NUMA
  node count**; on a 34-node host it stalls admission of every Guaranteed pod and must
  stay `None` (see the `max-allowable-numa-nodes` bullet). The topology manager aligns
  CPUs and devices; **memory and hugepages are only NUMA-aligned when the memory manager is also
  Static**. Without it you can get cores on one node and hugepages served from another — unless
  the 2 MiB pool exists on one node only, which is then the only place they can come from. It
  requires `reservedMemory`, and the total must **equal** kube-reserved plus system-reserved plus
  the eviction thresholds — not merely exceed it. Too much fails to start just as too little does.
  Split that total across the NUMA nodes.

**Do not write a zero-valued `reservedMemory` entry.** `hugepages-2Mi: 0Mi` makes kubelet refuse
to start with `reserved memory may not be zero for NUMA node N and resource hugepages-2Mi`. List
only what you are actually reserving and omit the rest.

---

## Step 4: the WEKA custom resource

### cpuPolicy

`cpuPolicy` decides both how many CPUs the pod reserves and whether a core list you supply is
honoured at all.

| cpuPolicy | CPUs the pod requests | `CORE_IDS` given to WEKA | Your `coreIds` |
|---|---|---|---|
| `auto` | resolves to `dedicated_ht` on an HT host, `dedicated` otherwise | `auto` | **ignored** |
| `dedicated` | `cores + extraCores + 1` | `auto` | ignored |
| `dedicated_ht` | `cores * 2 + extraCores + 1` | `auto` | ignored |
| `manual` | see the warning below — not documented here | your list | honoured, at a cost |
| `shared` | whatever you put in `resources` | not set | ignored |

The `+1` is the management core, on top of the data cores. Note that under `dedicated_ht` the data
cores are doubled but `extraCores` is **not** — it is counted once.

### The normal configuration

```yaml
apiVersion: weka.weka.io/v1alpha1
kind: WekaClient
spec:
  cpuPolicy: dedicated        # dedicated_ht on a hyper-threaded host
  coresNum: 12
```

That is all that is required. The operator produces a Guaranteed pod, kubelet's static CPU
manager hands it an exclusive cpuset, the topology manager guarantees that set is on one NUMA
node, and WEKA receives `CORE_IDS=auto`, reads the affinity mask it was given and selects its
data cores from inside it.

You do not choose *which* cores. You choose how many, and which NUMA node. On v1.15 and earlier
the node is chosen indirectly, by where the hugepage pool is: with `single-numa-node` and the
memory manager Static, the only satisfiable placement is the node holding the pages, so the pool
location drives the CPU placement. On v1.16 and later, `spec.numa`/`spec.roleNuma` let you
name the node directly instead of arranging for it to be the only satisfiable one — provided you
set `single: true` alongside `region`.

### What the operator computes

| Field | Formula | 12 cores, non-HT |
|---|---|---|
| CPU request and limit | `cores + extraCores + 1`, or `cores * 2 + extraCores + 1` on `dedicated_ht` | 13 |
| memory request and limit | `2000 + 1965 + 3050 * cores + additionalMemory` MiB | 40565Mi |
| `hugepages-2Mi` | `1564 * cores` MiB | 18768Mi |

`hugepagesOffset` defaults to 200 MiB for most modes and `200 * numDrives` for drive containers.
It is subtracted from `hugepages` to produce WEKA's own `--memory`, then rounded down to a
`2 * cores` MiB boundary. Raise `hugepages` to give WEKA more; use `additionalMemory` to adjust
only the pod's memory request.

### extraCores — headroom for the non-datapath threads

`extraCores` reserves additional CPUs for the pod **on top of** the WEKA FE cores. It is not
handed to WEKA as data cores. The runtime derives `non_datapath_cores` as the pod cpuset minus the
IONode cores (and their SMT siblings), and WEKA pins every non-IONode process there: the management
`wekanode`, each frontend's `wekanode-pool` and `wekanode-queue` helper threads, trace-dumper,
trace-server and the agent. With `extraCores` unset that is a **single core** — measured on a
12-core client: twelve DPDK poll threads on their own cores, everything else on the one remaining
core, about 20 % busy at idle. `extraCores` adds cores to that set and nothing else.

It does **not** feed the wekafs kernel side. The driver's kernel threads are outside the pod
cpuset and are not governed by kubelet; on the host they showed a `Cpus_allowed_list` that spans
every CPU. None of that moves when `extraCores` changes. Size that host-side footprint separately.

It is available on `WekaContainer` and, since v1.16, on `WekaClient`. `WekaCluster` carries
per-role variants — `computeExtraCores`, `driveExtraCores`, `s3ExtraCores`, `nfsExtraCores`.

```yaml
spec:
  coresNum: 12
  extraCores: 2      # pod gets 15 CPUs on dedicated: 12 + 2 + 1
```

Three things worth knowing:

- **It widens the pod's cpuset, which is exactly what NUMA confinement then has to satisfy.**
  Every CPU in the request has to come from the region you named, so `extraCores` raises the bar
  for what must fit on that node. Size the region against the full request, not against
  `coresNum`.
- **It is the supported way to get what a hand-written non-datapath core list would give you.**
  `nonDatapathCoreIds` requires `cpuPolicy: manual` and everything that comes with it;
  `extraCores` works under `auto` and keeps exclusivity and SMT alignment.
- **It is safely adjustable in both directions.** The admission rule that blocks decreasing
  `numCores` on a running cluster explicitly does not check `extraCores`, because it never reaches
  WEKA — shrinking it only narrows the pod's cpuset. Unlike a core count, you can tune it without
  a cluster-level objection.

It is **undocumented outside the generated API schema** — it appears in `doc/api_dump/` and in no
prose page — so it is easy to miss when sizing a pinned client.

### Traps

- **`coreIds` is silently ignored unless `cpuPolicy: manual`.** Under `auto` the operator briefly
  resolves to manual when a core list is present and then immediately overwrites that with
  `dedicated_ht` or `dedicated`. No warning is emitted. If you set core IDs and left the policy
  at its default, you are not pinned to them.
- **`manual` without a `resources` block produces a Burstable pod.** The fallback request and
  limit differ (`1000*n+100` against `1000*(n+1)`), and kubelet's static CPU manager only grants
  exclusive CPUs to Guaranteed pods with whole-number CPU requests. WEKA still pins its own
  threads, but nothing stops other pods being scheduled onto the same CPUs.
- **`manual` with no `coreIds` is rejected outright.**
- **`nonDatapathCoreIds` shares `coreIds`' problem.** It is honoured only under `manual` and
  `shared`, so reaching it means accepting everything in the warning below.
- **Field names differ between CRDs.** `WekaClient` uses `coresNum`, `WekaContainer` uses
  `numCores`. Both carry `extraCores` as of v1.16 — see above.
- **`resources` accepts `hugepages-2Mi` as of v1.16**, alongside `cpu` and `memory`. On v1.15 and
  earlier an explicit `resources` block could set only CPU and memory, so a `manual` pod had its
  hugepages computed for it.

### A warning about naming exact cores

`cpuPolicy: manual` and `cpuManagerPolicy: static` are two independent things choosing CPUs, and
nothing reconciles them. kubelet assigns an exclusive cpuset of its own choosing to a Guaranteed
pod and knows nothing about your `coreIds`; WEKA then tries to pin to the list you gave. If the
two disagree, the pin is against CPUs the container does not own.

Kubernetes has no API for asking for particular CPU IDs. The static policy's allocator chooses
the set itself out of whatever is free at admission time, and what is free changes as other pods
come and go, so a `coreIds` list that happens to match today will not match after the pod is
recreated.

When the list and the cpuset disagree the kernel resolves it in one of two ways, neither of them
good:

| Overlap between `coreIds` and the container's cpuset | Result |
|---|---|
| none | `sched_setaffinity` returns `EINVAL`; the thread fails to start |
| partial | the call **succeeds silently**, clamped to the intersection: WEKA believes it holds every core it named and is in fact running on fewer |

The partial case is the dangerous one. Nothing logs an error, and the data path is quietly
oversubscribed onto a handful of CPUs.

In practice you cannot have both exact core selection and kubelet-enforced exclusivity. That is
not just an inference from behaviour — WEKA's docs corroborate it three ways: `cpu-policy.md` says
"`coreIds` - used in combination with `cpuPolicy: manual`"; `numa-alignment.md` says "Only
containers in Guaranteed pods with integer CPU requests receive exclusive CPUs. WEKA containers
with `cpuPolicy` `dedicated`/`dedicated_ht` (the `auto` default) meet this" — with `manual`
conspicuously absent from that list; and the DRA path "rejects `manual` and `shared`". The
existence of `nri-cpuset`, described as being for "explicit per-pod core placement outside these
mechanisms", is WEKA acknowledging the same gap.

### The conclusion, and why this guide stops here

**Use `cpuPolicy: dedicated` or `dedicated_ht` — or just leave it at `auto` — and let kubelet
choose which cores.** You choose how many cores and which NUMA node; you do not choose the
individual CPU IDs. That is the only configuration that gets you kubelet-enforced exclusivity,
NUMA alignment, SMT alignment and WEKA's own support, and it is what the rest of this guide
assumes.

**This guide deliberately does not document how to specify core IDs.** Not because it cannot be
made to do something, but because every route to it trades away a guarantee you are otherwise
getting for free, and the failure modes are silent:

- `coreIds` requires `cpuPolicy: manual`, which forfeits kubelet-enforced exclusivity — so you
  inherit the job of keeping everything else off those cores, by hand, on every node, forever.
- The list is not durable. Kubernetes has no concept of a requested CPU ID, so nothing reconciles
  your list with what the CPU manager allocated, and any accidental agreement breaks on the next
  pod recreation.
- A partial mismatch does not fail — it silently clamps, and the data path runs oversubscribed on
  fewer cores than WEKA believes it holds, with nothing logged.
- `manual` is also the branch with no SMT-alignment handling, so on a hyper-threaded host it can
  emit a CPU count kubelet refuses.
- WEKA's own guidance is "unless advised by Weka personal, avoid using any other policy rather
  than default `auto`."

There is one mechanism that delivers exact core selection *and* exclusivity — the `weka/nri-cpuset`
NRI plugin — and it does so by **replacing** kubelet's CPU manager rather than working alongside
it, which means turning the static policy off cluster-wide and giving up everything in Step 3. Its
own README calls it early-stage and not ready for production use. It is named here so you know it exists and what it would cost, not as a
recommendation.

If a case genuinely requires named cores — a specific NIC-local core set that automatic selection
will not produce — treat that as a conversation with WEKA rather than a configuration exercise,
since it puts you outside the supported path in four separate ways.

---

## Native NUMA confinement

> ### Two rules that make this fail silently — read these before configuring it
>
> `spec.numa` works, but it has two ways of doing nothing while looking correct. Either one on its
> own is enough to convince you the feature is broken.
>
> 1. **`single: true` and `region` must BOTH be set.** `region` alone does nothing, and so does
>    `single` alone. A CR with only `region` is accepted by the webhook, stored, and propagated to
>    the child `WekaContainer` — and then correctly ignored. No resource request is rendered and
>    nothing is logged.
> 2. **A change to a running container does not re-render its pod.** Client pod replacement is
>    keyed on the container **image**, so patching `numa` onto a running client updates the CR and
>    the child `WekaContainer` and leaves the pod exactly as it was, indefinitely. You must delete
>    the pod and let it be recreated.
>
> Together these mean **the CR is not evidence**. Verify on the pod — see the verification
> commands below.
>
> **The whole feature shipped in v1.15.5** (2026-08-18), filed under *Bug Fixes* as "device plugin
> in node agent for numa aligments", which is why it appears in no 1.16.x release note. Confirmed
> against the committed `doc/api_dump/`, generated from the Go types: numa is entirely absent at
> v1.15.4, and at v1.15.5 both `spec.numa` **and** `spec.roleNuma` appear complete, with v1.15.6,
> v1.16.0 and v1.16.1 identical. **The 1.16 line added nothing NUMA-related** — if NUMA
> confinement is your only reason to upgrade, v1.15.6 carries the complete feature.
>
> There is also **no `enabled` field, at any tag.** `numa.enabled: true` is pruned as an unknown
> field and the CR silently does nothing. Use `single`.

Both `WekaCluster` and `WekaClient` carry `spec.numa`, and `WekaCluster` additionally carries
`spec.roleNuma` for per-role placement:

```yaml
# WekaCluster
spec:
  numa:                      # default for all backend and protocol containers
    single: true             # confine to one NUMA node
    region: 0                # NUMA node index, 0-based
    method: device-plugin    # device-plugin (default) | dra
  roleNuma:                  # per-role override, same fields
    drive:   {single: true, region: 1}
    compute: {single: true, region: 0}
    # also: s3, nfs, smbw, dataServices

# WekaClient
spec:
  numa:
    single: true
    region: 1
```

### The rules that actually govern it

- **Both `single: true` and `region` are required** — see the box above.
- **`method` omitted means `device-plugin`**, which is the WEKA-recommended path.
- `roleNuma.<role>` replaces `numa` for that role; roles without an override inherit `numa`.
- Applies to compute, drive, S3, NFS, SMB-W and data-services containers only. **Auxiliary
  containers — envoy, telemetry, drivers — are never confined.**
- Changing `numa` or `roleNuma` on a running `WekaCluster`, or `numa` on a `WekaClient`, **is**
  propagated to existing `WekaContainer`s — but see rule 2 above about the pod.

### Patch, then recreate — and verify on the pod, never on the CR

This is the operational trap. Setting or changing `numa` on a running `WekaClient` updates the CR
and the child `WekaContainer` and **does not restart the pod**, because client pod replacement is
keyed on the container image. The CR will show your change while the running pod is still
completely unconfined. Nothing warns you.

So: patch, then delete the pod and let it be recreated, then verify against the **pod**:

```bash
# 1. the pod actually requests the region resource
kubectl get pod <pod> -o jsonpath='{.spec.containers[*].resources.requests}'
#    expect weka.io/numa-region-<N>: 1

# 2. the node shows it allocated, on that region and not another
kubectl describe node <node> | grep numa-region

# 3. the device plugin injected the env var on allocation
kubectl exec <pod> -- env | grep WEKA_NUMA_REGION
#    expect WEKA_NUMA_REGION=<N>

# 4. memory is actually confined to that node
kubectl exec <pod> -- grep Mems_allowed_list /proc/self/status
```

Checking the CR proves nothing about the running pod. Checking *where the pod landed* proves
little either — on a host whose hugepage pool exists on only one node, it would land there anyway.
The resource request and `WEKA_NUMA_REGION` are the observables that distinguish a confined pod
from a coincidentally-placed one.

### method: device-plugin (default, and the one to use)

The node agent discovers NUMA nodes from `/sys/devices/system/node` and advertises each as an
extended resource `weka.io/numa-region-<N>`. Every advertised device carries kubelet
`TopologyInfo` naming its NUMA node, so the Device Manager supplies a NUMA hint and the topology
manager can align the pod's exclusive CPUs to the same node.

**Measured under `restricted` (kubelet 1.34, operator v1.16.1):** kubelet logged
`TopologyHints {"weka.io/numa-region-1": [{NUMANodeAffinity: 2, Preferred: true}]}` for a
Guaranteed pod that requested the region and **no hugepages**, and placed it on node-1 CPUs with
`Mems_allowed_list: 1`. The region request alone steers CPU and memory placement; the hugepage pool
does not have to be on that node to pull the pod there — it only has to be able to satisfy the
request once the pod is there.

A confined pod requests one unit of `weka.io/numa-region-<region>`, and on allocation the device
plugin sets **`WEKA_NUMA_REGION=<N>`** in the container environment.

It is **off by default**:

```yaml
nodeAgent:
  devicePlugin:
    enabled: true
  kubeletPath: /var/lib/kubelet   # change if kubelet is installed elsewhere
```

With it off, no node advertises the resource and a confined pod **cannot be scheduled at all**.

**After a kubelet restart the resource is briefly gone.** kubelet recreates its device-plugin
socket on start; the node agent notices the removal and re-registers both regions about 5 s later
(measured: socket removed 03:47:08Z, `registered device plugin with kubelet` 03:47:13Z). In that
window `kubectl describe node` shows `weka.io/numa-region-<N>` capacity 0. Already-running
confined pods are re-admitted from kubelet's checkpoint and are unaffected; a new pod that lands
in the window fails admission with `UnexpectedAdmissionError: … no healthy devices present` if it
was pinned with `nodeName`, or simply waits in Pending if it came through the scheduler. Check
the capacity is back to its normal value after any kubelet restart before drawing conclusions
from a Pending or Failed WEKA pod.
Two field notes: enabling it is a DaemonSet pod-spec change (it adds a hostPath mount), so every
node agent in the cluster restarts when you flip it; and the hostPath uses
`type: DirectoryOrCreate`, so a wrong `kubeletPath` fails **silently** — an empty directory is
created, registration goes to a socket nobody watches, and the resource never appears with
nothing logged.

### method: dra — do not use it in production

Uses Kubernetes Dynamic Resource Allocation with the upstream `kubernetes-sigs/dra-driver-cpu`
driver, creating a ResourceClaim against its `dra.cpu` DeviceClass. That driver is real and public
but **pre-1.0** — latest release v0.2.0, June 2026 — and its own README states: "The CPUManager and
this DRA driver are mutually incompatible and only one can be enabled at a time on any given
node." **WEKA documents this method as not validated for production use and says to use
`device-plugin`.** If you evaluate it anyway:

- `dra-driver-cpu` must be installed; a missing `dra.cpu` DeviceClass fails the container reconcile
  with an explicit error.
- Only `cpuPolicy` `dedicated`, `dedicated_ht` or `auto` is accepted — `manual` and `shared` are
  rejected, because the claim's CPU count must equal the pod's integer CPU request.
- A node using `dra` cannot use the static CPU manager configuration in Step 3 and relies on the
  driver for exclusivity.

### What it will not change

- **kubelet still has to be configured.** Topology hints only mean something when the topology
  manager is switched on, so `cpuManagerPolicy: static` and a `topologyManagerPolicy` other than
  `none` are still required, and `memoryManagerPolicy: Static` is still what NUMA-aligns memory
  and hugepages. `spec.numa` chooses the region; the kubelet policies are what enforce it.
- **The hugepage pool still has to be on the region you name.** Asking for region 1 on a node
  whose 2 MiB pages are all on region 0 produces an unsatisfiable pod, not a relocated pool.
- **The NIC is still not aligned for you.** `weka.io/weka-nics` remains a plain extended resource
  with no topology information. See Step 5.
- **It does not let you name individual cores.** `region` is a NUMA index, not a core list, so
  everything under *A warning about naming exact cores* still holds.

---

## Step 5: the data-plane NIC on the same node

The CRD has no NUMA field, and **kubelet will not align the NIC for you**. The topology manager
can only align resources that publish topology hints, and the operator's NICs do not: they arrive
as the extended resource `weka.io/weka-nics` patched onto the node object, not through a device
plugin. kubelet will happily admit a pod onto one node while its data-plane NIC sits on another.

For a DPDK client this is a hard requirement, not a tuning preference. With cores and hugepages
on one node and the data-plane NIC on another, the client does not start: the front-ends stay
down and the container loops waiting for I/O nodes to come up.

It also cannot be repaired from the memory side. `memoryManagerPolicy: Static` confines the pod
to the target node's memory, so memory local to a NIC on a different node is unreachable inside
the container however many hugepages are allocated there. The only fixes are to move the NIC to
the node, or move the hugepage pool and let the CPU placement follow it.

So: read `/sys/class/net/<dev>/device/numa_node` for the interface you intend to use, and make
sure the cores, the hugepages and that NIC are all on the same node.

---

## Keeping other pods off the pinned cores

Exclusivity comes from kubelet, not from WEKA. WEKA's affinity calls pin its own threads; they
reserve nothing from the scheduler.

**The only mechanism that reserves cores is Guaranteed QoS plus a whole-number CPU request plus
`cpuManagerPolicy: static`.** When all three hold, kubelet removes those CPUs from the shared
pool for the life of the pod, and every other pod on the node, BestEffort, Burstable and other
Guaranteed pods alike, is confined to what remains. `dedicated` and `dedicated_ht` satisfy all
three automatically.

### `reservedSystemCPUs` does not do what its name suggests

**By default** it does **not** hold CPUs back for a particular workload. Reserved CPUs are
excluded from *exclusive* allocation and stay in the shared pool, where every Burstable and
BestEffort pod runs — verified on a live cluster: `reservedSystemCPUs: "0,1"` yet
`cpu_manager_state` showed `defaultCpuSet "0-1,15-19"`. So listing WEKA's intended cores there is
counterproductive; it guarantees they remain shared. Its normal use is the opposite one, carving
out CPUs for the OS and kubelet so exclusive allocations never land on them. **Reserve one whole
physical core per NUMA node**, siblings included — not two CPUs on node 0 and none on node 1,
which leaves node 1 with no system set. On an SMT host `0` and `1` are usually *not* siblings;
read the pairing from `/sys/devices/system/cpu/cpu0/topology/thread_siblings_list` rather than
assuming adjacency. Size the set for the interrupt, workqueue and daemon load it will carry.

**One option changes this, and the difference is measurable in two lines.** Identical BestEffort
pod, identical node, `reservedSystemCPUs: "0,1"` unchanged throughout:

```
strict-cpu-reservation unset    ->  Cpus_allowed_list: 0-1,8-15
strict-cpu-reservation "true"   ->  Cpus_allowed_list: 8-15
```

The checkpoint agrees: `defaultCpuSet` moved `0-1,8-15` -> `2-15` and back on restore. (CPUs 2-7
are absent from the pod's set in both runs because Guaranteed containers hold them exclusively —
so the run shows both mechanisms at once.) `cpuManagerPolicyOptions: strict-cpu-reservation:
"true"` prevents pods of every QoS class from running on the reserved CPUs — which is what the
field's name suggests it does, and what it does not do by default. It does not influence where *exclusive* CPUs
are placed. This is the setting that makes a reserved set genuinely exclusive to the host. See
the version caution in Step 3: the policy-option spelling is the supported one, and the
feature-gate spelling stops kubelet.

### On hyper-threaded hosts, mind the sibling threads

Exclusive assignment is granted per **logical** CPU. Under `dedicated` on a hyper-threaded host,
WEKA receives `cores + 1` logical CPUs, and the sibling threads of those same physical cores stay
in the shared pool. Another pod scheduled onto a sibling competes for the same physical core's
execution units. The symptom is WEKA jitter with nothing visibly wrong in the scheduler.

Two ways to close it:

- **Use `dedicated_ht`** (or `auto`, which resolves to it on an HT host). The request becomes
  `cores * 2 + 1`, so WEKA owns both siblings of every core it uses.
- **Turn on full-pcpus-only**, which makes kubelet allocate whole physical cores only:

  ```yaml
  cpuManagerPolicy: static
  cpuManagerPolicyOptions:
    full-pcpus-only: "true"
  ```

  kubelet then rejects any Guaranteed pod whose CPU request is not a multiple of the SMT width,
  with an SMT alignment admission error. The operator has machinery for this: it detects the
  node's setting, combines it with the Helm value `fullPcpusOnly` (default `false`, environment
  variable `FULL_PCPUS_ONLY`), and rounds an odd CPU request up to the next even number so
  admission passes.

  **These two are compatible — verified from source at v1.16.1.** `roundFullPcpus` in
  `internal/capacityplanner/cpu.go` bumps an odd CPU count to the
  next even number when the node is hyper-threaded and `full-pcpus-only` is set, so
  `dedicated_ht`'s always-odd `cores * 2 + 1` becomes even, whole physical cores are held, and the
  documented spare non-DPDK thread survives — two of them, after rounding. It reaches clients:
  the renderer builds the node topology and calls the same code for every container mode, and it
  triggers on either the operator's own `fullPcpusOnly` config or the node's detected kubelet
  setting. You do not need to pad core counts by hand.

On a non-hyper-threaded host neither applies. `dedicated` gives one logical CPU per physical
core, and there is no sibling to leak through.

> **`cpuPolicy: manual` is the one that breaks here.** `roundFullPcpus` is called on the
> `dedicated` and `dedicated_ht` branches only. The manual branch computes its CPU count with no
> alignment call at all, so on a hyper-threaded node with `full-pcpus-only` it can emit an **odd**
> CPU request and fail SMT-alignment admission. If you are naming cores by hand on an HT host,
> either keep `full-pcpus-only` off or make the resulting count even yourself.

### Things that look like they should work and do not

| Attempt | Why it fails |
|---|---|
| `cpuPolicy: manual` with `coreIds` and nothing else | Request and limit differ, so the pod is Burstable and nothing is reserved |
| Listing WEKA's cores in `reservedSystemCPUs` | Reserved CPUs stay in the *shared* pool; this guarantees sharing rather than preventing it |
| A CPU limit set higher than the request | Not Guaranteed, so no exclusive assignment |
| A fractional CPU request such as `12500m` | The static policy grants exclusive CPUs only for whole numbers |
| `topologyManagerPolicy: single-numa-node` on its own | Controls NUMA alignment, not exclusivity |
| Relying on WEKA's own core pinning | Pins WEKA's threads; reserves nothing from the scheduler |

---

## Keeping OS processes off the pinned cores

The cpusets kubelet applies constrain only the pod's own processes. Kernel threads, interrupt
handlers and kernel workqueues are placed by the kernel and may land on a WEKA poll core, where
they compete with a 100%-busy thread. Split the node into a *system set* (the CPUs in
`reservedSystemCPUs`) and a *workload set*, then point each control below at the system set. The
first three are the ones most guides miss:

| Control | Mechanism |
|---|---|
| Steerable interrupts | `/proc/irq/<N>/smp_affinity_list`, `/proc/irq/default_smp_affinity`, or `irqaffinity=` on the kernel command line |
| Stop irqbalance undoing that | `IRQBALANCE_BANNED_CPULIST=<workload set>` in the irqbalance environment file, or disable irqbalance |
| Unbound kernel workqueues | `/sys/devices/virtual/workqueue/cpumask` |
| Block I/O completions | `rq_affinity=2` in `/sys/block/<dev>/queue/` so completions run on the submitting CPU |
| systemd-started host daemons | `CPUAffinity=<system set>` in `system.conf`, plus a per-unit override for the container runtime |


Nothing in the Kubernetes layer addresses this. The static CPU manager keeps other *pods* away;
kernel threads, IRQ handlers and systemd services are unaffected and will still be scheduled on
WEKA's cores.

If host-level noise matters, this is kernel and systemd territory:

| Mechanism | Effect |
|---|---|
| `isolcpus=<cpus>` | removes the CPUs from the scheduler's general load balancing |
| `nohz_full=<cpus>` | stops the periodic timer tick on those CPUs when one task is runnable |
| `rcu_nocbs=<cpus>` | moves RCU callback processing off them |
| `irqaffinity=<other cpus>` | keeps device interrupt handling on the cores you are not using |
| `CPUAffinity=` in `/etc/systemd/system.conf` | confines systemd-managed services to the other cores |

**These three are not part of WEKA's recommended set, and there is a design reason.** The
operator's own host-partitioning guidance stops at interrupt affinity, the irqbalance ban list,
the workqueue cpumask, systemd `CPUAffinity` and `rq_affinity` — every one of which names either
nothing or only the *system* set. `isolcpus`, `nohz_full` and `rcu_nocbs` name **workload** cores
at boot, and under the operator WEKA's cores are chosen at pod admission, not at boot, so at boot
you do not yet know which cores to name. Treat them as available for a statically-planned node
where you control the whole layout, not as a default step.

One interaction that makes the point concrete: kubelet does not know about `isolcpus`. Isolated CPUs remain
online and allocatable, so the static CPU manager may still hand them to some other Guaranteed
pod. Isolation and kubelet accounting have to be planned together rather than assumed to
cooperate.

**The blunt alternative** is to keep other workloads off the host entirely with a taint only the
WEKA pods tolerate. It is completely effective and usually self-defeating for a client, whose
purpose is to serve co-located compute.

---

## What multi-NUMA placement can and cannot do

- **Recommended pattern: bind by container role.** Give each role its own NUMA node via
  `roleNuma` — e.g. drive containers on node 1, compute on node 0, WekaClient on node 1 — with
  core counts sized to fit each node. This uses only the built-in kubelet managers.
- **Not supported: splitting one cluster symmetrically across NUMA nodes on the same host.** The
  planner places at most one drive container and one compute container per node, so two
  same-role containers on one host, each bound to a different NUMA node with its local drives and
  NICs, is not possible. (The same one-per-node constraint applies to client-mode containers, via
  a hard pod anti-affinity on `weka.io/mode`.)
- **NIC and NVMe selection is independent of `spec.numa`.** Only CPUs — and hugepages, with the
  Memory Manager Static — are aligned. Placing the data-plane NIC on the same node is still your
  job. See Step 5.
- `distribute-cpus-across-numa` spreads CPUs evenly only when a request needs more than one NUMA
  node; it never splits a request that fits in one.

---

## Switching a node between 4k and 64k

Changing kernel changes the hugepage **pool set**, not just the counts: a 4k ARM kernel offers
64kB/2MB/32MB/1GB, a 64k kernel offers 2MB/512MB/16GB. kubelet caches the machine state and will
crash-loop after such a switch:

```
policy_static.go ... "Invalid state, please drain node and remove policy state file"
err="[memorymanager] the expected machine state is different from the real one"
```

Delete `/var/lib/kubelet/cpu_manager_state` and `/var/lib/kubelet/memory_manager_state`, then
restart kubelet. Pinned pods are re-admitted by the static policy on the way back up.

The `hugepagesz=2M hugepages=<node>:<count>` line is valid on both kernels and does not need to
change. WEKA's driver build is per kernel version, so the switch does require a driver build for
the new kernel, though a second node already running that same kernel will have produced it.

---

## Verification

```bash
# which CPUs kubelet actually reserved, per container. This is the authoritative answer.
sudo jq . /var/lib/kubelet/cpu_manager_state

# whether memory and hugepages were NUMA-aligned, and to which node
sudo jq . /var/lib/kubelet/memory_manager_state

# QoS class and the numbers the operator computed
kubectl -n weka-operator-system get pod <weka-pod> \
  -o jsonpath='{.status.qosClass}{"\n"}{.spec.containers[0].resources}'

# per-node hugepage pools: allocated, and still free once the client is up
grep . /sys/devices/system/node/node*/hugepages/hugepages-2048kB/nr_hugepages
grep . /sys/devices/system/node/node*/hugepages/hugepages-2048kB/free_hugepages

# what kubelet advertises. A 64k host missing the 2 MiB pool shows hugepages-2Mi: 0
kubectl get node <node> -o jsonpath='{.status.allocatable}' | tr ',' '\n' | grep huge

# the cores WEKA actually landed on, and their NUMA node
grep Cpus_allowed_list /proc/<wekanode-pid>/status
grep Mems_allowed_list /proc/<wekanode-pid>/status
```

**Do not read the cpuset from inside the WEKA container.** It is privileged and sees the host's
root cgroup, so `/sys/fs/cgroup/cpuset.cpus.effective` reports every CPU on the machine rather
than the container's exclusive set. Use `cpu_manager_state`.

Two things confirm success. `cpu_manager_state` shows an exclusive cpuset for the WEKA container
whose CPUs all belong to the target node, and the per-node `free_hugepages` count on that node
drops by roughly `hugepages / 2 MiB` when the client starts while the other nodes are untouched.
The second is what distinguishes real allocation from mere accounting.

---

## Checklist

1. `lscpu` for threads per core and the node-to-CPU map. 1 thread means `dedicated`, 2 means
   `dedicated_ht`.
2. `hugepagesz=2M hugepages=<node>:<count>` on the kernel command line, sized at least
   `1564 MiB x cores` with headroom. No `default_hugepagesz`.
3. On 64k, confirm the pool through the size-specific sysfs path, not `/proc/meminfo`.
4. kubelet: `cpuManagerPolicy: static`, `topologyManagerPolicy: single-numa-node`,
   `topologyManagerScope: pod`, `memoryManagerPolicy: Static` with non-zero `reservedMemory` for
   every node (fewer than 8 NUMA nodes; see Step 3 for larger hosts). On a hyper-threaded host,
   `dedicated_ht`/`auto` alone already closes the sibling gap.
5. `cpuPolicy: dedicated` or `dedicated_ht`, and a core count. Do not set `coreIds`.
6. Put the data-plane NIC on the same node as the pool.
7. Verify with `cpu_manager_state`, `memory_manager_state` and per-node `free_hugepages`.
8. For host-level quiet, set interrupt affinity, the irqbalance ban list, the workqueue cpumask,
   `rq_affinity=2` and a systemd
   `CPUAffinity`, planned together with kubelet's accounting.
