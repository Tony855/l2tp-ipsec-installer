#!/usr/bin/env bash
# Debian/Ubuntu-only L2TP/IPsec installer. Review before production use.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_NAME=${0##*/}
readonly LOG_FILE=/var/log/vpn-install.log
readonly VPN_SUBNET=192.168.42.0/24
readonly VPN_LOCAL_IP=192.168.42.1
readonly VPN_POOL=192.168.42.10-192.168.42.250
readonly IPSEC_CONF=/etc/ipsec.conf
readonly IPSEC_SECRETS=/etc/ipsec.secrets
readonly XL2TPD_CONF=/etc/xl2tpd/xl2tpd.conf
readonly PPP_OPTIONS=/etc/ppp/options.xl2tpd
readonly CHAP_SECRETS=/etc/ppp/chap-secrets

OS=''
VERSION_ID=''
STRONGSWAN_SERVICE=''
DEFAULT_IF=''
PUBLIC_IP=''
VPN_IPSEC_PSK=''
VPN_USER=vpnuser
VPN_PASSWORD=''

log() { printf '[%s] %s\n' "$1" "$2" | tee -a "$LOG_FILE" >&2; }
info() { log INFO "$*"; }
ok() { log OK "$*"; }
warn() { log WARN "$*"; }
die() { log ERROR "$*"; exit 1; }
on_error() { local rc=$? line=${1:-unknown}; log ERROR "第 ${line} 行失败（退出码 ${rc}），日志：${LOG_FILE}"; exit "$rc"; }
trap 'on_error "$LINENO"' ERR

require_root() { [[ $EUID -eq 0 ]] || die '请使用 root 身份运行。'; }
init_log() { touch "$LOG_FILE" || { printf '无法写入日志：%s\n' "$LOG_FILE" >&2; exit 1; }; chmod 600 "$LOG_FILE"; }
check_dependencies() {
  local cmd
  for cmd in awk grep sed ip systemctl; do
    command -v "$cmd" >/dev/null 2>&1 || die "缺少必要命令：$cmd"
  done
}

detect_os() {
  local os_release=${OS_RELEASE_FILE:-/etc/os-release}
  [[ -r $os_release ]] || die "找不到系统信息文件：$os_release"
  # shellcheck disable=SC1090
  . "$os_release"
  OS=${ID:-unknown}
  VERSION_ID=${VERSION_ID:-unknown}
  case "$OS" in debian|ubuntu) ;; *) die "不支持发行版：$OS；仅支持 Debian/Ubuntu。" ;; esac
  [[ $VERSION_ID != unknown && -n $VERSION_ID ]] || die '无法识别系统版本。'
  info "操作系统：$OS $VERSION_ID"
}

check_backend_conflicts() {
  local pkg status
  for pkg in charon-systemd strongswan-swanctl; do
    status=$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)
    if [[ $status == 'install ok installed' ]]; then
      die "检测到 $pkg。当前安装器要求 strongswan-starter/ipsec.conf；为避免破坏现有 VPN，不会自动卸载冲突包。"
    fi
  done
}

get_public_ip() {
  local candidate='' octet
  command -v curl >/dev/null 2>&1 || die '缺少 curl。'
  candidate=$(curl -4fsS --connect-timeout 4 --max-time 8 https://api.ipify.org 2>/dev/null || true)
  if [[ ! $candidate =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    candidate=$(curl -4fsS --connect-timeout 4 --max-time 8 https://ifconfig.me/ip 2>/dev/null || true)
  fi
  if [[ ! $candidate =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    warn '无法自动获取公网 IPv4；请填写客户端实际连接的地址。'
    read -r -p '公网 IPv4：' candidate
  fi
  [[ $candidate =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die '公网 IPv4 格式无效。'
  local -a octets
  IFS=. read -r -a octets <<< "$candidate"
  for octet in "${octets[@]}"; do
    (( 10#$octet <= 255 )) || die 'IPv4 地址格式无效。'
  done
  printf '%s' "$candidate"
}

detect_strongswan_service() {
  local units unit
  units=$(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}')
  for unit in strongswan-starter.service ipsec.service; do
    if grep -Fxq "$unit" <<< "$units"; then
      STRONGSWAN_SERVICE=${unit%.service}
      return 0
    fi
  done
  die '未找到 strongswan-starter.service 或 ipsec.service。'
}

install_dependencies() {
  [[ $OS == debian || $OS == ubuntu ]] || die '内部错误：只允许 Debian/Ubuntu。'
  check_backend_conflicts
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y strongswan-starter strongswan-charon libstrongswan-standard-plugins libcharon-extra-plugins xl2tpd ppp iptables iptables-persistent curl openssl
  command -v ipsec >/dev/null 2>&1 || die '未找到 ipsec 命令。'
  detect_strongswan_service
  if systemctl is-enabled --quiet strongswan.service 2>/dev/null; then
    die 'strongswan.service 已启用，可能使用 charon-systemd；请检查后端冲突。'
  fi
  ok "依赖安装完成；IPsec 服务：$STRONGSWAN_SERVICE"
}

backup_file() {
  local file=$1
  [[ -e $file ]] && cp -a -- "$file" "${file}.bak.$(date +%Y%m%d%H%M%S)"
  return 0
}

validate_credentials() {
  [[ -n $VPN_IPSEC_PSK && $VPN_IPSEC_PSK != *'"'* && $VPN_IPSEC_PSK != *$'\n'* ]] || die 'PSK 不能为空，且不能包含双引号或换行符。'
  [[ -n $VPN_USER && $VPN_USER != *[[:space:]]* && $VPN_USER != *['"\\']* ]] || die '用户名包含不支持的字符。'
  [[ -n $VPN_PASSWORD && $VPN_PASSWORD != *[[:space:]]* && $VPN_PASSWORD != *['"\\']* ]] || die '密码包含不支持的字符。'
}

load_kernel_modules() {
  local module
  for module in ppp_generic ppp_async l2tp_core l2tp_netlink l2tp_ppp; do modprobe "$module" 2>/dev/null || true; done
  if [[ ! -c /dev/ppp ]]; then mknod /dev/ppp c 108 0 2>/dev/null || true; fi
  [[ -c /dev/ppp ]] || die '无法使用 /dev/ppp；请检查宿主机 PPP 模块和设备权限。'
  chmod 600 /dev/ppp
}

configure_ipsec() {
  backup_file "$IPSEC_CONF"; backup_file "$IPSEC_SECRETS"
  cat > "$IPSEC_CONF" <<'IPSEC_EOF'
config setup
    uniqueids=yes
    strictcrlpolicy=no
    charondebug="ike 1, knl 1, cfg 1"

conn %default
    keyexchange=ikev1
    authby=secret
    type=transport
    ike=aes256-sha1-modp2048,aes128-sha1-modp2048,aes256-sha1-modp1024,aes128-sha1-modp1024!
    esp=aes256-sha1,aes128-sha1,3des-sha1!
    ikelifetime=24h
    keylife=1h
    rekeymargin=3m
    keyingtries=3
    dpddelay=30
    dpdtimeout=120
    dpdaction=clear
    left=%any
    leftprotoport=17/1701
    right=%any
    rightprotoport=17/%any

conn l2tp-psk
    auto=add
IPSEC_EOF
  printf '%%any %%any : PSK "%s"\n' "$VPN_IPSEC_PSK" > "$IPSEC_SECRETS"
  chmod 600 "$IPSEC_SECRETS"
}

configure_xl2tpd() {
  backup_file "$XL2TPD_CONF"; backup_file "$PPP_OPTIONS"; backup_file "$CHAP_SECRETS"
  install -d -m 755 /etc/xl2tpd /etc/ppp
  cat > "$XL2TPD_CONF" <<EOF2
[global]
port = 1701

[lns default]
ip range = $VPN_POOL
local ip = $VPN_LOCAL_IP
refuse chap = yes
refuse pap = yes
require authentication = yes
name = L2TP_VPN
ppp debug = no
pppoptfile = $PPP_OPTIONS
length bit = yes
EOF2
  cat > "$PPP_OPTIONS" <<'PPP_EOF'
require-mschap-v2
refuse-eap
refuse-pap
refuse-chap
ms-dns 1.1.1.1
ms-dns 8.8.8.8
mtu 1400
mru 1400
lcp-echo-interval 30
lcp-echo-failure 4
connect-delay 5000
PPP_EOF
  touch "$CHAP_SECRETS"
  chmod 600 "$CHAP_SECRETS"
  awk -v user="$VPN_USER" '$1 != user { print }' "$CHAP_SECRETS" > "${CHAP_SECRETS}.tmp"
  printf '%s * %s *\n' "$VPN_USER" "$VPN_PASSWORD" >> "${CHAP_SECRETS}.tmp"
  install -m 600 "${CHAP_SECRETS}.tmp" "$CHAP_SECRETS"
  rm -f "${CHAP_SECRETS}.tmp"
}

enable_ip_forwarding() {
  install -d -m 755 /etc/sysctl.d
  printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-l2tp-ipsec.conf
  sysctl --system >/dev/null
  [[ $(sysctl -n net.ipv4.ip_forward) == 1 ]] || die 'IPv4 转发未生效。'
}

iptables_ensure() {
  local table=filter chain
  if [[ ${1:-} == -t ]]; then
    [[ $# -ge 3 ]] || die 'iptables_ensure 参数不足。'
    table=$2; chain=$3; shift 3
  else
    [[ $# -ge 1 ]] || die 'iptables_ensure 缺少链名称。'
    chain=$1; shift
  fi
  if iptables -t "$table" -C "$chain" "$@" 2>/dev/null; then
    return 0
  fi
  iptables -t "$table" -A "$chain" "$@"
}

configure_firewall() {
  DEFAULT_IF=$(ip -4 route show default | awk 'NR==1 {print $5}')
  [[ -n $DEFAULT_IF ]] || die '找不到 IPv4 默认路由接口。'
  iptables_ensure -t nat POSTROUTING -s "$VPN_SUBNET" -o "$DEFAULT_IF" -j MASQUERADE
  iptables_ensure FORWARD -s "$VPN_SUBNET" -j ACCEPT
  iptables_ensure FORWARD -d "$VPN_SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  iptables_ensure INPUT -p udp --dport 500 -j ACCEPT
  iptables_ensure INPUT -p udp --dport 4500 -j ACCEPT
  iptables_ensure INPUT -p udp --dport 1701 -m policy --dir in --pol ipsec -j ACCEPT
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save
  else
    warn '未找到 netfilter-persistent；防火墙规则可能不会在重启后保留。'
  fi
}

start_services() {
  systemctl daemon-reload
  systemctl enable "$STRONGSWAN_SERVICE" xl2tpd
  systemctl restart "$STRONGSWAN_SERVICE" xl2tpd
  systemctl is-active --quiet "$STRONGSWAN_SERVICE" || die "$STRONGSWAN_SERVICE 未启动。"
  systemctl is-active --quiet xl2tpd || die 'xl2tpd 未启动。'
  ipsec status >/dev/null || die 'ipsec status 失败；请检查配置和日志。'
}

show_config() {
  local file=/root/vpn-config.txt
  cat > "$file" <<EOF3
L2TP/IPsec VPN
Server IPv4: $PUBLIC_IP
IPsec PSK: $VPN_IPSEC_PSK
Username: $VPN_USER
Password: $VPN_PASSWORD
Ports: UDP 500/4500; UDP 1701 protected by IPsec policy
EOF3
  chmod 600 "$file"
  ok "客户端配置已保存：$file（权限 600）"
}

diagnose() {
  printf '系统：%s %s\n' "$OS" "$VERSION_ID"
  systemctl --no-pager --full status "${STRONGSWAN_SERVICE:-strongswan-starter}" xl2tpd 2>&1 || true
  ipsec statusall 2>&1 || true
  ip -4 route show default || true
  sysctl net.ipv4.ip_forward 2>&1 || true
  journalctl -u "${STRONGSWAN_SERVICE:-strongswan-starter}" -n 30 --no-pager 2>&1 || true
  journalctl -u xl2tpd -n 30 --no-pager 2>&1 || true
}

prompt_credentials() {
  VPN_IPSEC_PSK="vpn$(openssl rand -hex 16)"
  VPN_PASSWORD=$(openssl rand -hex 16)
  local input
  read -r -p 'IPsec PSK（回车使用随机值）: ' input || true
  [[ -n ${input:-} ]] && VPN_IPSEC_PSK=$input
  read -r -p "VPN 用户名（默认 $VPN_USER）: " input || true
  [[ -n ${input:-} ]] && VPN_USER=$input
  read -r -s -p 'VPN 密码（回车使用随机值）: ' input || true
  printf '\n'
  [[ -n ${input:-} ]] && VPN_PASSWORD=$input
  validate_credentials
}

main() {
  require_root
  init_log
  check_dependencies
  detect_os
  if [[ ${1:-} == diagnose ]]; then
    detect_strongswan_service || true
    diagnose
    exit 0
  fi
  [[ ${1:-} == '' || ${1:-} == install ]] || die "用法：$SCRIPT_NAME [install|diagnose]"
  PUBLIC_IP=$(get_public_ip)
  prompt_credentials
  warn '将修改 IPsec、xl2tpd、PPP、sysctl 和 iptables 配置；现有配置会先备份。'
  read -r -p '输入 YES 确认继续：' confirm
  [[ $confirm == YES ]] || die '用户取消安装。'
  install_dependencies
  load_kernel_modules
  configure_ipsec
  configure_xl2tpd
  enable_ip_forwarding
  configure_firewall
  start_services
  show_config
  diagnose
  ok '安装步骤完成；请使用真实客户端验证协商、认证、DNS 和公网流量。'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "${1:-}"; fi
