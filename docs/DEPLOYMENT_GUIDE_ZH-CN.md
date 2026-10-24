# Debian/Ubuntu VPN 安装与部署手册

本文介绍如何在全新或已审查的 Debian/Ubuntu 服务器上部署本仓库的 L2TP/IPsec 或 IKEv2/IPsec。请先阅读限制和回滚说明，再在生产服务器执行。

- 仓库： https://github.com/Tony855/l2tp-ipsec-installer
- 支持范围：Debian 12/13、Ubuntu 22.04/24.04/26.04（以系统仓库实际提供的软件包为准）
- 运行方式：原生安装，不使用 Docker
- 需要：root/sudo、systemd、内核 IPsec 支持、可访问的软件源；IKEv2 还需要公网 IPv4、DNS 域名和证书签发条件。

> CI 已验证语法、ShellCheck、部分模拟单元测试及软件包依赖解析，但不会在真实云服务器上完成安装，也不代表客户端 VPN 已经连通。首次部署请使用快照或可重建的测试机。

## 1. 选择协议

| 项目 | IKEv2/IPsec（建议新部署优先考虑） | L2TP/IPsec |
|---|---|---|
| 客户端 | Windows、macOS、iOS/iPadOS、Android（视系统/客户端版本而定） | 旧系统和部分内置客户端支持；新系统支持情况不一 |
| 服务器身份 | DNS 域名 + Let's Encrypt 证书 | 预共享密钥（PSK） |
| 用户认证 | EAP-MSCHAPv2 用户名/密码 | 由安装器配置的用户名/密码及 IPsec PSK |
| 主要端口 | UDP 500、UDP 4500；签发证书时 TCP 80 | UDP 500、UDP 4500、UDP 1701（1701 应受 IPsec 保护） |
| 注意事项 | 本仓库当前使用 strongSwan starter 和 `ipsec.conf` | IKEv1/L2TP 属于较旧方案，新部署应评估现代替代方案 |

**重要：两个安装脚本不是并行配置。** 它们共享 `/etc/ipsec.conf` 和 `/etc/ipsec.secrets`。运行其中一个会备份并替换共享配置，原协议连接会停止工作。需要同时提供 L2TP 和 IKEv2 时，不要直接连续运行两个脚本，应先设计并验证合并配置。

## 2. 部署前准备

### 2.1 准备服务器

建议使用全新、受支持的 Debian/Ubuntu 64 位服务器，确保有控制台或云厂商救援入口。先更新系统并安装基础工具：

```bash
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y ca-certificates curl git
sudo reboot
```

重启后重新 SSH 登录。升级可能更新内核或网络组件；请确认云厂商控制台可用，并避免在没有带外访问的情况下进行可能影响远程连接的维护。

确认系统版本、时间、磁盘和默认路由：

```bash
cat /etc/os-release
timedatectl status
df -h
ip -4 address
ip -4 route show default
```

### 2.2 配置 DNS（仅 IKEv2 必需）

在 DNS 服务商创建一个 A 记录，例如 `vpn.example.com`，指向服务器的公网 IPv4 地址。不要把域名指向错误的负载均衡地址。证书验证前确认 DNS 已传播：

```bash
getent ahostsv4 vpn.example.com
curl -4fsS --max-time 8 https://api.ipify.org; echo
```

将示例域名替换为自己的域名。解析出的 IPv4 应与服务器实际公网 IPv4 一致。若服务器位于 NAT 后方，须确认端口转发和公网地址映射正确。当前安装器要求公网 IPv4 查询服务可访问。

### 2.3 配置云防火墙与主机防火墙

在云厂商安全组/网络 ACL 与主机防火墙两处检查入站策略。只开放实际需要的端口，并将管理 SSH 端口限制到可信管理 IP（不要因配置 VPN 而意外开放所有管理服务）。

IKEv2：
- UDP 500：IKE 协商
- UDP 4500：IPsec NAT-T
- TCP 80：仅在需要通过 Let's Encrypt HTTP-01 签发/续期证书时使用；本安装器使用 Certbot standalone，签发时要求该端口可达且没有其他 Web 服务占用。

L2TP/IPsec：
- UDP 500、UDP 4500
- UDP 1701：仅允许 IPsec 保护的 L2TP 流量；不要把未受保护的 1701 暴露给公网。

安装器会尝试使用 iptables 添加规则并保存规则（若有 netfilter-persistent）。如果主机使用 UFW、nftables、云防火墙或自定义策略，必须先审查规则，避免规则冲突或覆盖。不要在远程 SSH 会话中直接清空防火墙规则。

## 3. 下载并审查项目

```bash
cd /usr/local/src
sudo git clone https://github.com/Tony855/l2tp-ipsec-installer.git
cd l2tp-ipsec-installer
git status --short
git log -1 --oneline
```

在执行前审查要运行的脚本：

```bash
less install-IKEv2_IPSec.sh
less install-L2TP_IPSec.sh
```

如果服务器没有安装 `less`，可使用 `sed -n '1,240p' 文件名` 查看。生产环境建议固定到已审核的 commit/tag，而不是无条件跟随 `main`。

## 4. 安装 IKEv2/IPsec（建议）

### 4.1 运行安装器

```bash
cd /usr/local/src/l2tp-ipsec-installer
sudo bash install-IKEv2_IPSec.sh
```

按提示操作：

1. 输入已解析到本机公网 IPv4 的完整域名，例如 `vpn.example.com`。
2. 输入 VPN 用户名（默认 `vpnuser`；支持字母、数字、下划线、点、@、连字符）。
3. 输入至少 12 个字符的强密码。不要复用 SSH、邮箱或其他服务密码。
4. 确认公网地址、DNS、TCP 80 和 UDP 500/4500 条件均满足。
5. 确认理解现有配置将被备份且共享 IPsec 配置会被替换后，输入大写 `YES` 才继续。

安装器将安装 strongSwan starter 相关软件包、iptables、Certbot 等，申请或复用 Let's Encrypt 证书，配置 IP 转发、NAT 和防火墙规则，启动 strongSwan，并创建证书续期 deploy hook。

**如果 Nginx 或 Apache 正在运行，安装器会为避免中断网站而停止并退出。** 请先单独规划证书签发方式；不要为了签发证书盲目停止生产网站。脚本不会自动停止 Web 服务。

### 4.2 安装完成后核验

```bash
sudo systemctl status strongswan-starter --no-pager
sudo ipsec statusall
sudo sysctl net.ipv4.ip_forward
sudo iptables -t nat -S POSTROUTING
sudo iptables -S INPUT
sudo iptables -S FORWARD
sudo ls -l /etc/letsencrypt/live/
sudo ls -l /root/ikev2-vpn-config.txt
```

服务单元名称可能因软件包布局而不同。安装器会探测 `strongswan-starter.service` 或 `ipsec.service`，因此若固定服务名不存在，应先查看实际单元：

```bash
systemctl list-unit-files | grep -E 'strongswan|ipsec'
```

客户端配置摘要保存在 `/root/ikev2-vpn-config.txt`，权限应为 600。该文件包含 VPN 密码，**不要贴到工单、聊天、Git 仓库或公共日志中**。可在服务器上使用 `sudo cat /root/ikev2-vpn-config.txt` 查看，并通过可信的安全渠道把必要参数传给客户端用户。

### 4.3 客户端配置

使用系统自带的 IKEv2 客户端时，通常需要以下参数：

- 服务器地址：证书对应的 DNS 域名（例如 `vpn.example.com`），不要用 IP 替代域名。
- VPN 类型：IKEv2。
- 用户认证：用户名和密码（EAP-MSCHAPv2）。
- 远程标识/Remote ID：域名；若客户端提供此字段，应与证书域名匹配。
- 证书：使用系统信任的公开 CA 证书；不要忽略证书警告，也不要安装来历不明的根证书。
- 端口：UDP 500/4500 通常由系统自动处理。

Windows、macOS、iOS/iPadOS 与 Android 的配置界面会随版本变化，请按当前系统的 VPN 设置页面选择 IKEv2，并按上面的参数填写。部分 Android 版本/厂商不提供内置 IKEv2 客户端，可能需要可信的兼容客户端。首次连接建议先测试一个客户端，不要同时修改多项服务器参数。

### 4.4 检查连通性

客户端连接后检查：
1. 客户端显示已连接，且没有证书或身份验证错误。
2. 客户端能访问预期的公网地址查询服务。
3. DNS 查询正常。
4. 服务器端能看到连接状态：
   ```bash
   sudo ipsec statusall
   sudo journalctl -u strongswan-starter -n 100 --no-pager
   ```
5. 在客户端验证实际业务访问。仅显示“已连接”并不保证默认路由、DNS 或所有流量都按预期转发。

## 5. 安装 L2TP/IPsec

仅在确实需要兼容 L2TP 客户端时使用：

```bash
cd /usr/local/src/l2tp-ipsec-installer
sudo bash install-L2TP_IPSec.sh
```

按交互提示配置 IPsec PSK、VPN 用户名和密码；检查参数后输入大写 `YES` 确认。安装完成后，配置摘要写入 `/root/vpn-config.txt`，权限为 600。该文件包含凭据，应严格保密。

在客户端选择 L2TP/IPsec PSK 类型，填写服务器公网 IPv4/域名、IPsec 预共享密钥、用户名和密码。由于不同操作系统版本对 L2TP 的支持存在差异，务必在目标客户端版本上实测。

L2TP 诊断命令：

```bash
sudo bash install-L2TP_IPSec.sh diagnose
sudo systemctl status xl2tpd --no-pager
sudo ipsec statusall
sudo journalctl -u xl2tpd -n 100 --no-pager
```

## 6. 日常运维与诊断

IKEv2：
```bash
sudo bash /usr/local/src/l2tp-ipsec-installer/install-IKEv2_IPSec.sh diagnose
sudo systemctl --no-pager --full status strongswan-starter
sudo ipsec statusall
sudo journalctl -u strongswan-starter -n 100 --no-pager
sudo certbot certificates
sudo certbot renew --dry-run
```

L2TP：
```bash
sudo bash /usr/local/src/l2tp-ipsec-installer/install-L2TP_IPSec.sh diagnose
sudo systemctl --no-pager --full status xl2tpd
sudo ipsec statusall
sudo journalctl -u xl2tpd -n 100 --no-pager
```

如果服务名称与示例不一致，先用 `systemctl list-units --type=service | grep -E 'strongswan|ipsec|xl2tpd'` 查找实际名称。日志可能包含 IP 地址、用户名等敏感信息，分享前应脱敏。

### 常见故障

- **证书申请失败：** 检查域名 A 记录、公网 IPv4、TCP 80 入站可达性，以及 80 端口是否被 Web 服务占用。
- **IKE 协商超时：** 检查云安全组与主机防火墙是否放行 UDP 500/4500，检查 NAT 和运营商是否过滤 UDP。
- **用户名/密码失败：** 核对大小写、用户名和密码，避免空格、引号或反斜杠等不支持字符；确认配置文件内容和权限。
- **连接成功但无法上网：** 检查 `net.ipv4.ip_forward=1`、NAT POSTROUTING、FORWARD 规则、默认路由及客户端 DNS。
- **续期后证书似乎未生效：** 检查 `certbot certificates`、deploy hook 文件及 strongSwan 服务日志；先在测试环境执行 `certbot renew --dry-run`。
- **服务无法启动：** 查看 `journalctl -u <实际服务名> -n 100 --no-pager` 与 `ipsec statusall`，确认 strongSwan 后端与安装的插件匹配。
- **SSH 断连或防火墙异常：** 通过云控制台恢复，检查既有 UFW/nftables/iptables 策略；不要直接清空生产防火墙。

## 7. 备份与回滚

安装器会在覆盖 `/etc/ipsec.conf` 与 `/etc/ipsec.secrets` 前创建带时间戳的副本，但**这不是完整的事务回滚机制**。它还可能安装软件包、写入 sysctl 配置、添加防火墙规则和证书续期 hook。

安装前建议先创建云服务器快照，并手动保存当前状态：

```bash
sudo install -d -m 700 /root/vpn-preinstall-backup
sudo cp -a /etc/ipsec.conf /etc/ipsec.secrets /root/vpn-preinstall-backup/ 2>/dev/null || true
sudo iptables-save | sudo tee /root/vpn-preinstall-backup/iptables.rules >/dev/null
sudo sysctl -a 2>/dev/null | grep '^net.ipv4.ip_forward' | sudo tee /root/vpn-preinstall-backup/ip-forward.txt >/dev/null
```

回滚前先通过云控制台或带外通道确保不会失去服务器访问权限。根据安装前记录和时间戳备份，人工恢复 IPsec 配置、sysctl 与防火墙规则；检查并移除仅由本次安装创建的续期 hook。不要直接恢复整个防火墙快照，除非确认它与当前 SSH、云代理及其他业务规则兼容。生产系统建议优先恢复云快照。

## 8. 上线安全清单

- [ ] 已确认服务器系统版本受支持，且有云控制台/快照。
- [ ] 已核对 DNS、公网 IPv4、云安全组和主机防火墙。
- [ ] 已审查现有 strongSwan、xl2tpd、UFW/nftables 和其他 VPN 服务。
- [ ] VPN 使用独立强密码，密钥文件和配置摘要权限受限。
- [ ] 未将包含密码的配置文件、日志或私钥提交到 Git。
- [ ] 已从真实目标客户端测试连接、DNS、路由和业务访问。
- [ ] 已验证证书续期流程（IKEv2）及服务重启 hook。
- [ ] 已保存备份、记录变更并制定回滚步骤。
- [ ] 已监控系统更新、服务状态、认证失败和异常流量。

## 9. 自动化测试的范围

GitHub Actions 当前覆盖 Debian 13、Ubuntu 24.04 和 Ubuntu 26.04 的 Bash 语法、ShellCheck、部分模拟单元测试与软件包依赖解析。它不执行真实 root 安装，不会真实申请 Let's Encrypt 证书，也不测试 Windows/macOS/iOS/Android 的隧道建立。因此，上线前必须完成真实环境验收。

