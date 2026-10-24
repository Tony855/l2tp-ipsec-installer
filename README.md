# L2TP/IPsec Installer

Debian/Ubuntu-only installer for an L2TP/IPsec VPN endpoint using the traditional strongSwan `ipsec.conf`/starter backend, `xl2tpd`, PPP and iptables.

> Experimental: CI performs syntax, lint and mocked unit tests. It does not prove end-to-end VPN connectivity on a real VM. Test on a disposable host before production.

## Supported systems

- Debian 12/13 and Ubuntu 22.04/24.04/26.04 (subject to package availability).
- Other distributions are rejected before any installation changes.
- Requires root, systemd, PPP/IPsec kernel support and a reachable public IPv4/NAT mapping.

## Install

```bash
sudo bash install-L2TP_IPSec.sh
```

The script asks for a PSK, username and password, then requires typing `YES` before modifying system configuration. Credentials are written to `/root/vpn-config.txt` with mode 0600.

## Diagnose

```bash
sudo bash install-L2TP_IPSec.sh diagnose
```

## Validation

CI tests Ubuntu 24.04, Ubuntu 26.04, and Debian 13. It runs `bash -n`, ShellCheck, OS-detection tests and mocked firewall helper tests. It does not perform a privileged installation or real client negotiation.

## Notes

- This installer intentionally uses `strongswan-starter` and `ipsec.conf`; it refuses to proceed when `charon-systemd` or `strongswan-swanctl` packages are already installed rather than removing an existing VPN stack.
- L2TP/IPsec with IKEv1 and MS-CHAPv2 is legacy. Use WireGuard or IKEv2 for new deployments when client compatibility allows.
- Configure cloud firewalls separately. Permit UDP 500/4500; UDP 1701 should be restricted to IPsec-protected traffic.
- Config files are backed up before replacement, but this is not a fully transactional installer. Review before use on production hosts.

## License

MIT; see `LICENSE`.