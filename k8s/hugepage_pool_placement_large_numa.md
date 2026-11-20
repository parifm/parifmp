# Where a 2 MiB hugepage pool lands on a host with many NUMA nodes

Checked against Linux v6.8 (`mm/hugetlb.c`, `include/linux/hugetlb.h`, `arch/arm64/mm/hugetlbpage.c`) and the NVIDIA Grace performance tuning guide. Personal notes; verify on your own node.

## The problem

A common node-prep step writes one number to the global file:

```bash
echo 7500 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
```

On a two-socket server this splits the pool between two nodes. On a GPU tray with many memory-bearing NUMA nodes, it does something that most people do not expect.

## What the kernel does

- **A write to the global sysfs file is a round-robin over each NUMA node that has memory.** The kernel allocates one page per node in turn. The writer's memory policy does not apply to this file (it applies only to `/proc/sys/vm/nr_hugepages`).
- **The per-node file sets one node only:** `/sys/devices/system/node/node<N>/hugepages/hugepages-2048kB/nr_hugepages`. The boot parameter `hugepagesz=2M hugepages=<node>:<n>` is equivalent.
- **2 MiB pages can come from `ZONE_MOVABLE`.** On arm64 each valid hugepage size supports migration. GPU memory that is online as a NUMA node is movable-zone memory, so it is eligible.

## What that means on a Grace + GPU tray

- The NVIDIA tuning guide shows 34 NUMA nodes for a tray: 2 CPU nodes, 4 GPU memory nodes, and 28 MIG partition nodes that hold no memory unless MIG instances exist.
- So a global write spreads the pool across 6 nodes. A 7,500-page pool is about 1,250 pages per node: about 2.4 GiB on each CPU socket and about 9.8 GiB in GPU memory.
- This assumes that the GPU memory is online when the write occurs. Verify on the node.

## Which pages a process gets

- The first touch takes a page from the node of the thread that touches it. When that node is empty, the kernel follows the zonelist by distance: the other CPU socket first, then GPU memory.
- With no kubelet memory manager, nothing refuses this spill. See `numa_core_pinning_guide.md` for why the memory manager stays off on a 34-node host.
- Public measurements for CPU-to-GPU-memory access on this platform family give about 800 ns against about 200 ns local. Pages in GPU memory are the case that matters. `/proc/meminfo` does not show them.

## Checks

```bash
# pool per node; a non-zero count on a GPU memory node means that the pool is in GPU memory
grep . /sys/devices/system/node/node*/hugepages/hugepages-2048kB/nr_hugepages

# where the hugepages of one process are
awk '/huge/ {for(i=1;i<=NF;i++) if($i ~ /^N[0-9]+=/) print $i}' /proc/<pid>/numa_maps | sort | uniq -c
```

## What to do

- Use the per-node sysfs file or the node-qualified boot parameter. Put the pool on the CPU node where the consumer runs.
- Do not use the global file on a host where a device contributes NUMA memory.
