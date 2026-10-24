#!/usr/bin/env bash
# IKEv2/IPsec VPN installer for Debian and Ubuntu using strongSwan starter.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_NAME=${0##*/}
readonly LOG_FILE=/var/log/vpn-install.log
readonly IPSEC_CONF=/etc/ipsec.conf
readonly IPSEC_SECRETS=/etc/ipsec.secrets
readonly VPN_POOL=10.77.0.10-10.77.0.250
readonly VPN_SUBNET=10.77.0.0/24

OS=''
VERSION_ID=''
STRONGSWAN_SERVICE=''
DEFAULT_IF=''
PUBLIC_IP=''
DOMAIN=''
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
    [[ $status == 'install ok installed' ]] && die "检测到 $pkg。为避免破坏现有 VPN，不会自动卸载冲突包。"
  done
}

validate_domain() {
  [[ $DOMAIN =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]] || die '域名格式无效；IKEv2 安装需要指向此服务器公网 IPv4 的有效域名。'
}

validate_credentials() {
  [[ -n $VPN_USER && $VPN_USER =~ ^[a-zA-Z0-9_.@-]{1,64}$ ]] || die '用户名只能包含字母、数字、下划线、点、@ 和连字符。'
  [[ -n $VPN_PASSWORD && $VPN_PASSWORD != *[[:space:]]* && $VPN_PASSWORD != *['"\\']* ]] || die '密码不能为空，且不能包含空白、引号或反斜杠。'
}

get_public_ip() {
  local candidate='' octet
  candidate=$(curl -4fsS --connect-timeout 4 --max-time 8 https://api.ipify.org 2>/dev/null || true)
  [[ $candidate =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die '无法自动获取公网 IPv4；请先确认服务器可访问公网 IPv4 查询服务。'
  local -a octets
  IFS=. read -r -a octets <<< "$candidate"
  for octet in "${octets[@]}"; do (( 10#$octet <= 255 )) || die '检测到无效的 IPv4 地址。'; done
  printf '%s' "$candidate"
}

detect_strongswan_service() {
  local units unit
  units=$(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}')
  for unit in strongswan-starter.service ipsec.service; do
    if grep -Fxq "$unit" <<< "$units"; then STRONGSWAN_SERVICE=${unit%.service}; return 0; fi
  done
  die '未找到 strongswan-starter.service 或 ipsec.service。'
}

install_dependencies() {
  check_backend_conflicts
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y strongswan-starter strongswan-charon libstrongswan-standard-plugins libcharon-extra-plugins libcharon-extauth-plugins iptables iptables-persistent curl openssl certbot
  command -v ipsec >/dev/null 2>&1 || die '未找到 ipsec 命令。'
  detect_strongswan_service
  if systemctl is-enabled --quiet strongswan.service 2>/dev/null; then die 'strongswan.service 已启用，可能使用 charon-systemd；请先检查现有 VPN 后端。'; fi
}

backup_file() {
  local file=$1
  if [[ -e $file ]]; then cp -a -- "$file" "${file}.bak.$(date +%Y%m%d%H%M%S)"; fi
  return 0
}

obtain_certificate() {
  local live_dir="/etc/letsencrypt/live/$DOMAIN"
  if [[ -s "$live_dir/fullchain.pem" && -s "$live_dir/privkey.pem" ]]; then
    info "检测到现有证书：$DOMAIN；将复用该证书。"
  else
    if systemctl is-active --quiet nginx 2>/dev/null || systemctl is-active --quiet apache2 2>/dev/null; then
      die '检测到 Nginx/Apache 正在运行。请先安排 HTTP-01 证书签发（TCP 80），避免中断现有网站；脚本不会自动停止 Web 服务。'
    fi
    certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$DOMAIN"
  fi
  [[ -s "$live_dir/fullchain.pem" && -s "$live_dir/privkey.pem" ]] || die '未找到有效的完整证书和私钥。'
  # Use Certbot's stable live symlinks so renewals do not leave stale copies.
}

configure_ipsec() {
  backup_file "$IPSEC_CONF"; backup_file "$IPSEC_SECRETS"
  cat > "$IPSEC_CONF" <<EOF2
config setup
    uniqueids=never
    strictcrlpolicy=no
    charondebug="ike 1, knl 1, cfg 1"

conn ikev2-eap
    auto=add
    keyexchange=ikev2
    type=tunnel
    fragmentation=yes
    forceencaps=yes
    dpdaction=clear
    dpddelay=300s
    rekey=no
    left=%any
    leftid=@$DOMAIN
    leftauth=pubkey
    leftcert=/etc/letsencrypt/live/$DOMAIN/fullchain.pem
    leftsendcert=always
    leftsubnet=0.0.0.0/0
    right=%any
    rightid=%any
    rightauth=eap-mschapv2
    rightsourceip=$VPN_POOL
    rightdns=1.1.1.1,8.8.8.8
    rightsendcert=never
    eap_identity=%identity
    ike=aes256-sha256-modp2048,aes128-sha256-modp2048!
    esp=aes256-sha256,aes128-sha256!
EOF2
  cat > "$IPSEC_SECRETS" <<EOF3
: RSA /etc/letsencrypt/live/$DOMAIN/privkey.pem
$VPN_USER : EAP "$VPN_PASSWORD"
EOF3
  chmod 600 "$IPSEC_SECRETS"
}

enable_ip_forwarding() {
  install -d -m 755 /etc/sysctl.d
  printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-ikev2-ipsec.conf
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
  if iptables -t "$table" -C "$chain" "$@" 2>/dev/null; then return 0; fi
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
  if command -v netfilter-persistent >/dev/null 2>&1; then netfilter-persistent save; else warn '未找到 netfilter-persistent；防火墙规则可能不会在重启后保留。'; fi
}

install_renewal_hook() {
  local hook=/etc/letsencrypt/renewal-hooks/deploy/ikev2-strongswan-reload.sh
  install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
  cat > "$hook" <<EOFHOOK
#!/usr/bin/env bash
set -Eeuo pipefail
systemctl restart "$STRONGSWAN_SERVICE"
EOFHOOK
  chmod 750 "$hook"
}

start_services() {
  systemctl daemon-reload
  systemctl enable "$STRONGSWAN_SERVICE"
  systemctl restart "$STRONGSWAN_SERVICE"
  systemctl is-active --quiet "$STRONGSWAN_SERVICE" || die "$STRONGSWAN_SERVICE 未启动。"
  ipsec status >/dev/null || die 'ipsec status 失败；请检查 strongSwan 配置和日志。'
}

show_config() {
  local file=/root/ikev2-vpn-config.txt
  cat > "$file" <<EOF4
IKEv2/IPsec VPN
Server hostname: $DOMAIN
Server IPv4: $PUBLIC_IP
VPN username: $VPN_USER
VPN password: $VPN_PASSWORD
Authentication: IKEv2 with trusted TLS certificate and EAP-MSCHAPv2
Ports: UDP 500 and UDP 4500
Client remote ID: $DOMAIN
EOF4
  chmod 600 "$file"
  ok "客户端配置已保存：$file（权限 600）"
}

diagnose() {
  printf '系统：%s %s\n' "$OS" "$VERSION_ID"
  systemctl --no-pager --full status "${STRONGSWAN_SERVICE:-strongswan-starter}" 2>&1 || true
  ipsec statusall 2>&1 || true
  ip -4 route show default || true
  sysctl net.ipv4.ip_forward 2>&1 || true
  journalctl -u "${STRONGSWAN_SERVICE:-strongswan-starter}" -n 30 --no-pager 2>&1 || true
}

prompt_credentials() {
  local input
  read -r -p 'IKEv2 服务器域名（必须解析到本机公网 IPv4）：' DOMAIN
  validate_domain
  read -r -p "VPN 用户名（默认 $VPN_USER）: " input || true
  [[ -n ${input:-} ]] && VPN_USER=$input
  read -r -s -p 'VPN 密码（至少 12 个字符）: ' VPN_PASSWORD || true
  printf '\n'
  [[ ${#VPN_PASSWORD} -ge 12 ]] || die '密码至少需要 12 个字符。'
  validate_credentials
}

main() {
  require_root
  init_log
  check_dependencies
  detect_os
  if [[ ${1:-} == diagnose ]]; then detect_strongswan_service || true; diagnose; exit 0; fi
  [[ ${1:-} == '' || ${1:-} == install ]] || die "用法：$SCRIPT_NAME [install|diagnose]"
  PUBLIC_IP=$(get_public_ip)
  prompt_credentials
  warn 'IKEv2 安装会替换 /etc/ipsec.conf 和 /etc/ipsec.secrets；现有文件将备份，但现有 L2TP/IPsec 连接配置会停止工作。若需两种协议同时运行，请先合并配置，不要直接安装。'
  printf '即将为 %s 配置 IKEv2/IPsec。请确认 DNS A 记录已指向 %s，TCP 80 可用于证书签发，云防火墙允许 UDP 500/4500。\n' "$DOMAIN" "$PUBLIC_IP"
  read -r -p '输入 YES 确认继续：' confirm
  [[ $confirm == YES ]] || die '用户取消安装。'
  install_dependencies
  obtain_certificate
  configure_ipsec
  enable_ip_forwarding
  configure_firewall
  start_services
  install_renewal_hook
  show_config
  diagnose
  ok 'IKEv2 安装步骤完成；请用真实客户端验证证书信任、EAP 认证、DNS 和公网流量。'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "${1:-}"; fi
