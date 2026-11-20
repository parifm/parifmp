# k8s: WEKA Operator and WEKA CSI plugin notes

Personal notes. They are not WEKA documentation, and WEKA does not support them. The official sources are docs.weka.io, `weka/weka-operator` and `weka/csi-wekafs`.

| File | Contents |
|---|---|
| [jargon_map.md](jargon_map.md) | One-page map of the Kubernetes, Operator and CSI terms, each tied to the WEKA thing it stands for |
| [operator_notes.md](operator_notes.md) | Chart and upgrade mechanics, CPU policy, client Pod resources, NUMA alignment, kubelet static policy, drivers and NICs, client roll gates |
| [numa_core_pinning_guide.md](numa_core_pinning_guide.md) | How to put a WEKA Operator client on cores of one NUMA node, on 4k and 64k kernels, and keep other Pods and OS processes off those cores |
| [csi_notes.md](csi_notes.md) | kubelet root directory and registration, mounts, the stale-container loop, chart facts |

Each note gives the versions it was checked on. Behaviour can change in a newer release.
