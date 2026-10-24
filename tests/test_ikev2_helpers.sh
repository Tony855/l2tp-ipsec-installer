#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../install-IKEv2_IPSec.sh
source "$SCRIPT_DIR/install-IKEv2_IPSec.sh"

# Keep unit tests isolated from host configuration and system services.
log() { :; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

# Domain validation: accept valid FQDNs and reject malformed/single-label values.
DOMAIN=vpn.example.com
validate_domain || fail 'valid FQDN rejected'
pass 'domain validation accepts valid FQDN'

for DOMAIN in '' example localhost '-bad.example.com' 'bad..example.com' 'vpn.example.com;touch /tmp/pwned'; do
  if ( validate_domain ) >/dev/null 2>&1; then
    fail "invalid domain accepted: $DOMAIN"
  fi
done
pass 'domain validation rejects malformed input'

# Credentials: supported characters pass; unsafe syntax and whitespace fail.
VPN_USER='vpn_user-01@example.com'
export VPN_PASSWORD='long-safe-password-123'
validate_credentials || fail 'valid credentials rejected'
pass 'credential validation accepts supported values'

for VPN_USER in 'bad user' 'bad;user' 'user/name' ''; do
  if ( validate_credentials ) >/dev/null 2>&1; then
    fail "invalid username accepted: $VPN_USER"
  fi
done
VPN_USER='vpnuser'
for bad_password in '' 'contains space' 'quote"bad' 'slash\\bad'; do
  if ( VPN_PASSWORD=$bad_password; validate_credentials ) >/dev/null 2>&1; then
    fail 'invalid password accepted'
  fi
done
pass 'credential validation rejects unsafe values'

# Public IPv4 parser: mock curl so tests do not depend on external network.
curl() { printf '%s' "${MOCK_PUBLIC_IP:-203.0.113.10}"; }
MOCK_PUBLIC_IP=203.0.113.10
[[ $(get_public_ip) == "$MOCK_PUBLIC_IP" ]] || fail 'valid public IPv4 parsing failed'
pass 'public IPv4 parser accepts dotted-quad addresses'

for MOCK_PUBLIC_IP in '999.1.1.1' 'not-an-ip' '192.168.1.1/24'; do
  if ( get_public_ip ) >/dev/null 2>&1; then
    fail "invalid IPv4 accepted: $MOCK_PUBLIC_IP"
  fi
done
pass 'public IPv4 parser rejects malformed and out-of-range octets'

# Firewall helper: existing rules must not be appended; missing rules append once.
calls_file=$(mktemp)
trap 'rm -f "$calls_file"' EXIT
iptables() {
  local IFS=' '
  printf '%s\n' "$*" >> "$calls_file"
  if [[ " $* " == *"-C INPUT -p udp --dport 500"* ]]; then return 0; fi
  if [[ " $* " == *' -C '* ]]; then return 1; fi
  return 0
}

: > "$calls_file"
iptables_ensure INPUT -p udp --dport 500 -j ACCEPT
[[ $(wc -l < "$calls_file") -eq 1 ]] || fail 'existing firewall rule was unexpectedly appended'
grep -Fxq -- '-t filter -C INPUT -p udp --dport 500 -j ACCEPT' "$calls_file" || fail 'firewall check arguments incorrect'

: > "$calls_file"
iptables_ensure -t nat POSTROUTING -s 10.77.0.0/24 -o eth0 -j MASQUERADE
[[ $(wc -l < "$calls_file") -eq 2 ]] || fail 'missing NAT rule was not checked and appended'
grep -Fxq -- '-t nat -C POSTROUTING -s 10.77.0.0/24 -o eth0 -j MASQUERADE' "$calls_file" || fail 'NAT check arguments incorrect'
grep -Fxq -- '-t nat -A POSTROUTING -s 10.77.0.0/24 -o eth0 -j MASQUERADE' "$calls_file" || fail 'NAT append arguments incorrect'
pass 'firewall helper preserves idempotency and NAT rule ordering'

# Backups preserve existing contents and do not fail for absent files.
tmpdir=$(mktemp -d)
trap 'rm -f "$calls_file"; rm -rf "$tmpdir"' EXIT
printf 'preserve-me\n' > "$tmpdir/config"
backup_file "$tmpdir/config"
backup=$(find "$tmpdir" -maxdepth 1 -name 'config.bak.*' -print -quit)
[[ -n $backup && $(cat "$backup") == 'preserve-me' ]] || fail 'backup_file did not preserve contents'
backup_file "$tmpdir/absent"
pass 'configuration backup handles existing and absent files'

printf 'PASS: IKEv2 installer unit tests completed\n'
