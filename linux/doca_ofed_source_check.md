# Read the MLNX_OFED / DOCA-Host kernel source for an exact release

Use this when you must know if one OFED release contains a given kernel change.

## Get the source

- The NVIDIA DOCA-Host repository is public: `https://linux.mellanox.com/public/repo/doca/<ver>/ubuntu24.04/x86_64/`. The `Packages` index lists `mlnx-ofed-kernel-dkms_<ver>_all.deb` (about 2.7 MB).
- The DKMS package is the full kernel tree:

```bash
ar x mlnx-ofed-kernel-dkms_<ver>_all.deb
bsdtar -xf data.tar.zst
ls usr/src/mlnx-ofed-kernel-<ver>/drivers/infiniband usr/src/mlnx-ofed-kernel-<ver>/drivers/net/ethernet/mellanox
```

- On a host with OFED installed, the same tree is in `/usr/src/mlnx-ofed-kernel-*/`.

## Map DOCA to OFED

| DOCA-Host | MLNX_OFED |
|---|---|
| 3.0.0 | 25.04.0.6.1.1 |
| 3.1.0 | 25.07.0.9.7.1 |
| 3.3.0 | 26.01.1.0.0.1 |

## Find the version that really runs

- `ofed_info -s` can be wrong. It comes from the `ofed-scripts` package, and a version-pinned downgrade leaves that package behind.
- Trust `dkms status` and `cat /sys/module/mlx5_core/version`.
- OFED's `ib_core` has no `version:` string. Use `modinfo -n ib_core` (a path under `updates/dkms/`) and the `srcversion`.

## Example: is a release exposed to the "block sizes >= 4G" truncation?

Upstream fix: commit 15fe76e23615, "RDMA/umem: Fix truncation for block sizes >= 4G". The bug needs a memory-key page of 4 GiB or more with more than one translation entry; `__rdma_block_iter_next` then truncates an `unsigned int`.

Three places decide if that condition is reachable:

| Place | 25.04 | 25.07 and later |
|---|---|---|
| `drivers/infiniband/hw/mlx5/mlx5_ib.h`, `mlx5_umem_mkc_find_best_pgsz()` | Page size bitmap ends at bit 31: 2 GiB maximum | Driven by device capability: larger pages possible |
| `drivers/infiniband/core/umem.c`, `ib_umem_find_best_pgsz()` | Each interior boundary caps the page size | Physically contiguous entries are merged |
| `drivers/infiniband/core/verbs.c`, `__rdma_block_iter_next()` | One scatterlist step | A loop over some entries; still `unsigned int` |

- With the first or the second guard present, the page size stays below 4 GiB and the truncation is not reachable.
- As of 26.01, the upstream fix was in no OFED tree that I read.

## Method

- Get the exact tree, then extract a function and compare releases:

```bash
awk '/^unsigned long ib_umem_find_best_pgsz/,/^}/' drivers/infiniband/core/umem.c > f_<ver>.c
diff f_25.04.c f_25.07.c
```
