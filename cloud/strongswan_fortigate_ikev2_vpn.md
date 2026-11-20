# strongSwan client for a FortiGate IKEv2 remote-access VPN (PSK + EAP-MSCHAPv2)

How to connect a headless Linux host to a FortiGate remote-access VPN with plain strongSwan. Verified on Ubuntu in 2026-09.

## Why plain strongSwan is enough

- EAP-MSCHAPv2 carries the user name and password inside IKEv2. No browser is necessary.
- If the gateway uses SSO or SAML for the EAP step, this method does not apply. Confirm the method first.

## The settings that matter

| Item | Value |
|---|---|
| Who authenticates with what | The gateway authenticates with the PSK. The client authenticates with EAP. |
| strongSwan (`ipsec.conf`) | `leftauth=eap-mschapv2`, `rightauth=psk`, `eap_identity=<user>` |
| FortiClient DH group 19 | strongSwan `ecp256` |

- **If you reverse the two auth lines,** the FortiGate drops IKE_AUTH with no message after a clean IKE_SA_INIT. This looks like a firewall on UDP 4500. It is not.

## Traps

1. **Full tunnel can blackhole the client.** A FortiGate that offers traffic selector 0.0.0.0/0 can return nothing for internet destinations. The client then loses its own internet and DNS. Set `rightsubnet` to the private ranges or to the real subnets.
2. **AppArmor and DNS on Ubuntu.** AppArmor stops charon's resolve plugin from writing the systemd-resolved stub. Set `file = /run/charon.resolv.conf` for the resolve plugin.
3. **Restart.** `sudo ipsec restart` detaches charon from systemd on Ubuntu. Use `systemctl restart strongswan-starter`.
4. **NAT.** If the client is behind a NAT gateway, try `forceencaps=yes`.
5. **MSS and MTU.** The tunnel over a 1500-byte WAN gives an inner MTU near 1422 bytes. strongSwan's routes carry no `mtu`, so the client advertises an MSS from the underlay NIC. Interactive ssh works, and bulk output freezes: large inbound segments are dropped and no ICMP comes back.
   - Clamp it: `iptables -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -d <remote scope> -j TCPMSS --set-mss <inner MTU - 40>`.
   - Do not set `mtu` on charon's routes. Each rekey removes it.

## Layout

- Keep one VPN per host. Two VPN clients on one host collide on routes, DNS and iptables.
- Keep the PSK and the password in `ipsec.secrets` with mode 600. Do not put them on a command line.
