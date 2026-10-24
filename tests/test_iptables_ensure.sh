#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../install-L2TP_IPSec.sh
source "$SCRIPT_DIR/install-L2TP_IPSec.sh"

calls_file=$(mktemp)
trap 'rm -f "$calls_file"' EXIT
iptables() {
  printf '%s\n' "$*" >> "$calls_file"
  if [[ " $* " == *' -C INPUT -p udp --dport 500 '* ]]; then
    return 0
  elif [[ " $* " == *' -C '* ]]; then
    return 1
  fi
  return 0
}

: > "$calls_file"
iptables_ensure -t nat POSTROUTING -s 192.168.42.0/24 -o eth0 -j MASQUERADE
[[ $(wc -l < "$calls_file") -eq 2 ]]
grep -Fxq -- '-t nat -C POSTROUTING -s 192.168.42.0/24 -o eth0 -j MASQUERADE' "$calls_file"
grep -Fxq -- '-t nat -A POSTROUTING -s 192.168.42.0/24 -o eth0 -j MASQUERADE' "$calls_file"

: > "$calls_file"
iptables_ensure INPUT -p udp --dport 500 -j ACCEPT
[[ $(wc -l < "$calls_file") -eq 1 ]]
grep -Fxq -- '-t filter -C INPUT -p udp --dport 500 -j ACCEPT' "$calls_file"
printf 'PASS: iptables helper argument ordering and idempotency\n'
