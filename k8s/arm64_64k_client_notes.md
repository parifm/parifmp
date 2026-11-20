# WEKA Operator client on arm64 with a 64k-page kernel: build notes

From lab builds on Oracle Cloud (OCI) with Operator v1.14.2, WEKA 5.1, Kubernetes 1.34, CRI-O and Calico IPIP, on Ubuntu 22.04 with the `generic-64k` HWE kernel. Personal notes, not WEKA documentation.

## Images

- The `weka-in-container`, `weka-operator` and `csi-wekafs` images that we used were multi-arch (amd64 and arm64).

## Boot the 64k kernel

- On an OCI Ubuntu image the `oracle` kernel sorts above the `generic-64k` kernel, so an install of the 64k kernel does not boot it.
- Pin the kernel by GRUB menu id in a file in `/etc/default/grub.d/`, then check `grep 'set default=' /boot/grub/grub.cfg`. The first hit is the `${next_entry}` placeholder.
- A `GRUB_DEFAULT=0` image boots the newest kernel that unattended upgrades staged. The Node then needs a driver build for that kernel.
- Install `linux-modules-extra` for each kernel that you boot. See the verbs note below.

## Hugepages

- The sizes on a 64k arm64 kernel are 2 MiB, 512 MiB and 16 GiB. **The default is 512 MiB.**
- `vm.nr_hugepages=N` and a bare `hugepages=N` allocate 512 MiB pages. `N=1024` reserves 512 GiB.
- `/proc/meminfo` `HugePages_Total` counts only the default size.
- The Operator requests `hugepages-2Mi`. Create the 2 MiB pool with `hugepagesz=2M hugepages=<node>:<count>` on the kernel command line, or write the size-specific sysfs file at run time.
- You do not need `default_hugepagesz=2M`. On a shared GPU node, do not change the default: other software expects it.
- If the pages go to the 512 MiB pool, kubelet advertises `hugepages-512Mi` and the client Pod stays Pending on `hugepages-2Mi`.
- 512 MiB pages can be allocated at run time through sysfs when memory is free.

## Firewall on the stock OCI Ubuntu image

- The image has `REJECT icmp-host-prohibited` rules at the end of INPUT and FORWARD.
- The FORWARD rule is before the rule that Calico appends. It rejects IPIP traffic to local Pods after decapsulation: other Nodes get "No route to host" at once, while Pods on this Node can still connect out. It also blocks kubelet port 10250 from the control plane.
- Remove the rules, or add ACCEPT rules for the Pod and Service CIDRs before them.
- **Do not run `netfilter-persistent save` on a Kubernetes Node.** The saved file refers to Calico and kube-proxy chains. The restore fails at boot and no rules load. Keep the small ACCEPT-only rules files.

## Network egress

- A subnet whose only default route is an Internet Gateway gives no internet to a VNIC without a public IP. Package and image pulls time out, while cluster traffic is good. Check the route table before you assume NAT.

## Operator flow

- A `drivers-builder` WekaContainer with `nodeSelector kubernetes.io/arch=arm64` first shows a JSON parse error in its status while its discovery Pod pulls the image. That error is not final.
- The driver build took about 9 minutes on 8 cores.
- `kubeadm join` makes the hostname lowercase.
- Do not label the new Node with the `nodeSelector` of an existing WekaClient. That clones the existing client onto it. Use a dedicated label and a new WekaClient.
- A wekafs CSI volume root can have mode 000. An unprivileged test needs a directory with permissions inside it.

## DPDK on a bare-metal arm64 Node with ConnectX NICs

- **The verbs stack is a prerequisite.** The stock image has `linux-modules` but not `linux-modules-extra`, so `mlx5_ib` and `ib_uverbs` are absent and `/dev/infiniband` does not exist. The WEKA frontends exit at once. The symptom reads like a core-assignment fault.
  - Fix: `apt-get install linux-modules-extra-$(uname -r) && modprobe mlx5_ib`.
- **Secondary VNICs on OCI bare metal are VLAN sub-interfaces, not PCI devices.** Map them onto SR-IOV VFs: set `sriov_numvfs`, then for each VF set the VNIC MAC and VLAN tag with `ip link set <pf> vf <i> mac <mac> vlan <tag> spoofchk off trust on`. Persist this with a oneshot systemd unit.
- **Do not put dataplane VFs on the same physical port as the untagged management VNIC.** Frames from a VF to the PF keep the VLAN tag, and the untagged PF drops them. The Node then connects to each other host and not to itself, and the cluster refuses the join for partial connectivity.
- **The NIC, the hugepages and the CPUs must be on one NUMA node** when the memory manager policy is `Static`. See `numa_core_pinning_guide.md`.
- A bare-metal reboot took about 35 minutes.

## Change between the 4k and 64k kernel

- The set of hugepage pools changes, so kubelet refuses to start: "the expected machine state is different from the real one". Remove `/var/lib/kubelet/cpu_manager_state` and `memory_manager_state`, then restart kubelet.
- The driver build is per kernel version. Check the driver distribution for the kernel before you build again.

## Performance note

- On the arm64 VM shape the network path had a higher round-trip time than the x86 VM shape (1.3 to 1.9 times). Single-stream flush and 1 MiB direct I/O were slower by about the same ratio. Small I/O and parallel streams were equal.
- This is a property of that VM network path. Do not use it to compare ARM with x86, or 64k with 4k.
