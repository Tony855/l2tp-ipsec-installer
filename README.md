# L2TP/IPsec and IKEv2/IPsec Installers

Debian/Ubuntu VPN installers using the traditional strongSwan `ipsec.conf` / starter backend.

> Experimental: GitHub Actions validates Bash syntax, ShellCheck, mocked firewall logic, OS detection and package dependency resolution. It does not prove end-to-end VPN connectivity on a real VM. Test on a disposable host before production.

## Supported systems

- Debian 12/13 and Ubuntu 22.04/24.04/26.04, subject to package availability.
- Other distributions are rejected before installation changes.
- Requires root, systemd, kernel IPsec support and a reachable public IPv4 address.
- Do not run either installer on a production host without reviewing the configuration backups and existing VPN stack.

## L2TP/IPsec installer

```bash
sudo bash install-L2TP_IPSec.sh
```

Prompts for an IPsec PSK, username and password. Requires typing `YES` before modifying system configuration. Credentials are saved in `/root/vpn-config.txt` with mode 0600.

## IKEv2/IPsec installer

```bash
sudo bash install-IKEv2_IPSec.sh
```

The IKEv2 installer uses a DNS hostname and a trusted Let's Encrypt certificate, then authenticates users with EAP-MSCHAPv2. The domain must resolve to this server's public IPv4 address. TCP port 80 must be reachable during HTTP-01 certificate issuance; UDP 500 and UDP 4500 must be allowed by the server/cloud firewall.

The installer prompts for a domain, username and password (minimum 12 characters), then requires typing `YES` before changes. Client settings are saved to `/root/ikev2-vpn-config.txt` with mode 0600. Certbot renewal uses a deploy hook to restart the detected strongSwan starter service.

**Important:** Both installers use the same `/etc/ipsec.conf` and `/etc/ipsec.secrets`. Running one after the other backs up and replaces the other's IPsec configuration, so the previous protocol's connection will stop working. They are not yet a combined simultaneous L2TP + IKEv2 configuration.

## Diagnose

For either installation:

```bash
sudo bash install-L2TP_IPSec.sh diagnose
sudo bash install-IKEv2_IPSec.sh diagnose
```

## Detailed deployment guide (Chinese)

See [`docs/DEPLOYMENT_GUIDE_ZH-CN.md`](docs/DEPLOYMENT_GUIDE_ZH-CN.md) for step-by-step Debian/Ubuntu deployment, DNS and firewall preparation, IKEv2/L2TP installation, client settings, verification, troubleshooting, backups and rollback.

## CI validation

GitHub Actions checks Ubuntu 24.04, Ubuntu 26.04 and Debian 13. CI runs `bash -n`, ShellCheck, mocked firewall tests, OS-detection tests and simulates dependency resolution for both installers. It does not run a privileged install or negotiate a real VPN tunnel.

## Security notes

- IKEv2 uses a publicly trusted certificate and EAP-MSCHAPv2; use strong, unique user passwords.
- L2TP/IPsec with IKEv1 and MS-CHAPv2 is legacy. Prefer IKEv2 or WireGuard for new deployments.
- Configure cloud firewalls separately. For IKEv2 allow UDP 500/4500 and TCP 80 only as needed for certificate issuance/renewal; for L2TP also permit UDP 1701 only when protected by IPsec policy.
- Installers back up configuration files before replacement, but are not fully transactional.
- Review the system's existing firewall policy before running either installer.

## License

MIT; see `LICENSE`.
