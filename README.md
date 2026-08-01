# VLESS + Reality + Vision 一键脚本

基于 [Xray-core](https://github.com/XTLS/Xray-core) 官方安装脚本构建的一键部署与管理工具。
内核安装完全交给官方 [XTLS/Xray-install](https://github.com/XTLS/Xray-install)，本脚本只负责
**生成参数、渲染配置、日常管理**，不魔改任何内核文件。

```
VLESS  +  Reality  +  XTLS-rprx-Vision
无需域名、无需证书、抗主动探测、性能接近直连
```

## 快速开始

在服务器上以 root 身份执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/doudoudoubao/VLESS-Reality-Vision/main/install.sh)
```

脚本会打开交互菜单。选择 `1` 安装，全程约 30 秒，结束后直接输出分享链接与二维码。

安装完成后，随时使用 `reality` 命令再次打开菜单：

```bash
reality
```

### 全自动安装（非交互）

适合批量部署或写进初始化脚本：

```bash
# 全部使用默认值：443 端口、www.microsoft.com 作为握手目标
reality install --yes

# 指定参数
reality install --port 443 --sni www.nvidia.com --name hk --host 1.2.3.4 --yes
```

## 功能

| | |
|---|---|
| 一键安装 | 自动装内核、生成密钥、写配置、开防火墙、出链接和二维码 |
| 多用户 | 随时增删用户，每个设备一个 UUID，互不影响 |
| 参数管理 | 改端口、换 SNI、轮换密钥、重建 UUID、改分享地址 |
| 配置安全网 | 每次改动先做 `xray -test` 自检，失败不落盘；启动异常自动回滚上一份配置 |
| 目标可用性检测 | 选 SNI 时实测目标是否支持 TLS1.3 + HTTP/2，不合格当场提示 |
| 客户端导出 | 分享链接、二维码、sing-box 出站、Clash.Meta 节点片段 |
| 跟随官方更新 | 每次更新都现拉官方安装脚本装最新内核，可开启每日自动更新，新版本起不来会自动回滚 |
| 其它 | BBR 加速、路由拦截规则、实时日志、干净卸载 |

## 命令一览

```
reality                 打开交互菜单
reality install         安装并生成节点
reality info            查看节点信息（含全部用户）
reality link            仅输出分享链接
reality qr              输出二维码
reality client          输出 sing-box / Clash.Meta 配置片段

reality add-user        添加用户       reality del-user      删除用户
reality change-port     修改监听端口   reality change-sni    更换握手目标
reality change-host     修改分享地址   reality change-uuid   重建全部 UUID
reality rekey           轮换 Reality 密钥对
reality rules           调整路由拦截规则

reality update          立即检查并更新 Xray-core
reality autoupdate on|off|status    自动更新开关
reality selfupdate      更新管理脚本自身
reality start | stop | restart | status | log
reality bbr             开启 BBR 加速
reality uninstall       卸载
```

常用选项：`--port` `--sni` `--dest` `--uuid` `--name` `--host` `--force` `-y/--yes`。
完整说明见 `reality help`。

> `-y/--yes` 的含义是 **对所有确认一律回答「是」**（与 `apt-get -y` 一致）。
> 对 `rekey`、`change-uuid`、`uninstall` 这类破坏性操作请谨慎使用。

## 客户端配置

脚本输出的 `vless://` 链接可直接导入以下客户端：

| 平台 | 客户端 |
|---|---|
| Windows | v2rayN、Nekoray |
| macOS | V2RayXS、Nekoray |
| Android | v2rayNG、NekoBox、sing-box |
| iOS | Shadowrocket、Stash、sing-box |
| 路由器 / 命令行 | sing-box、mihomo (Clash.Meta) |

手动填写时的对应关系：

| 字段 | 值 |
|---|---|
| 协议 | VLESS |
| 传输 (network) | tcp |
| 传输层安全 | reality |
| 流控 (flow) | `xtls-rprx-vision` |
| SNI / servername | 安装时选择的目标域名 |
| 指纹 (fingerprint) | chrome |
| PublicKey (pbk) | 脚本输出的公钥 |
| ShortId (sid) | 脚本输出的短 ID |

`reality client` 可直接输出 sing-box 与 Clash.Meta 的配置片段，复制粘贴即可。

## 安全设计

这个脚本在几个容易被忽略的地方做了加固：

**私钥不外泄。** Reality 私钥写在 `config.json` 里，官方安装脚本默认给它 644 权限，
意味着服务器上任何一个普通用户都能读到。本脚本把它收紧为 `600`，并归属于 Xray 的实际运行用户
（官方默认是 `nobody`，不是 root）。元数据 `meta.conf` 与用户列表则是 `600 root:root`，
数据目录 `700`。

**不做 `curl | bash`。** 官方安装脚本会先完整下载到临时文件，校验是脚本文件后再执行，
地址固定为 XTLS 官方仓库的 HTTPS 原始地址。

**阻断内网探测。** 路由规则默认丢弃所有指向 `geoip:private` 的流量。
否则任何拿到你 UUID 的人都能通过你的代理访问服务器本机的 `127.0.0.1` 与内网服务
（Redis、面板、云厂商元数据接口 `169.254.169.254` 等）。
配合 `domainStrategy: IPIfNonMatch`，域名解析后仍会再匹配一次，避免用域名绕过。

**默认不记访问日志。** `log.access` 设为 `none`，只保留 warning 级别的错误日志，
既保护隐私也避免日志把磁盘写满。

**改配置不会把服务改挂。** 任何一次改动都是「渲染到临时文件 → `xray -test` 自检 →
备份当前配置 → 落盘 → 重启 → 确认存活」，中间任何一步失败都会自动回滚到上一份可用配置，
并保留最近 10 份备份在 `/usr/local/etc/xray/reality/backup/`。

**跟随官方风险提示。** Xray-core 自身会对两种情况告警，脚本提前把它们暴露出来：

- 用 `apple` / `icloud` 系域名做握手目标可能导致服务器 IP 被封锁，
  因此内置候选列表已剔除这类域名，手动填写时也会提示；
- 监听非 443 端口更容易被识别，选择其它端口时会提示。

**BT 流量默认拦截。** 多数 VPS 商家禁止 BT/PT，一次滥用就可能导致停机。可在
`reality rules` 中关闭。

## 跟随官方更新

脚本**不内置任何 Xray 副本**：每次执行 `reality update`，都会现从
[XTLS/Xray-install](https://github.com/XTLS/Xray-install) 官方仓库拉取最新的
`install-release.sh`，再由它安装官方最新版内核。所以脚本本身不会因为放久了而过期。

官方安装脚本在检测到「已是最新版本」时，只打印一行提示就退出，**不会改动任何文件**，
因此重复执行是幂等且安全的 —— 定时任务正是依赖这一点。

### 开启每日自动更新

```bash
reality autoupdate on       # 开启
reality autoupdate status   # 查看状态与下次执行时间
reality autoupdate off      # 关闭
```

开启后会注册一个 systemd timer，每天检查一次，并带 0–4 小时的随机延迟
（避免所有机器同一分钟去打 GitHub API）。若机器当时关机，下次开机会补跑。

**自动更新的安全保障**：更新前先备份当前二进制，更新后如果配置自检不通过、
或服务起不来，会自动**回滚到上一版本的二进制**并重启，确保代理不会在无人值守时挂掉。

> 说明：「实时更新」在技术上做不到 —— GitHub 不会主动推送到你的服务器，只能轮询；
> 而官方安装脚本走的是未认证的 GitHub API，按 IP 限流，分钟级轮询没有意义。
> 每天一次已经足够及时。

### 更新脚本自身

```bash
reality selfupdate
```

会从本仓库拉取最新的 `install.sh`，**先做语法检查再替换**，版本相同则不动。
这一项**刻意只提供手动方式**：让服务器无人值守地自动执行来自网络的新代码，
风险远大于收益。

## 关于握手目标（SNI）的选择

Reality 的原理是让你的服务器在被主动探测时，表现得像是在访问某个真实网站。
这个"真实网站"就是握手目标，选择标准：

- 支持 **TLS1.3** 与 **HTTP/2**（脚本会实测，不合格会提示）；
- **不在 Cloudflare 等 CDN 之后**，否则容易被识别；
- 与服务器 **地理位置相近**，延迟越低握手越自然；
- 是个 **常有人访问** 的站点，冷门域名反而显眼；
- 避开 `apple` / `icloud` 系（Xray 官方明确警告）。

内置候选（均已实测支持 TLS1.3 + h2）：

```
www.microsoft.com   www.amazon.com    www.nvidia.com
www.samsung.com     www.tesla.com     www.asus.com
dl.google.com       addons.mozilla.org
www.lovelive-anime.jp             shopping.yahoo.co.jp
```

## 文件位置

```
/usr/local/bin/xray                        Xray 二进制（官方脚本安装）
/usr/local/bin/reality                     本管理脚本
/usr/local/etc/xray/config.json            Xray 配置（600，属 Xray 运行用户）
/usr/local/etc/xray/reality/meta.conf      节点参数（600 root）
/usr/local/etc/xray/reality/users.tsv      用户列表（600 root）
/usr/local/etc/xray/reality/backup/        配置备份（最近 10 份）
/usr/local/etc/xray/reality/xray.prev      上一版本二进制（供更新失败时回滚）
/var/log/xray/error.log                    错误日志
/etc/systemd/system/xray.service           systemd 服务（官方脚本生成）
/etc/systemd/system/reality-update.timer   自动更新定时器（开启后才有）
```

## 常见问题

**连不上怎么办？**

按顺序排查：

1. `reality status` 看服务是否在运行；
2. 云服务器控制台的**安全组**是否放行了对应 TCP 端口（这是最常见的原因，
   脚本只能处理服务器内部的 ufw / firewalld，管不到云厂商的安全组）；
3. 客户端的 SNI、公钥、短 ID、flow 是否与 `reality info` 输出完全一致；
4. **客户端是否支持 Reality** —— 需要同时支持 VLESS、Reality 和
   `xtls-rprx-vision` 流控，缺一样都连不上。已实测可用的有
   Shadowrocket 与 Quantumult X（较新版本）。判断方法：看客户端能否
   填入「公钥 / Short ID / 指纹」这三个 Reality 专有字段，填不了就是不支持；
5. `reality log` 看实时错误日志。

时间未同步（`timedatectl` 显示 `NTP service: inactive`）**不会**导致连不上 ——
本脚本未启用 Reality 的时间差校验（`maxTimeDiff` 保持默认的 0）。
但时钟偏差过大会让 HTTPS 证书校验失败，影响 `reality update` 下载，建议还是校准。

**支持哪些系统？**

Debian、Ubuntu、CentOS / RHEL / Rocky / AlmaLinux、Fedora、Arch、openSUSE 等
使用 systemd 的发行版。Alpine 等 OpenRC 系统暂不支持（官方安装脚本亦不支持），
脚本会明确提示而不是装到一半失败。

**为什么服务以 nobody 而不是 root 运行？**

这是官方安装脚本的默认行为，通过 `CAP_NET_BIND_SERVICE` 让非 root 用户也能监听 443。
权限更小，更安全，本脚本沿用这一设定。

**能装在已有 Xray 的机器上吗？**

`reality install` 会覆盖 `/usr/local/etc/xray/config.json`。如果机器上已有其它
Xray 配置，请先自行备份。

**IPv6 服务器可以用吗？**

可以。脚本会自动探测公网地址，IPv6 会正确加上方括号写进分享链接；
若服务器没有全局 IPv6 地址，DNS 与出站策略会自动切到 `UseIPv4`，避免解析到
AAAA 记录却连不通。

## 卸载

```bash
reality uninstall
```

调用官方脚本的 `remove --purge` 移除内核，并清理本脚本的全部数据、管理命令与防火墙规则。

## 致谢

- [XTLS/Xray-core](https://github.com/XTLS/Xray-core) —— Reality / Vision 的实现
- [XTLS/Xray-install](https://github.com/XTLS/Xray-install) —— 官方安装脚本

## 许可

[MIT](LICENSE)

> 本项目仅供学习与技术研究使用，请遵守所在国家和地区的法律法规。
