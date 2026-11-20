# WEKA CSI plugin: field notes

These notes come from lab tests and from the public source (`weka/csi-wekafs`). Check a newer release before you rely on a detail.

## 1. A kubelet root directory that is not the default breaks CSI registration, with no error

- **Symptom:** each PVC fails with "no available topology found", and each CSINode shows `spec.drivers: null`.
- **Cause:** kubelet runs with a `--root-dir` that is not `/var/lib/kubelet`. The hostPath mounts of the CSI chart use the default, so the registration socket is in a directory that kubelet does not watch.
- **Fix:** set `kubeletPath` in the Helm values to the real root directory and deploy again.
- **Checks:**
  - `journalctl -u kubelet | grep "Plugin Watcher Start"` shows the directory that kubelet watches.
  - Do not accept "the root directory is the default" without this evidence.
  - If a GitOps tool (for example Argo CD) owns the release, it reverts a manual Helm change. Make the change in the source of the release.
- The Operator's node-agent device plugin has the same failure mode (`nodeAgent.kubeletPath`).

## 2. Mounts and the node server (csi-wekafs v2.9)

- The node server makes one shared wekafs mount, and a bind mount per PV into the Pod (`pkg/wekafs/nodeserver.go`).
- The wekafs mount goes away only when the last PV reference drops (`pkg/wekafs/wekafsmount.go`).
- The node server adds the mount options `writecache,sync_on_close` (`NodeServerAdditionalMountOptions` in `pkg/wekafs/nodeserver.go`). It drops `sync_on_close` when the WEKA cluster version does not support it (`pkg/wekafs/volume.go`). For a plain `mount -t wekafs`, the WEKA mount documentation gives `sync_on_close` as disabled by default.
- `mountOptions` in the StorageClass changes the options for the volumes of that class.

## 3. A dead client container with a live mount stops the node server

- **Loop:** a WEKA client container stops while a wekafs mount through it still exists. The node server probe reads the frontend state from the driver and fails with `Not all frontends are connected`. The liveness check kills the node plugin, `csi.sock` goes away, kubelet cannot tear down the volume, and the mount stays.
- **Recovery:** `umount -f <mount path>` on the host, then delete the CSI node Pod. If the stale container stays in the driver, ask WEKA Support.
- **Traps:**
  - A `stat()` on the dead mount path hangs (`ls` of the parent directory, `findmnt --target`). Read `/proc/mounts`.
- A graceful Pod stop with no mounts does not leave a stale container.

## 4. Chart facts

- The chart is a normal Helm repo: `https://weka.github.io/csi-wekafs`.
- The Operator chart pins a CSI image version (`csi.image`). An Operator upgrade can change the CSI version.
- Templates: a controller Deployment, a node DaemonSet and a `CSIDriver` object. See `charts/csi-wekafsplugin/templates/`.
