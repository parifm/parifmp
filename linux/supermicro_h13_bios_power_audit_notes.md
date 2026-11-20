# Supermicro H13 (AMD EPYC 9005) BIOS and power audit: notes

From an audit of 51 storage servers of one model in 2026-09: Supermicro H13 single-socket boards, EPYC 96-core with SMT off, BIOS dumps taken in-band with Supermicro Update Manager (SUM). Personal notes.

## 1. The Workload Profile hides settings

- This BIOS generation has a master selector, `Workload Profile` (default Disabled).
- When a profile is selected, the BIOS hides these items: Global C-state Control, Determinism Control and Determinism Enable, NUMA Nodes Per Socket, Power Profile Selection, SR-IOV and Core Performance Boost.
- **Redfish `Systems/1/Bios` exports only the items that are visible.** A tool that reads or sets BIOS values through Redfish does not see the hidden items, and it skips them with no error.
  - In this fleet, a Redfish-based settings tool could handle 4 of its 8 keys (SMT, IOMMU, DF C-states, SRAT L3). The other 4 were hidden.
- An in-band SUM dump shows the stored values of the hidden items. Use it to compare a fleet.
- The fan mode is a BMC OEM setting (`ipmitool raw 0x30 0x45 0x00`). It is not in BIOS Setup.

## 2. Compare a fleet

- Dump each node with SUM, then diff the XML files. In this fleet each value was identical on all 51 nodes.
- SUM in-band needs no BMC IP and no credentials.
- The Redfish host interface (a USB network device) exists but is not configured by default. The host must give itself a link-local address. Check for an existing 169.254/16 route first.

## 3. Is the CPU power-limited? Measure with RAPL

- Read the package energy counter (`/sys/class/powercap/intel-rapl:0/energy_uj`, root only) twice and divide by the time. Read the frequency of the busy cores in the same window.
- Result here: 34 of 96 cores in busy-poll loops on each node, package power 384 to 400 W with a mean of 393 W. That is the package power limit (PPT) of this CPU.
- **Meaning:** the fleet runs at the power limit with no margin. Each added load decreases the frequency of the polling cores. Busy-core frequency was 4,139 to 4,361 MHz, a 5.2% spread between nodes at the same load.
- "Determinism = Power" was in effect. That is why all nodes sit at the same limit.
- An idea that we did not test: enable Global C-state Control so that the 62 idle cores can enter a deep C-state and give power budget back to the polling cores. This needs the Workload Profile set to Disabled and a reboot.

## 4. Small anomalies that a fleet diff finds

- One node reported half of the median BMC node power with a normal package power. Suspect one of the two power supplies (redundancy lost).
- One drive reported a different security feature set from all the others. It was probably a field replacement that missed the provisioning step.
- Three nodes had the PXE entries of one NIC at the end of the boot order. The device was absent at one POST. This is cosmetic.
