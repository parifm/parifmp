# Oracle Cloud (OCI): change a VM from virtio to SR-IOV (VFIO) networking

From lab tests in 2026-09 with the `oci` CLI. Shape behaviour can change; test on one instance first.

## The API rules

- The instance must be STOPPED: `oci compute instance update --instance-id <id> --launch-options '{"networkType":"VFIO"}' --force`.
- The call refuses while a secondary VNIC or a block volume is attached. Only the primary VNIC and the boot volume can stay.
- **A detach of a secondary VNIC deletes it.** Create the VNICs again afterwards. `attach-vnic --private-ip <old ip>` keeps the IP when it is free. The MAC addresses are new, so update each record that holds a MAC.
- The update is asynchronous. A START immediately after it returns `409` for a while. Retry in a loop.
- The detach command is `oci compute instance detach-vnic --compartment-id <c> --vnic-id <v>`. There is no `vnic-attachment delete`.

## Results by shape

| Shape | Result |
|---|---|
| VM.Standard.E5.Flex | Works. VFIO and `--shape-config` in one update also work. The VNICs become ConnectX virtual functions on `mlx5_core`. |
| VM.Standard.A1.Flex | Refused: "Setting NetworkType in LaunchOptions to VFIO is not supported". The OCI documentation lists the shape under SR-IOV, but the update fails. |
| VM.DenseIO.E4.Flex | Refused: "not valid for the change shape operation", also when stopped with no secondary VNICs. Not tested at launch. |

- For arm64 without virtio on OCI, the option that we found was bare metal.

## Traps

- **Hot-plug desync after a failed change.** A VM that starts with stale virtio devices spends minutes on hot-remove. A VNIC attached in that window shows ATTACHED in the API but does not appear in the guest, and STOP/START does not fix it. Detach those VNICs, then attach them again one at a time. Wait for `lspci` to show each one.
- **A hard STOP can corrupt container image layers** on the node (the images are then pulled again). Use SOFTSTOP.
- **In-place Flex resize and kubelet:** after a change of the CPU count, kubelet with the static CPU policy does not start. Remove `/var/lib/kubelet/cpu_manager_state` and restart kubelet.
- **Launch:** an `ssh_authorized_keys` value with a blank line at the end is rejected ("Invalid format for ssh public key").
- With `netplan`, a MAC match plus `set-name` keeps the interface name and the IP of the primary VNIC across the change.

## What changed for the workload

- Kernel ping to a peer in the same region went from 0.24 ms to 0.13 ms average.
- A DPDK application uses the `mlx5` bifurcated driver on the VFs. It needs no `igb_uio` binding.
