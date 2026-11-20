# strongSwan client for a FortiGate IKEv2 remote-access VPN (PSK + EAP-MSCHAPv2)

Goal: connect a headless Linux host (here an Oracle Cloud instance) to a FortiGate remote-access VPN that uses IKEv2 with a pre-shared key and EAP user credentials. No FortiClient GUI is available on such a host.

Verified on Ubuntu 22.04 with strongSwan 5.9.5 in 2026-09.

## Why plain strongSwan is enough

- A VPN whose user login is a browser-based SAML flow needs a browser trick on a headless host.
- This FortiClient profile uses **EAP-MSCHAPv2** for the user login. The user name and password travel inside IKEv2. strongSwan supports this natively, so the setup is a config file.
- If the gateway uses SSO or SAML for the EAP step, this method does not apply. Confirm the method first.

## 1. Install strongSwan

Ubuntu or Debian:
```
sudo apt-get update
sudo apt-get install -y strongswan strongswan-pki libcharon-extra-plugins libstrongswan-extra-plugins libstrongswan-standard-plugins
```

- `libcharon-extra-plugins` holds `eap-mschapv2`.
- `libstrongswan-standard-plugins` holds `openssl`, which gives the ECP curves (DH group 19 = `ECP_256`).

Check both before you look for a gateway problem:
```
sudo ipsec listalgs | grep dh-group          # must list ECP_256
sudo ipsec statusall | grep -o 'loaded plugins:.*' | tr ' ' '\n' | grep -E '^(openssl|eap-mschapv2)$'
```

Oracle Linux or RHEL (strongSwan is in EPEL):
```
sudo dnf install -y oracle-epel-release-el9   # or el8
sudo dnf install -y strongswan
```

## 2. Install the config

```
sudo install -m 644 ipsec.conf /etc/ipsec.conf
sudo install -m 600 ipsec.secrets.template /etc/ipsec.secrets
sudo $EDITOR /etc/ipsec.secrets   # the real PSK and the EAP user name and password
```

Replace each `<...>` placeholder in `ipsec.conf`. The file maps the FortiClient settings as follows:

| FortiClient setting | strongSwan equivalent |
|---|---|
| IKEv2 | `keyexchange=ikev2` |
| Phase 1: AES256/SHA256, DH group 19 | `ike=aes256-sha256-ecp256!` (group 19 = NIST ECP256) |
| Phase 1 lifetime 54000 s | `ikelifetime=54000s` |
| Phase 2: AES256/SHA256, PFS DH group 19 | `esp=aes256-sha256-ecp256!` |
| Phase 2 lifetime 14400 s | `lifetime=14400s` |
| PSK + EAP user credentials | `leftauth=eap-mschapv2` / `rightauth=psk` |
| NAT traversal | on by default in strongSwan; see section 4 |

- The `!` at the end of a proposal means "strict": do not negotiate a weaker cipher.
- Use your own values for the ciphers and lifetimes. These are the values of one profile.

## 3. Connect

```
sudo systemctl restart strongswan-starter    # reads ipsec.conf and ipsec.secrets again
sudo ipsec up fortinet-vpn
sudo ipsec statusall fortinet-vpn
```

- **Do not use `sudo ipsec restart` on Ubuntu.** It starts a starter process outside systemd. The unit then shows `inactive`, nothing restarts charon after a reboot, and the daemon stops when the session ends.
- The helpers in `bin/` do the same steps: `vpn-up`, `vpn-down`, `vpn-check`.
- With `auto=add`, the connection is loaded but no IKE packet leaves the host until you run `ipsec up`. Use `auto=start` if the tunnel must come up with the unit.

## 4. Cloud network items

- If the instance is behind a NAT gateway, raw ESP can fail. NAT-T normally changes to ESP in UDP on port 4500. If the tunnel negotiates and no traffic passes, add `forceencaps=yes` to the `conn` block.
- The security list or network security group must permit egress UDP 500 and 4500 to the gateway.

## 5. What the first connection taught us

1. **Auth direction.** FortiGate "PSK + user credentials" on IKEv2 means that the gateway authenticates with the PSK and the client authenticates with EAP: `leftauth=eap-mschapv2` and `rightauth=psk`. With the two reversed, IKE_SA_INIT succeeds and IKE_AUTH gets no reply at all. It looks like a firewall on UDP 4500. It is not.
2. **Full tunnel returned nothing.** With `rightsubnet=0.0.0.0/0` the SA came up, the host sent data and received 0 bytes. The gateway forwards only the destinations that its policy permits. A missing return route on the far side gives the same signature. A full tunnel also takes the cloud resolver and the cloud network, so the host lost DNS and package installs while connected.
3. **The pushed DNS servers can be public resolvers.** Expect target IP addresses, not host names.
4. **Scope the tunnel to private ranges.** Set `rightsubnet` to the three RFC 1918 ranges, or to the real subnets. The FortiGate accepted three selectors in one CHILD_SA. Public traffic then leaves directly.
5. **DNS push fails under AppArmor on Ubuntu** (`DENIED open /run/systemd/resolve/stub-resolv.conf`). Fix without a profile change: set `file = /run/charon.resolv.conf` (see `charon-resolve.conf`). The servers are then recorded and not applied.
6. **Link-local bypass.** `ip rule add to 169.254.0.0/16 lookup main priority 210` keeps the cloud metadata service and resolver out of the tunnel. `vpn-bypass-rules.service` installs it.
7. **Watchdog for a route change on a headless host.** Before an `ipsec up` that can cut your SSH session, arm `sudo systemd-run --unit=vpn-watchdog --on-active=240 /usr/sbin/ipsec down fortinet-vpn`. Stop it with `systemctl stop vpn-watchdog.timer` when you are still connected.
8. **`leftfirewall=yes`.** The updown script adds an INPUT ACCEPT rule for each tunneled source range to the virtual IP, on any port. Hosts on the far side can then open new connections to this host. With `leftfirewall=no`, replies to your outbound sessions still pass, and new inbound connections from the tunnel meet the host firewall. Select the posture on purpose.
9. **MSS and MTU.** The tunnel over a 1500-byte WAN gave an inner MTU of 1422 bytes. strongSwan's routes carry no `mtu`, so the kernel advertises an MSS from the underlay NIC (1448 on a 9000-MTU interface). Interactive ssh works, and a command with a screen of output freezes: large inbound segments are dropped and no ICMP comes back.
   - Clamp the MSS to the inner MTU minus 40 (1382 here). `vpn-bypass-rules.service` does it.
   - Do not set `mtu` on charon's routes. Each CHILD_SA rekey installs the routes again.
   - Do not use `netfilter-persistent save` for it. That saves the full live rule set, with charon's dynamic rules.

## 6. Troubleshooting

- `sudo journalctl -u strongswan-starter -f` during `ipsec up fortinet-vpn`. The `charondebug` line in `ipsec.conf` raises the IKE, config and kernel detail.
- `NO_PROPOSAL_CHOSEN` in phase 1: a cipher or DH mismatch. Confirm the group on the FortiGate side.
- The tunnel is up and no traffic passes: check `forceencaps=yes` and `rightsubnet`.
- EAP is rejected: confirm `eap-mschapv2` against the gateway's EAP method, and that the user name in `ipsec.secrets` matches `eap_identity`.

## Files

| File | Use |
|---|---|
| `ipsec.conf` | The connection; copy to `/etc/ipsec.conf` |
| `ipsec.secrets.template` | Copy to `/etc/ipsec.secrets`, mode 600, and fill in |
| `bin/vpn-up`, `bin/vpn-down`, `bin/vpn-check` | Thin wrappers |
| `vpn-bypass-rules.service` | Oneshot unit: link-local bypass and MSS clamp |
| `charon-resolve.conf` | The resolve plugin with a file that AppArmor permits |

Keep one VPN per host. Two VPN clients on one host collide on routes, DNS and iptables.
