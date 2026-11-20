# csi-wekafs: where the `acl` and `sync_on_close` mount options come from, and how to remove them

Checked against the public sources: csi-wekafs v2.9.1 and v2.9.3, weka-operator v1.14.2 (with the embedded CSI), and the Kubernetes validation code. A lab test on 2026-09-11 confirmed the `sync_on_close` parts. Personal notes, not WEKA documentation.

**Read this first.** WEKA sets `sync_on_close` on CSI mounts on purpose. Without it, a write error that occurs after `close()`, for example an out-of-quota error, is not reported to the application. Ask WEKA Support before you remove it, and record the risk that you accept.

## Where each option comes from

| Option | Source | Notes |
|---|---|---|
| `acl` on node mounts | The node server adds `fscontext` and `acl` when it believes that SELinux is active (`pkg/wekafs/mountoptions.go`, `setSelinux`). | With the Operator's `csi.selinuxSupport: off`, the driver gets no flag and reads the SELinux config file of its own container image (`utilities.go`). The image has that file, so the driver can believe that SELinux is on when the host has none (for example Ubuntu with AppArmor). |
| `acl` on controller mounts | Always, by design (`ControlServerAdditionalMountOptions`). | No change below affects it. |
| `sync_on_close` | A node server default (`NodeServerAdditionalMountOptions`). | The driver merges the node defaults again at mount time (`volume.go`, `MountUnderlyingFS`), after all user options. |

- `setSelinux` runs after the StorageClass, PV and annotation options are assembled. A `-acl` override cannot remove `acl`.

## A. Remove `acl` from the Pod mounts

### What does not work (Operator v1.14.2)
- `csi.selinuxSupport: auto`: the detection is for OpenShift nodes only. On Ubuntu it is the same as `off`.
- `csi.selinuxSupport: enforced`: it forces `acl` and adds a hostPath for `/sys/fs/selinux`. That path does not exist on Ubuntu, so the node Pod does not start.
- A PVC or Pod annotation `-acl`.

### A1. `noacl` with no image change
- **Why it works:** the driver sends the options in alphabetical order, so `acl` is before `noacl`, and wekafs applies the last one. `/proc/mounts` then shows no `acl`.
- **Effect of no `acl`:** POSIX ACL calls see no ACL, and `user.*` extended attributes are refused.
- **New PVs:** set the Kubernetes field of the StorageClass, not its `parameters`:

  ```bash
  kubectl patch storageclass <sc> --type merge -p '{"mountOptions":["noacl"]}'
  ```

  `StorageClass.mountOptions` is mutable. Kubernetes copies it to `PV.spec.mountOptions` at provisioning, and it reaches only the node mount. Do not use `parameters.mountOptions`: `parameters` is immutable, and the controller also uses it for its own mount.
- **Existing PVs:** `PV.spec.mountOptions` is mutable, and kubelet passes it on each NodePublish:

  ```bash
  kubectl patch pv <pv> --type merge -p '{"spec":{"mountOptions":["noacl"]}}'
  ```

  Then restart the Pods that use the PV.
- **Per PVC:** set `csi.allowMountOptionOverrides: true` in the Operator values (this restarts the node DaemonSet), then:

  ```bash
  kubectl -n <ns> annotate pvc <pvc> weka.io/mount-options-override="+noacl"
  ```

  With overrides on, each person who can create a Pod or PVC in the namespace can change mount options.

### A2. A derived image
```
FROM quay.io/weka.io/csi-wekafs:<tag>
RUN rm -f /etc/selinux/config
```
- With the file absent, the SELinux detection is false: no `acl` and no `fscontext` on node mounts.
- Set `csi.image` to the new image. The Operator restarts the node Pods, because the image is part of the DaemonSet hash.
- The Operator gives the CSI node DaemonSet no image pull secret. The nodes must be able to pull the image themselves.
- A later csi-wekafs release can change the detection. Read the release notes before you build an image.

### Verification
- Node plugin log: `kubectl -n <operator-ns> logs ds/<csi-node-daemonset> -c wekafs | grep -E 'Started CSI driver|Mounting wekafs filesystem'`. The "Mounting wekafs filesystem" line (debug level) lists the real options.
- In the Pod: `mount -t wekafs` shows no `acl`.
- Do not verify on the host mount table. After a node plugin restart, the old underlying mounts stay until a reboot or a manual unmount. That is harmless.
- Pods that restart at different times can coexist: the identity of the underlying mount includes the option string.
- Restart each Pod that uses a WEKA PVC after a change. The underlying mount is made at NodePublish with the options of that moment.

## B. `sync_on_close`

### Why the usual controls do not remove it
- The annotation `-sync_on_close` is applied, and the mount-time merge of the node defaults then puts the option back.
- `+nosync_on_close` (annotation, PV or StorageClass) sends both options. `nosync_on_close` sorts before `sync_on_close`, and the last one wins.
- A derived image cannot change it: the default is compiled in.
- The Operator-embedded CSI (v1.14.2 to v1.16.0) sets three fixed groups of mutually exclusive options (`readcache,writecache,coherent,forcedirect` / `sync,async` / `ro,rw`) and has no value for a fourth.

### What does work (lab-tested with the standalone chart, csi-wekafsplugin 2.9.3)
- Add `"sync_on_close,nosync_on_close"` to `pluginConfig.mutuallyExclusiveMountOptions` in the standalone `csi-wekafsplugin` Helm chart.
- Then `nosync_on_close` removes the default through each of these routes:
  - the Pod annotation `weka.io/mount-options-overrides` (needs `pluginConfig.allowMountOptionOverrides=true`);
  - `PV.spec.mountOptions` (no annotation and no override flag);
  - the PVC annotation `weka.io/mount-options-override`.
- Control: the exclusive set alone, with no `nosync_on_close`, leaves `sync_on_close` in place.
- With the Operator-embedded CSI, this route needs the standalone chart (Operator `csi.installationEnabled: false`) or a change in the Operator. That is a CSI redeployment.

### After the change
- StorageClass for new PVs: `kubectl patch storageclass <sc> --type merge -p '{"mountOptions":["noacl","nosync_on_close"]}'`.
- PV patch or PVC annotation for existing PVs, then a Pod restart.
- In the Pod, `mount -t wekafs` shows neither `acl` nor `sync_on_close`.
