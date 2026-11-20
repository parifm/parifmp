# WEKA on Oracle Cloud (OCI): VNIC and firewall notes

From lab builds in 2026-07 to 2026-10 (WEKA 4.4 and 5.1, VM.Standard.E5.Flex clients). Personal notes, not WEKA documentation.

## 1. Add DPDK NICs to a WEKA client

- **Do not give the dataplane VNICs kernel IP addresses.**
  - A static IP on each dataplane NIC adds a connected route for the subnet at metric 0. That route is better than the route of the primary NIC (metric 100).
  - Traffic to the backends then leaves through a dataplane NIC, and WEKA binds that NIC to DPDK during start.
  - Symptom: the management process restarts in a loop ("Starting wekanode slot 0 ... without assigned core"), the container does not join, and the mount fails after about 6 minutes with "Container client did not become ready in time".
  - Fix: flush the address and set the link down on each dataplane NIC, and remove their netplan files. WEKA reads the IP, gateway and netmask of each port from the OCI metadata by MAC address.
- **Two limits per OCPU** (see `oci compute shape list`): E5.Flex gives 1 VNIC and 1 Gbps for each OCPU.
  - An 8-OCPU client has at most 8 VNICs (1 primary and 7 dataplane) and about 8 Gbps.
  - More NICs above the bandwidth limit give nothing. Measured: 1 core with 1 NIC gave 4.72 GiB/s across 5 clients, and 7 cores with 7 NICs gave 4.87 GiB/s.
  - More client bandwidth needs more OCPUs, not more NICs.
- **Mount syntax:** `mount -t wekafs -o core=4,core=5,net=enp1s0,net=enp2s0 <backend-ips>/<fs> /mnt/weka`. Give all options in one `-o` list.
- **Attach VNICs one at a time.** `oci compute instance attach-vnic` has no wait option, and OCI does one attachment at a time for an instance. Attach, poll `vnic-attachment list` until the state is ATTACHED, then attach the next one. A second attach during the first returns 409.

## 2. A cluster with several VNICs on one subnet

- **Use the admin NIC IP as the management IP on cloud instances.**
  - The containers take the dataplane NICs into DPDK at container setup. A management IP on a dataplane address is then reachable only through the userspace network stacks of the peers.
  - During cluster formation this is a bootstrap loop: the join cycles through the endpoints with 2-second timeouts and no errors, and `weka cluster create` is very slow.
  - Fix: set `--management-ips` and `--join-ips` to the IP of the default-route NIC of each host. Read the IP at run time, because it comes from DHCP.
  - An on-premises cluster normally keeps the management IP on the dataplane network.
- **Network security group.** If the subnet security list permits no ingress, each new VNIC needs the NSG (`--nsg-ids`) and `--skip-source-dest-check true`. Without them the VNIC drops all inbound traffic, and OCI applies this to DPDK traffic also.
- **Disproved, do not test again:** a reply blackhole from the OCI source/destination check, or a need for per-VNIC source-based routing. Kernel paths between all VNIC IPs connected at once.

## 3. The stock firewall comes back after a reboot

- Some OCI Ubuntu images have a restrictive `/etc/iptables/rules.v4` (established, ICMP, loopback, port 22, then `REJECT icmp-host-prohibited`) with `netfilter-persistent` enabled.
- A deploy script that removes the REJECT rules only at run time is undone by any reboot, for example after a kernel update.
- WEKA can stay healthy, because its connections start outbound and the firewall tracks them. The problem appears on new inbound connections: a benchmark server port, a new protocol service.
- **Signature:** "No route to host" while ssh works.
- **Check:** `iptables -S INPUT` and `uptime -s`. The nodes that rebooted are the nodes with the stock rules.
- **Fix on a plain host:** add the ACCEPT rules again, then run `netfilter-persistent save` on each node so that the rules survive the next reboot.
- **On a Kubernetes node, do not run `netfilter-persistent save`.** See `../k8s/arm64_64k_client_notes.md`.
