# WEKA Operator, WEKA CSI plugin and Kubernetes: a jargon map

This page is a map for a person who knows WEKA and is new to Kubernetes. It is not a tutorial.

**Source labels:** S = read in a public source (the path is given), G = general Kubernetes knowledge, H = hypothesis (not checked).

Sources: `weka/weka-operator` at 43ccc4b6 (2025-09-04), `weka/csi-wekafs` at a1b65ec (2025-08-19), and docs.weka.io. Newer releases can add kinds or modes.

```
Helm chart ──installs──► Operator (controller Pod) ──watches──► CRs (your YAML, the desired state)
                                 │ reconciles
   WekaCluster ──owns──► WekaContainer ──owns──► Pod ──runs on──► Node   (backends)
   WekaClient  ─creates► WekaContainer (mode client) ─► Pod per Node     (clients)

App Pod ─► PVC ─► StorageClass ─► CSI controller ─► WEKA API: filesystem / directory / snapshot
              └─► PV ◄──binds          CSI node (per Node) ─► wekafs mount into the App Pod
```

## Kubernetes itself (all G)

| Term | One line | WEKA thing it is like |
|---|---|---|
| Node / Pod | A host / the smallest unit that runs containers | A server / one WEKA container process set |
| Deployment / DaemonSet | N copies anywhere / one copy on each Node | DaemonSet ≈ "a client on each host" |
| CRD / CR | A new object type / one instance of it | The schema of `weka cluster ...` / your config |
| Controller, reconcile loop | Code that drives the actual state to the CR | An automated admin who runs the `weka` commands |
| Operator | A controller plus its CRDs for one product | Day-1 and day-2 runbooks as code |
| Helm chart, `values.yaml` | The package and its install parameters | The installer and its flags |
| Namespace, Secret, label, nodeSelector, toleration | Scope, credentials, and "which Nodes" | Org-like scope, the join credentials, host selection |
| ownerReference | Parent-child link; delete the parent and the children go | — |
| QoS class (Guaranteed, Burstable) | Guaranteed = request equals limit for each resource | The condition for exclusive cores |
| kubelet CPU / memory / topology manager | The Node agents that give exclusive CPUs and NUMA alignment | Core pinning and NUMA placement |
| Device plugin, extended resource | A Node-level resource that a Pod can request by name | `weka.io/weka-nics`, `weka.io/numa-region-<N>` |

## WEKA Operator (API group `weka.weka.io/v1alpha1`)

| Term | One line | WEKA thing | Src |
|---|---|---|---|
| `WekaCluster` | The CR for a whole backend cluster | The cluster | S |
| `WekaContainer` | One CR per WEKA container; it owns one Pod | A WEKA container (`weka local ps` row) | S: `internal/controllers/wekacluster/steps_cluster_creation.go`, `internal/controllers/wekacontainer/funcs_pod_ensure.go` |
| Container modes: `drive`, compute, s3, nfs, envoy, client | The role of a WekaContainer | Drive / compute / frontend / protocol containers; envoy is in front of S3 | S for `drive`; the others are seen as Go constant names |
| `WekaClient` | The CR for "clients on these Nodes" | Stateless clients | S |
| `drivers-builder`, `drivers-dist`, `drivers-loader` | They build, serve and load the kernel modules | The wekafs driver build | S: Operator deployment and day-2 operations docs |
| `WekaManualOperation` | A one-shot task CR (example: sign drives) | An admin command that you run one time | S: day-2 operations doc |
| `WekaPolicy` | A recurring or standing task CR | A scheduled admin task | H |
| Operator modes `manager`, `node-agent` | The central controller / a per-Node helper | — | S: `internal/config/env.go` |
| discovery, adhoc-op | Helper containers for Node inspection and one-off jobs | — | H |
| Validating webhook | An admission check on each CR create or update | Input validation for the config | S (see `operator_notes.md`) |

The CRD field definitions are in the public repo `weka/weka-k8s-api`. The Operator repo includes it as a submodule at `pkg/weka-k8s-api`.

## WEKA CSI plugin (driver name `csi.weka.io`)

| Term | One line | WEKA thing | Src |
|---|---|---|---|
| CSI | The Kubernetes standard interface for storage drivers | — | G |
| Controller server (Deployment) | It creates, deletes, expands and snapshots volumes through the WEKA API | An API user who makes filesystems and directories | S: chart templates |
| Node server (DaemonSet) | It mounts the volume on the Node for the Pod | `mount -t wekafs` | S: chart templates |
| StorageClass | A template for new volumes | "Which filesystem, which group, which mount options" | S |
| PVC / PV | An app's request for storage / the volume that fills it | A request / a filesystem, directory or snapshot | G |
| Dynamic / static provisioning | CSI creates the volume / you point at one that exists | A new or a pre-made directory | S |
| `volumeType: dir/v1` | A directory-backed volume | A directory with a quota in an existing filesystem | S: storage class docs |
| `volumeType: weka/v2` | The current general type; the other parameters select filesystem-backed or snapshot-backed | A whole filesystem or a writable snapshot | S for the string; H for the selection rule |
| `filesystemName`, `filesystemGroupName`, `capacityEnforcement`, `mountOptions` | StorageClass parameters | Filesystem, filesystem group, quota (HARD or soft), mount options | S: `examples/` |
| CSI secret | The API endpoints and credentials | A WEKA user and organization | G/S |
| NFS transport failback | CSI mounts over NFS when no WEKA client is on the Node | An NFS mount in place of wekafs | S: doc page name |
| CSINode, `kubeletPath` | The per-Node record of registered drivers / where the chart expects kubelet's root directory | — | S (see `csi_notes.md`) |

## Where to learn the rest

- Operator: docs.weka.io, "WEKA Operator deployments" and "WEKA Operator day-2 operations".
- Operator concepts in the repo at tag v1.16.1: `doc/operator/concepts/` (`numa-alignment.md`, `cpu-policy.md`, `project-overview.md`) and `doc/operator/deployment/`.
- CSI: docs.weka.io, "WEKA CSI Plugin" ("Storage class configurations", "Dynamic and static provisioning").
- Kubernetes terms to look up: "operator pattern", "custom resources", "persistent volumes", "CSI", "CPU manager policy", "topology manager", "device plugins".
