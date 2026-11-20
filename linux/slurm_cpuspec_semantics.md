# Slurm `CpuSpecList`: what the CPU IDs mean

Read from the SchedMD/slurm source (master, 2026-09). These notes are the background for `check-slurm-weka-cpus.sh` in this repo.

- **Abstract CPU ID.** Slurm numbers CPUs as `core index * threads per core + thread index`, with cores counted socket by socket (`src/slurmd/common/xcpuinfo.c`). This is the hwloc logical PU number. It equals the logical core number only at 1 thread per core.
- **OS IDs or logical IDs?** The map from abstract ID to OS ID starts as the identity. Slurm replaces it only after the hwloc topology loads. So the same `CpuSpecList` string can mean OS IDs on one slurmd and logical IDs on another.
- **`CpuSpecList` reserves whole cores.** Slurm converts each listed CPU to its core, then expands the core to all of its threads (`src/slurmd/slurmd/slurmd.c`). Exception: when the CPU count of the node equals its core count, Slurm reads the list as core IDs.
- **`TaskPluginParam=SlurmdOffSpec`.** With it, the system cgroup gets the complement of the reserved CPUs, so slurmd stays off them. Without it, the system cgroup gets the reserved CPUs. This is the same on cgroup v1 and v2.
- **cgroup v2 path.** The system cgroup is `/sys/fs/cgroup/system.slice/<node>_slurmstepd.scope/system/` or `/sys/fs/cgroup/system.slice/slurmstepd.scope/system/` (`src/plugins/cgroup/v2/cgroup_v2.c`). It is not `/sys/fs/cgroup/slurm/system`.
- **`CoreSpecCount` and `CpuSpecList` together on one node is an error** (`slurm.conf(5)`). `scontrol` shows a `CoreSpecCount` that Slurm derives from the list.

## How to apply

- To reserve CPUs for another pinned service on a compute node, list them in `CpuSpecList` and set `SlurmdOffSpec`.
- Compare the reserved set with the cpuset that the other service really uses, in OS IDs. Read both from the cgroup files, not from the configuration strings.
