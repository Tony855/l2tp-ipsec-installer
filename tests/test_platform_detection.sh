#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

make_os_file() {
  printf 'ID=%s\nVERSION_ID="%s"\n' "$1" "$2" > "$3"
}
make_os_file debian 13 "$tmp/debian"
make_os_file ubuntu 26.04 "$tmp/ubuntu"
make_os_file centos 9 "$tmp/centos"

run_detection() {
  local file=$1
  OS_RELEASE_FILE="$file" bash -c '
    set -Eeuo pipefail
    # shellcheck source=../install-L2TP_IPSec.sh
    source "$1/install-L2TP_IPSec.sh"
    log() { :; }
    detect_os
  ' _ "$SCRIPT_DIR"
}
run_detection "$tmp/debian"
run_detection "$tmp/ubuntu"
if run_detection "$tmp/centos" >/dev/null 2>&1; then
  printf 'FAIL: non-Debian/Ubuntu distro should be rejected\n' >&2
  exit 1
fi
printf 'PASS: Debian/Ubuntu accepted; non-target distro rejected\n'
