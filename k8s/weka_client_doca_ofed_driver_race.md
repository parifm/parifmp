# WEKA Operator client and DOCA-OFED driver-load race: avoidance and recovery

Step-by-step instructions to (1) recover the nodes where the DOCA-OFED driver is currently stuck behind a running WEKA client, and (2) stop the race from recurring on new nodes and reboots. Personal notes, not WEKA or NVIDIA documentation.

Written 2026-09-10 for one GPU cluster; part of it was verified on a lab on 2026-09-11. Evidence: a `NicClusterPolicy` with the settings shown below, WEKA Operator source at tag `v1.14.2`, NVIDIA Network Operator documentation and source (26.4.x), and the WEKA Operator docs. Check the versions that you run before you use a step. Everything below that came from reading source names the file so it can be re-checked.

## Summary

* The starting state: the `NicClusterPolicy` has `ofedDriver.upgradePolicy.autoUpgrade: true` but `safeLoad: false`. `safeLoad` is the Network Operator feature that cordons and drains a node before loading DOCA-OFED; NVIDIA's documentation describes it as "a special scenario of the upgrade procedure, where we upgrade from the inbox driver to the containerized DOCA-OFED Driver" — exactly this case. It is off.
* Turning `safeLoad` on is not enough for WEKA clients, but not for the reason of scheduling. The WEKA Operator gives every client pod a blanket `operator: Exists` / `effect: NoSchedule` toleration (`internal/controllers/resources/tolerations.go`, applied to client mode in `pod.go` `GetWekaPodTolerations`), so the Kubernetes scheduler would place a client pod on a cordoned node. However, the Operator itself does not create a client pod while its node is cordoned: at `v1.14.2` the `ensurePod` step returns a wait error "node <node> is unschedulable, cannot create pod" and retries every 10 s (`internal/controllers/wekacontainer/funcs_pod_ensure.go`). Verified on a lab on 2026-09-11: with the node cordoned and the client pod removed, no pod was created for the 10 minutes the cordon stayed on; it appeared within 2 s of the uncordon. What `safeLoad` cannot do on its own is remove a running client that still has active WEKA mounts (the Operator holds that pod in `Terminating`, log "Node is unschedulable and has active mounts"), and it cannot stop a pod that is already bound to the node from restarting on a reboot. The Helm value `skipClientNoScheduleToleration: true` removes the blanket toleration and is kept in Part 1 as the belt to that suspender: it also stops the scheduler from placing a client pod created moments before the cordon. Once it is set, the WekaClient must carry explicit tolerations for the taints that legitimately sit on client nodes.
* The nodes that are stuck now need a per-node recovery: stop the WEKA client through the Operator (pause the `WekaContainer`, which force-stops the client and removes its pod), let the DOCA-OFED pod reload cleanly, then unpause. A plain `kubectl delete pod` does not work: on an uncordoned node the Operator recreates the pod within seconds and it lands on the same node, replaying the race; on a cordoned node with active WEKA mounts the Operator refuses to let the pod stop at all and it sits in `Terminating`, which is the stuck state itself.
* Order of operations: Part 1 (client honors cordon) → Part 2 (recover stuck nodes) → Part 3 (enable `safeLoad`) → Part 4 (optional extra gate). Do not enable `safeLoad` first: with `autoUpgrade` already on, it would start cordon-and-drain on up to `maxParallelUpgrades` nodes at once, hitting client pods that have not been taken down cleanly.
* What this does and does not cover: new node joins and planned reboots become race-free. Unplanned reboots are not covered by any Kubernetes-level setting, because a pod already bound to a node restarts on boot regardless of cordon or node selectors; only a startup gate inside the client pod covers that case (see Part 5).

## What is happening

On a node that boots with the inbox `mlx5_core`/`mlx5_ib` modules, the WEKA client pod and the DOCA-OFED driver pod start in no particular order. If the WEKA client starts first, its DPDK/RDMA stack opens a verbs context through `ib_uverbs`, which pins `mlx5_ib`. When the DOCA-OFED container finishes building and tries to unload the inbox modules to load its own, `rmmod` fails with the module in use, and the driver pod never becomes ready. The `NicClusterPolicy` status then shows `state-OFED: notReady` and overall `state: notReady`.

`UNLOAD_STORAGE_MODULES: "true"` in `ofedDriver.env` tells the DOCA container to unload storage-path kernel modules (`nvme_rdma`, `ib_srp`, and similar) that would otherwise pin `mlx5_ib`. It cannot do anything about a userspace process holding a verbs context, which is what the WEKA client is. The two settings are complementary; keep it.

## Before you start

1. Confirm the Network Operator version, so the documentation links below match your release:

    ```bash
    helm list -n network-operator
    ```

    The NVIDIA page linked in the references is the `kubernetes2640` documentation version (the 26.4.x train). Use the page for your release.

2. Confirm on one node how the two driver states look, because the checks below depend on it. The inbox `mlx5_core` has no `version` attribute in sysfs; DOCA-OFED's does. NVIDIA's own NIC Feature Discovery uses the same file as its DOCA marker (`Mellanox/nic-feature-discovery`, `pkg/feature/internal/driver/driver.go`).

    ```bash
    test -f /sys/module/mlx5_core/version && cat /sys/module/mlx5_core/version || echo "inbox mlx5_core: no version file"
    ```

    Do not rely on the DOCA-OFED pod's `Ready` condition or on `mofed.wait=false` alone: the pod's readiness probe is literally `lsmod | grep mlx5_core` (`manifests/state-ofed-driver/0050_ofed-driver-ds.yaml` in `Mellanox/network-operator`), which also passes with the inbox module loaded.

3. If a GitOps tool such as Argo CD manages the two operators (look for `argocd.argoproj.io/tracking-id` on the `NicClusterPolicy`), make every configuration change in its source, not with `kubectl edit`, or the next sync reverts it.

4. Placeholders used below: `<node>` is a Kubernetes node name; `<weka-ns>` is the namespace of your `WekaClient` and its `WekaContainer` objects; `<weka-operator-ns>` is the WEKA Operator's namespace; `network-operator` is assumed as the namespace of the NVIDIA Network Operator.

## Part 1: Make the WEKA client honor a cordon

Do this first. It is harmless on its own. Lab verification on 2026-09-11 showed that the Operator already refuses to create a client pod on a cordoned node at `v1.14.2` (see Summary), so this Part is the belt rather than the whole fix: it also keeps the Kubernetes scheduler from placing a client pod that was created just before the cordon, and it makes drain-based tooling such as `safeLoad` behave the way its authors assume.

1. List every distinct taint present on the client nodes:

    ```bash
    kubectl get nodes -o json | jq -r '.items[].spec.taints[]? | "\(.key)=\(.value // "")::\(.effect)"' | sort | uniq -c
    ```

    The tolerations in your `NicClusterPolicy` are a hint of what you will find, for example `nvidia.com/gpu` and `dedicated`.

2. Add explicit tolerations for those taints to the `WekaClient` spec, using `rawTolerations` (a list of Kubernetes toleration objects; `tolerations` is a list of bare keys that the Operator expands to `NoSchedule` plus `NoExecute`). Example, adjust keys to step 1:

    ```yaml
    spec:
      rawTolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
        - key: dedicated
          operator: Exists
          effect: NoSchedule
        - key: reserved-by
          operator: Exists
          effect: NoSchedule
    ```

    Rules: do not add `node.kubernetes.io/unschedulable` (that is the cordon taint; tolerating it defeats the purpose), and do not add a keyless `operator: Exists` toleration (that recreates the blanket you are removing). Apply this before step 3; while the blanket toleration is still present it changes nothing.

3. Set the WEKA Operator Helm value `skipClientNoScheduleToleration: true` in the values of the `weka-operator` chart (`charts/weka-operator/values.yaml` in `weka/weka-operator` at `v1.14.2`; it becomes the env var `SKIP_CLIENT_NO_SCHEDULE_TOLERATION` on the manager deployment). Leave `skipUnhealthyToleration` at `false`: it governs the `NoExecute` tolerations that keep a running client alive through a node not-ready blip. Also leave `skipClientsTolerationValidation` at its default `true`: with validation on, the Operator would stop creating client containers for any node whose taints the client does not explicitly tolerate, including a cordoned node, instead of creating the container and letting its pod wait `Pending`.

4. Verify after the sync:

    ```bash
    kubectl -n <weka-operator-ns> get deploy -o yaml | grep -A1 SKIP_CLIENT_NO_SCHEDULE_TOLERATION
    ```

    Expect `value: "true"`. The Operator restarts; running client pods are not touched. Neither step 2 nor step 3 recreates existing pods: the Operator updates the `WekaContainer` spec in place, and pod recreation for client containers is driven by the image (upgrade) and by node changes, not by a pod-spec hash (`internal/controllers/wekacontainer/funcs_pod_ensure.go`, `targetPodConfigHash` returns empty for containers with an owner, so drift detection is skipped). Toleration-mismatch cleanup is also off by default. New tolerations apply to client pods created from now on, which includes every pod recreated in Part 2. After Part 2, check one recreated client pod and confirm there is no keyless `NoSchedule` entry:

    ```bash
    kubectl -n <weka-ns> get pod <client-pod> -o jsonpath='{.spec.tolerations}' | jq .
    ```

## Part 2: Recover the nodes that are stuck now

Work one node end to end first. Then run batches sized to what you can afford to have without a WEKA client at the same time; nothing here is safe to run fleet-wide in parallel on the first pass. Each node loses its WEKA client for the duration, so any pod on that node with a WEKA-backed volume must be evicted first.

1. Inventory. Which nodes are waiting on the driver, and what is each DOCA-OFED pod doing:

    ```bash
    kubectl get nodes -L network.nvidia.com/operator.mofed.wait -L nvidia.com/ofed-driver-upgrade-state
    kubectl -n network-operator get pods -l nvidia.com/ofed-driver -o wide
    kubectl get nicclusterpolicy nic-cluster-policy -o jsonpath='{range .status.appliedStates[*]}{.name}{"="}{.state}{"\n"}{end}'
    ```

    `mofed.wait=true` (or the label absent) marks nodes where the driver pod is not ready.

2. Confirm the cause on the node before touching it. Not every `notReady` is necessarily the module hold; a driver build failure on a new kernel would look the same from the status. Read the driver pod's log and check the module refcounts on the node:

    ```bash
    kubectl -n network-operator logs <mofed-pod> -c mofed-container --tail=200
    lsmod | grep -E '^(mlx5_ib|mlx5_core|ib_uverbs|ib_core) '
    test -f /sys/module/mlx5_core/version && cat /sys/module/mlx5_core/version || echo "inbox mlx5_core: no version file"
    ```

    The module-hold signature is an `rmmod`/"module is in use" failure in the log, a non-zero "Used by" count on `ib_uverbs`, and no `version` file. If you prefer not to open a node shell, `kubectl debug node/<node> -it --image=busybox -- chroot /host sh` gives the same view.

3. Find the WEKA client container on that node. The pod name is also the `WekaContainer` name, in the same namespace:

    ```bash
    kubectl get pods -A -l weka.io/mode=client -o wide --field-selector spec.nodeName=<node>
    ```

    If the label filter returns nothing, drop it and look for the `weka` pod in `kubectl get pods -A -o wide --field-selector spec.nodeName=<node>`.

4. Cordon the node and drain the workloads, excluding the WEKA client so that pods holding WEKA-backed volumes leave first and the drain does not wait on the client:

    ```bash
    kubectl cordon <node>
    kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --force --pod-selector 'weka.io/mode!=client'
    ```

    `--force` matches WEKA's documented node-reboot procedure and is only needed for pods without a controller. Confirm no WEKA mounts remain on the node before continuing: `mount -t wekafs` should print nothing.

5. Pause the client through the Operator. This sends the force-stop instruction to the client and deletes its pod; the Operator does not recreate it while the container is paused (`internal/controllers/wekacontainer/flow_paused_state.go`, `weka/weka-operator` `v1.14.2`):

    ```bash
    kubectl -n <weka-ns> patch wekacontainer <client-container> --type merge -p '{"spec":{"state":"paused"}}'
    kubectl -n <weka-ns> get wekacontainer <client-container> -o jsonpath='{.status.status}{"\n"}'
    ```

    Wait for `Paused`. The pause holds across Operator reconciles: the `WekaClient` reconciler never writes a container's `spec.state` except when an in-cluster target `WekaCluster` is explicitly paused or unpaused (`internal/controllers/wekaclient/client_pause.go`), and a `WekaClient` that joins an external cluster through `joinIpPorts` does not use that path.

6. Confirm the modules are released on the node: `lsmod | grep -E '^(ib_uverbs|mlx5_ib) '` should now show a zero "Used by" count for `ib_uverbs`.

7. Restart the DOCA-OFED driver pod on that node so it reloads with nothing holding the inbox modules. The DaemonSet recreates it:

    ```bash
    kubectl -n network-operator get pods -l nvidia.com/ofed-driver -o wide --field-selector spec.nodeName=<node>
    kubectl -n network-operator delete pod <mofed-pod>
    kubectl -n network-operator logs -f <new-mofed-pod> -c mofed-container
    ```

8. Verify the driver actually loaded, using the sysfs marker, not just the pod condition:

    ```bash
    test -f /sys/module/mlx5_core/version && cat /sys/module/mlx5_core/version
    kubectl get node <node> -L network.nvidia.com/operator.mofed.wait
    ```

    Expect the version string of your DOCA-OFED release, and `mofed.wait=false`.

9. Unpause first, then uncordon. While the node is still cordoned the Operator does not create the client pod at all: `get pods` shows no client pod on the node and the Operator log repeats "node <node> is unschedulable, cannot create pod" every 10 s (verified on a lab 2026-09-11 at `v1.14.2`). If a client pod does appear and schedule onto the still-cordoned node, stop and investigate before continuing. Unpausing before uncordoning means the client pod is created the moment the cordon lifts, before any workload with a WEKA-backed volume can land on the node and hit CSI mount retries:

    ```bash
    kubectl -n <weka-ns> patch wekacontainer <client-container> --type merge -p '{"spec":{"state":"active"}}'
    kubectl get pods -A -l weka.io/mode=client -o wide --field-selector spec.nodeName=<node>
    kubectl uncordon <node>
    kubectl -n <weka-ns> get wekacontainer <client-container> -o jsonpath='{.status.status}{"\n"}'
    kubectl get pods -A -l weka.io/mode=client -o wide --field-selector spec.nodeName=<node>
    ```

    Expect no client pod on the node after the first `get pods`, a `Running` pod within seconds of the uncordon (2 s on the lab, image and drivers already cached on the node), and the `WekaContainer` status back to `Running`. A `Pending` pod recycled about once a minute with `UnschedulablePod` events (`DELETE_UNSCHEDULABLE_PODS_AFTER`, Helm `defaultIntervals.deleteUnschedulablePodsAfter`, default `1m`) is what you see only when a pod object exists and cannot schedule for another reason, for example a `NoSchedule` taint the WekaClient does not tolerate after Part 1; a cordon never gets that far.

10. Verify the client from the WEKA side (any backend). `hostname` here is the name the client registered with WEKA, which can differ from the Kubernetes node name; use the value shown by `weka cluster container -F mode=client` if the filter returns nothing:

    ```bash
    weka cluster container -F mode=client -F hostname=<node> -o hostname,ips,sw_version,status,start_time
    ```

    Expect `UP` with a fresh `start_time`. Then move to the next node.

## Part 3: Turn on safe driver loading in the Network Operator

Do this after Part 2, or after confirming no node is still stuck; with `autoUpgrade` already `true`, the upgrade controller may begin cordon-and-drain on any node it considers `upgrade-required` as soon as `safeLoad` lands.

1. Change the `NicClusterPolicy`. Start with `maxParallelUpgrades: 1`, watch one node complete a full cycle, then raise it to the value that you want:

    ```yaml
    ofedDriver:
      upgradePolicy:
        autoUpgrade: true
        safeLoad: true
        maxParallelUpgrades: 1
        drain:
          enable: true
          force: true
          deleteEmptyDir: true
          timeoutSeconds: 300
    ```

    Field semantics from the CRD (`api/v1alpha1/nicclusterpolicy_types.go` in `Mellanox/network-operator`): `autoUpgrade` is the master switch and everything else is ignored when it is false; `safeLoad` cordons and drains the node before loading the driver; `drain.podSelector` filters which pods are drained and, left empty, applies to all pods; `drain.timeoutSeconds: 0` means no timeout. `waitForCompletion.podSelector` / `timeoutSeconds` lets you wait for jobs matching a label selector to finish before the drain starts, if you want training jobs to complete rather than be evicted.

2. Watch the state machine while the first node goes through:

    ```bash
    kubectl get nodes -L nvidia.com/ofed-driver-upgrade-state -L network.nvidia.com/operator.mofed.wait -w
    ```

    Expected sequence per node: `upgrade-required` → `cordon-required` → `drain-required` → `pod-restart-required` → `uncordon-required` → `upgrade-done`. `upgrade-failed` means the drain or the driver load timed out; recover that node with Part 2 and see Part 5 about drain timing.

3. What `safeLoad` changes operationally: every future DOCA-OFED rollout cordons and force-drains the nodes it touches, `maxParallelUpgrades` at a time, including `deleteEmptyDir`. Decide up front whether that is acceptable during production hours or whether driver rollouts become maintenance-window events.

## Part 4: Optional extra gate on the WekaClient

The Network Operator maintains a node label for exactly this purpose: `network.nvidia.com/operator.mofed.wait`. Its own RDMA device plugin, SR-IOV device plugin, DOCA telemetry and NIC configuration DaemonSets all use `network.nvidia.com/operator.mofed.wait: "false"` as a `nodeSelector` (`docs/heterogeneous-cluster-support.md` in `Mellanox/network-operator`). The controller sets it to `true` while the node's DOCA-OFED pod is not ready and to `false` once the pod reports ready; it removes it on nodes with no Mellanox NIC.

You can add it to the `WekaClient` node selector alongside your existing client label:

```yaml
spec:
  nodeSelector:
    <your-client-node-label>: "true"
    network.nvidia.com/operator.mofed.wait: "false"
```

Understand what it does and does not do with WEKA Operator `v1.14.2`:

* The Operator evaluates the selector when it reconciles the `WekaClient` and picks nodes at that moment; it does not watch node label changes (`internal/controllers/wekaclient/client_controller.go` only watches `WekaClient` objects). A node whose label flips to `false` later is picked up on the next `WekaClient` reconcile, not immediately. Kubernetes DaemonSets get continuous re-evaluation for free; a `WekaClient` does not.
* It is harmless with the Operator's defaults. Do not combine it with `CLEANUP_CLIENTS_ON_NODE_SELECTOR_MISMATCH=true` (Helm/env, default false): with that flag on, a transient `mofed.wait=true` (any driver pod restart) would delete the running client container on that node.

Treat it as a belt on top of Parts 1 and 3, not as a replacement for either.

## Part 5: Operating procedures after the fix

New node joins. With Part 1 and Part 3 in place: the Network Operator cordons the node before loading DOCA-OFED, the WEKA Operator does not create the client pod while the node is cordoned (Operator log "node <node> is unschedulable, cannot create pod" every 10 s, no pod object exists), the node is uncordoned once the driver is ready, and the client pod is created seconds later on top of DOCA-OFED. No manual step. The one window to be aware of: a client pod created in the seconds between the node turning Ready and the driver pod applying its cordon is already bound and will start on the inbox driver; Part 4's node selector on `operator.mofed.wait=false` closes that window, because the Operator only selects labeled nodes.

Planned reboots. Use the WEKA-documented "Perform a graceful node reboot on client nodes" procedure (cordon, drain, reboot, uncordon), with one addition for consistency with Part 2: pause the node's `WekaContainer` (Part 2 step 5) instead of letting the drain evict the client pod, then reboot. With Part 1 in place the sequence is race-free: the cordon persists across the reboot, nothing WEKA is bound to the node when it comes back, DOCA-OFED loads first, and the client is scheduled only after you unpause and uncordon (Part 2 step 9). Verify `/sys/module/mlx5_core/version` before you uncordon.

DOCA-OFED upgrades on nodes that already run a client. The Network Operator's drain evicts the client pod. Two things to verify on one node before relying on the automated path fleet-wide: how long an evicted client pod takes to leave `Terminating`, and whether it exceeds `drain.timeoutSeconds` (300). The client pod has a very long `terminationGracePeriodSeconds` and no `preStop` hook, and the Operator sends its own explicit stop instruction before the deletions it initiates; a plain eviction may not be handled the same way. If the timing is not comfortably inside the drain timeout, raise `drain.timeoutSeconds`, or treat driver upgrades as maintenance and pause the batch's client containers first (Part 2 steps 4 to 9).

Unplanned reboots and crashes. Not covered by any of the above. A pod already bound to a node restarts on boot regardless of cordon or node selector; those only govern scheduling. NVIDIA's own DaemonSets survive a reboot because `mofed.wait` flips to `true` at shutdown and the DaemonSet controller removes and recreates their pods; the WEKA Operator has no equivalent. The only layer that covers this case is a startup gate inside the client pod (wait until `/sys/module/mlx5_core/version` exists before starting the WEKA client). WEKA Operator `v1.14.2` offers no supported hook for it on `WekaClient` (the `preRunScript` override exists on `WekaContainer` but is not propagated from `WekaClient`). Until there is one, detect and remediate: a periodic check that a node runs a WEKA client while `/sys/module/mlx5_core/version` is absent identifies a client on the inbox driver; recover it with Part 2.

## Verification checklist

Per node:

```bash
test -f /sys/module/mlx5_core/version && cat /sys/module/mlx5_core/version
kubectl get node <node> -L network.nvidia.com/operator.mofed.wait -L nvidia.com/ofed-driver-upgrade-state
kubectl get pods -A -l weka.io/mode=client -o wide --field-selector spec.nodeName=<node>
weka cluster container -F mode=client -F hostname=<node> -o hostname,ips,sw_version,status,start_time
```

Fleet:

```bash
kubectl get nicclusterpolicy nic-cluster-policy -o jsonpath='{range .status.appliedStates[*]}{.name}{"="}{.state}{"\n"}{end}'
kubectl get nodes -L network.nvidia.com/operator.mofed.wait | awk 'NR>1 && $NF!="false"'
kubectl -n network-operator get pods -l nvidia.com/ofed-driver -o wide | grep -v Running
weka cluster container -F mode=client -F status=DOWN
```

Expected end state: `state-OFED=ready` and overall `state=ready`; every client node `mofed.wait=false`; every DOCA-OFED pod `Running` and `1/1`; no client `DOWN`; a recreated client pod's tolerations contain no keyless `NoSchedule` entry.

## Known limitations and open items

* Unplanned reboots remain a race until the client pod gates its own startup on the driver (Part 5).
* The eviction-time behavior of the client pod was not verified from source; measure it on one node before trusting the automated drain (Part 5).
* Whether enabling `safeLoad` retroactively processes nodes already in a not-ready state is not stated in NVIDIA's documentation; NVIDIA's troubleshooting guidance for a stuck node is manual (drain, delete the driver pod), which is what Part 2 does.
* The DOCA-OFED pod readiness probe does not distinguish inbox from DOCA modules; always verify with the sysfs `version` file.

## References

* NVIDIA Network Operator, Life Cycle Management (`safeLoad`, upgrade policy, node state labels, troubleshooting): https://docs.nvidia.com/networking/display/kubernetes2640/life-cycle-management.html
* `Mellanox/network-operator`, `docs/heterogeneous-cluster-support.md` ("OFED Wait Label (`mofed.wait`)", label management flow) and `api/v1alpha1/nicclusterpolicy_types.go` (`DriverUpgradePolicySpec`, `DrainSpec`, `WaitForCompletionSpec`), `manifests/state-ofed-driver/0050_ofed-driver-ds.yaml` (pod labels, readiness probe)
* `Mellanox/nic-feature-discovery`, `pkg/feature/internal/driver/driver.go` (`/sys/module/mlx5_core/version` as the DOCA marker)
* `weka/weka-operator` tag `v1.14.2`: `internal/controllers/resources/pod.go` (`GetWekaPodTolerations`), `internal/controllers/resources/tolerations.go`, `charts/weka-operator/values.yaml` (`skipClientNoScheduleToleration`), `internal/controllers/wekacontainer/flow_paused_state.go` (pause behavior), `internal/controllers/wekacontainer/funcs_handle_node_statuses.go` and `flow_active_state.go` (mismatch cleanup gates), `internal/controllers/wekaclient/client_controller.go` (watch set)
* WEKA Operator docs, WekaClient parameters (`nodeSelector`, `tolerations`, `rawTolerations`): https://docs.weka.io/kubernetes/weka-operator-deployments/weka-operator-full-deployment-workflow
* WEKA Operator docs, hardware maintenance, "Perform a graceful node reboot on client nodes": https://docs.weka.io/kubernetes/weka-operator-day-2-operations/hardware-maintenance

