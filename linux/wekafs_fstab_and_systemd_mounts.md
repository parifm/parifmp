# Mount wekafs at boot: systemd units, fstab options and autofs

Personal notes, not WEKA documentation. The first draft of this page was written with an AI assistant from field notes; the systemd options are standard and you can check them in `systemd.mount(5)`. Check the WEKA documentation for the mount options of your release.

## The problem

- A `wekafs` mount needs the `weka-agent` service. The agent is a userspace process.
- At boot, systemd turns each `/etc/fstab` line into a mount unit and starts the units in parallel with the services. Nothing orders a plain fstab line after the agent.
- Result: a mount at boot fails now and then. A slow NIC or driver initialization makes it more frequent.
- Many `wekafs` lines in fstab start at the same time, which makes failures more likely.

## Option 1 (most reliable): a systemd mount unit

`/etc/systemd/system/mnt-weka.mount` (the file name must match the mount point):

```ini
[Unit]
Description=WEKA mount
After=network-online.target weka-agent.service
Requires=weka-agent.service

[Mount]
What=<backend>/<filesystem>
Where=/mnt/weka
Type=wekafs
Options=<mount options>

[Install]
WantedBy=multi-user.target
```

- `After=` orders the mount after the network and the agent.
- `Requires=` makes the agent a hard dependency: if the agent does not start, the mount is not tried.
- Enable it with `systemctl daemon-reload && systemctl enable --now mnt-weka.mount`.

## Option 2: fstab with dependency options

| Option | Effect |
|---|---|
| `_netdev` | Marks a network mount, so that it waits for the network |
| `x-systemd.requires=weka-agent.service` | The mount unit requires the agent |
| `x-systemd.mount-timeout=infinity` | No timeout while the agent starts |
| `x-systemd.requires-mounts-for=<first mount point>` | Chains a second filesystem after the first one |

Example:

```
<backend-1>,<backend-2>,<backend-3>/<fs> /mnt/weka/<fs> wekafs _netdev,x-systemd.requires=weka-agent.service,x-systemd.mount-timeout=infinity,<mount options> 0 0
```

- With more than one `wekafs` line, chain each later line to the first mount with `x-systemd.requires-mounts-for=`. Sequential mounts were more reliable than parallel mounts.

## Option 3: autofs for many filesystems

- With tens or hundreds of filesystems, mount on demand with autofs. Boot is faster and nothing mounts until it is used.
- autofs unmounts an idle filesystem after a timeout.

## NIC items that make the race worse

- Use the correct driver for the NIC (for Broadcom NetXtreme-E: `bnxt_en`) at a version that the WEKA documentation lists.
- IOMMU settings can add latency or cause timeouts on some NICs. If mounts time out only on one NIC model, compare the IOMMU mode with a host that works.
- On a host with more than one interface, name the management IP in the mount options, so that the traffic leaves through the interface that you intend.

## References

- `systemd.mount(5)`: https://www.freedesktop.org/software/systemd/man/systemd.mount.html
- docs.weka.io, *Mounting filesystems*
