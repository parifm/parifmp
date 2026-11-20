# WEKA Operator: field notes

These notes come from lab tests and from the public sources (`weka/weka-operator`, `kubernetes/kubernetes`). Each note gives the versions it was checked on. Check a newer release before you rely on a detail.

Read the official concepts first: `doc/operator/concepts/numa-alignment.md` and `cpu-policy.md` in `weka/weka-operator` (present at tag v1.16.1).

## 1. Chart and upgrade mechanics (v1.14.2 to v1.16.1)

- **The chart is an OCI artifact, not a Helm repo.** It is at `oci://quay.io/weka.io/helm/weka-operator`, and the version has a leading `v` (`--version v1.16.1`). `helm search repo weka-operator` finds nothing. The CSI chart is a normal repo at `https://weka.github.io/csi-wekafs`.
- **You can diff offline.** `helm template <rel> <chart.tgz> -n <ns> -f user-values.yaml --kube-version <ver>` needs no cluster. Get the real values with `helm get values <rel> -n <ns> -o yaml` (not `--all`, which hides the keys that are pinned). `helm template` leaves out `crds/` unless you add `--include-crds`.
- **The Operator registers the validating webhook at run time. Helm does not template it.** `helm rollback` does not revert the webhook registration. A webhook problem shows as a failure of each later CR edit, not as an upgrade error.
  - Check after an upgrade or a rollback: do a no-op `kubectl annotate` on a WekaClient. An UPDATE uses the validate webhook and the protect-finalizers webhook.
- **The `weka-boot-scripts` ConfigMap is mounted with `subPath`, so a running Pod keeps its old copy.** kubelet does not refresh a `subPath` ConfigMap mount. The new `weka_runtime.py` reaches only the Pods that are created after the upgrade. Containers with `upgradePolicyType: manual` keep the old file until someone recreates them.
  - A clean Operator upgrade is not evidence that the driver path is good. Recreate one driver container to test it.
- **Shape of a minor version bump.** v1.14.2 to v1.16.1 changed 4 of 22 rendered objects and added none. The changes were in the boot-scripts ConfigMap, the manager ClusterRole, the controller-manager Deployment and the node-agent DaemonSet. Read the env block of the manager Deployment with care, because behaviour defaults move there (example: `POD_TERMINATION_DEACTIVATION_TIMEOUT` went from 24h to 0).
- **The node-agent device plugin is off by default.** Set `nodeAgent.devicePlugin.enabled=true` before `weka.io/numa-region-<N>` is advertised. The flag adds a hostPath mount at `<kubeletPath>/device-plugins`, so it changes the DaemonSet template and restarts each node agent.
- **A wrong `nodeAgent.kubeletPath` fails with no error.** The mount is `DirectoryOrCreate`. The plugin registers into a directory that kubelet does not watch, and the extended resource does not appear. Check kubelet's `--root-dir` on the Node.

## 2. CPU policy and core pinning (v1.14.2; see `internal/controllers/resources/pod.go` and the capacity planner code at that tag)

- **`cpuPolicy`** is one of `auto`, `shared`, `dedicated`, `dedicated_ht`, `manual`.
  - `dedicated` requests numCores + 1. The extra core is the management core.
  - `dedicated_ht` requests numCores × 2 + 1.
  - `auto` becomes `dedicated_ht` on a hyperthreaded Node, and `dedicated` on other Nodes.
- **Three traps, all with no error:**
  1. `coreIds` is ignored unless `cpuPolicy: manual`.
  2. `manual` without `resources` gives a request below the limit. The Pod is then Burstable, and kubelet gives it no exclusive CPUs. Set an equal whole-number CPU request and limit, and an equal memory request and limit.
  3. `manual` with no `coreIds` is rejected.
- **Field names differ between the CRDs.** WekaClient uses `coresNum`. WekaContainer uses `numCores`, `extraCores` and `hugepagesSize` (2Mi or 1Gi).
- **Exclusive cores are kubelet's job.** The mechanism is Guaranteed QoS, a whole-number CPU request and `cpuManagerPolicy: static`. WEKA pins its own threads and reserves nothing.
- **`reservedSystemCPUs` does not reserve cores for a workload.** Reserved CPUs stay in the shared pool. Use it to keep a few CPUs for the OS and kubelet. The option `strict-cpu-reservation` (beta in Kubernetes 1.34, stable in 1.35) keeps Pods of each QoS class off those CPUs. It is a CPU manager policy option, not a feature gate. An unknown feature gate stops kubelet.
- **`cpuPolicy: manual` plus `cpuManagerPolicy: static` is not coherent.** Two parts select CPUs and nothing reconciles them. Select `dedicated` or `dedicated_ht` for exclusive cores, or `manual` plus `coreIds` on a Node without the static policy.
- **On a hyperthreaded Node,** `dedicated` leaves the sibling threads in the shared pool. Use `dedicated_ht` or `auto`, or the kubelet option `full-pcpus-only`.
- **Debug trap:** do not read the cpuset from inside the WEKA container. It is privileged and it sees the host root cgroup. Read `/var/lib/kubelet/cpu_manager_state`, or `Cpus_allowed_list` in `/proc/<pid>/status`.

## 3. Client Pod resources (v1.14.2, WEKA 5.1, 2 MiB hugepages, measured)

| Resource | Formula |
|---|---|
| Memory request = limit | 3050 Mi × cores + 3965 Mi + `additionalMemory` |
| hugepages-2Mi | 1564 Mi × cores |
| CPU (`dedicated`) | cores + 1 |

- `spec.additionalMemory` (negative values are permitted) changes only the Pod memory request and limit.
- The real non-hugepage memory use was about half of the automatic request.
- To change `coresNum` or `coreIds`, recreate the WekaClient. A patch left `coreIds` null on this version.
- The Operator requires the 2 MiB hugepage pool. On a 64k-page arm64 kernel the default hugepage size is 512 MiB, so you must create the 2 MiB pool at boot (`hugepagesz=2M hugepages=<node>:<N>`). On that kernel `/proc/meminfo` shows the default pool only; read `/sys/devices/system/node/node*/hugepages/hugepages-2048kB/`.

## 4. NUMA alignment (`spec.numa`, v1.15.5 and later)

- `spec.numa` is on WekaClient and WekaContainer: `numa: {single: bool, region: int, method: device-plugin|dra}`. `spec.roleNuma` on WekaCluster gives placement per container role.
- **Set `single: true` and `region` together.** `region` alone does nothing, with no error.
- **A change to `numa` on a running client does not recreate the Pod.** Delete the Pod, then verify on the Pod: the `weka.io/numa-region-<N>` request, the `WEKA_NUMA_REGION` env var and `Mems_allowed_list`.
- `method: device-plugin` is the default and the recommended path. `method: dra` needs a DRA CPU driver that the Operator does not ship.
- The region resource carries a kubelet topology hint. The topology manager uses the hint to align CPUs and memory. With `topologyManagerPolicy: none`, `spec.numa` gives a scheduling constraint and an env var only.
- You also need `cpuManagerPolicy: static`, a topology manager policy (`restricted` or `single-numa-node`), `memoryManagerPolicy: Static` and the 2 MiB pool on the region.
- `spec.numa` does not align the NIC. For a DPDK client, put the cores, the hugepages and the dataplane NIC on the same NUMA node. A test with the NIC on the other node left all frontends down.
- After a kubelet restart the device plugin registers again in about 5 seconds. In that window the region capacity reads 0.
- **Change of kernel page size or of the hugepage pool set:** kubelet stops with an "invalid state" error. Remove `/var/lib/kubelet/cpu_manager_state` and `memory_manager_state`, then restart kubelet.

### Large NUMA counts (Kubernetes source, releases 1.34 to 1.36)

- kubelet's device manager made topology hints for each subset of the NUMA nodes (2^N − 1). On a host with 34 NUMA nodes, Pod admission does not complete. This applies to each device-plugin resource with topology data.
- Kubernetes PR #138244 ("devicemanager: constrain topology hints to device NUMA nodes") fixes this in v1.36. It is not in 1.34 or 1.35.
- The topology manager refuses more than 8 NUMA nodes unless you set `max-allowable-numa-nodes`.
- Before topology work on a new platform, count the nodes (`ls -d /sys/devices/system/node/node* | wc -l`) and check `kubelet --version`.

## 5. Switch kubelet to the static CPU policy in place (kubelet 1.34, cgroup v2)

- Procedure that worked: add `cpuManagerPolicy: static` and `reservedSystemCPUs` to the kubelet config, remove `/var/lib/kubelet/cpu_manager_state`, restart kubelet. The Node stayed Ready and no WEKA container stopped.
- kubelet admits the running Pods again in creation order and gives exclusive CPUs to the Guaranteed Pods with whole-number requests.
- A thread pin that is in the new cpuset stays. A pin outside the new cpuset is reset to the full new cpuset, and that container needs a recreate.
- Allocatable CPU decreases by the reserved count. Check the allocated resources of the Node before the switch.
- After a change of the CPU count of a Node, kubelet does not start until you remove `cpu_manager_state`.

## 6. Drivers and NICs

- The Operator builds kernel drivers only through a WekaContainer of mode `drivers-builder`. Each one builds for the kernel of the Node that its `nodeSelector` selects.
- A Node with an unknown kernel loops in `drivers-loader` with "Failed to download the drivers". Apply a builder with a `nodeSelector` for that Node. There is no automatic trigger.
- The driver signature is per kernel version. A second Node on the same kernel needs no new build.
- With `network.allocateVfPerIoNode: true`, the client Pod requests the extended resource `weka.io/weka-nics`, one per core. The Pod stays Pending with `Insufficient weka.io/weka-nics` until the Node has the resource and the `weka.io/weka-nics` annotation. The `ensure-nics` manual operation normally writes them.

## 7. Client roll gates (v1.16.1, WEKA 5.1)

- After you delete a client Pod, the cluster view reports the old container as `UP` for about one minute. Do not gate on the cluster view.
- Gate on `weka local ps --no-header` inside the new Pod: state `Running`, status `Ready` and a valid lease. The lease becomes valid a few seconds after `Ready`.
- The Operator sets the container name (the `NAME` env var of the Pod) from the WekaContainer CR (`internal/controllers/resources/pod.go`). A new Pod for the same CR has the same container name.
