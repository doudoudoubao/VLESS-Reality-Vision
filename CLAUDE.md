# CLAUDE.md

给接手本项目的 Claude 会话看的交接文档。**改代码前请先读完「踩过的坑」一节** ——
里面每一条都是实际调试出来的，看代码本身看不出来。

## 项目定位

`install.sh` 是 VLESS + Reality + Vision 的一键部署与管理脚本，装完自身注册为
`/usr/local/bin/reality` 命令。**全部功能在这一个文件里**，没有其它源码。

## 架构原则

**内核安装完全交给官方脚本，本项目不碰内核。** 每次安装/更新都现场从
`XTLS/Xray-install` 拉取 `install-release.sh` 执行，本项目只负责：生成参数、
渲染配置、管理用户、输出分享链接。

这条原则决定了很多设计。不要为了"省一次下载"而内置官方脚本副本——那样它就会过期。

配置的唯一真相来源是 `meta.conf` + `users.tsv`，`config.json` 每次都由
`render_config()` 全量重新生成。**因此任何手工改 `config.json` 的操作都会在下一次
执行 `change-port` / `add-user` / `rekey` 等命令时被覆盖。**

## 关键设计决策（附理由，别随手改掉）

| 决策 | 理由 |
|---|---|
| `config.json` 收紧为 600 并 chown 给 Xray 运行用户 | 官方脚本默认 644，等于把 Reality 私钥暴露给本机所有用户 |
| `harden_conf()` 带 runuser 可读性回退 | 权限收紧后若服务反而读不到，自动退回 644，保证可用性优先 |
| 路由默认丢弃 `geoip:private` | 否则拿到 UUID 的人能通过代理访问本机内网与云元数据接口 `169.254.169.254` |
| DNS 里 `localhost` 排第一 | 系统解析器在机房内、有缓存、且机器能上网就必然可用；公共 DNS 仅作兜底。配合 `IPIfNonMatch`（每个域名都要解析一次），把不一定可达的公共 DNS 排前面风险很大 |
| `log.access` 设为 `none` | 隐私，且避免日志写满磁盘 |
| `apply_config()` 先自检再落盘、失败自动回滚 | 见下「坑」第 1 条，自检真的拦下过非法配置 |
| `selfupdate` 只手动、不自动 | 让服务器无人值守地自动执行来自网络的新代码，风险大于收益。内核自动更新是另一回事（那是官方签名的发布） |
| `selfupdate` 按**文件内容**比对而非版本号 | 修了 bug 忘记改版本号时不会漏掉更新 |
| 界面默认用 Unicode 制表符，不看 `LANG` | 界面本身全是中文，终端不支持 UTF-8 的话中文早就乱码了；最小化云镜像常常没设 `LANG`，据此降级会让正常终端白白吃到 ASCII 界面。留 `REALITY_ASCII=1` 作为退路 |

## 踩过的坑（改代码前必读）

**1. 新版 Xray 按文件扩展名推断配置格式。**
`mktemp` 生成的无后缀临时文件会让 `run -test` 报
`Failed to get format of /tmp/tmp.XXXX`，导致每次自检都失败、脚本完全不可用。
所以临时文件必须是 `*.json`，**且** `xray_test_config()` 显式传 `-format json`。

**2. `xray x25519` 在 26.x 是三行输出。**
```
PrivateKey: xxx
Password (PublicKey): yyy
Hash32: zzz
```
`gen_keypair()` 取前两行冒号后的值（旧版是 `Private key:` / `Public key:` 两行，
同样兼容）。**别按标签名匹配**，标签改过不止一次。

**3. `maxTimeDiff` 默认 0 = 不校验时间差。**
本项目从不设置它，所以**服务器时钟不准不会导致 Reality 握手失败**。
曾经写过"时间偏差可能导致握手失败"的警告，是错的，已改。
时钟不准的真实影响是 HTTPS 证书校验出错，进而影响更新下载。

**4. `run -test` 会初始化日志组件。**
配置里 error log 指向 `/var/log/xray/`，该目录不存在时自检直接失败。
`apply_config()` 调用 `ensure_log_dir()` 正是为此。

**5. Xray 内核自己会给两条风险警告，已内建提示。**
- `Choosing apple, icloud, etc. as the target may get your IP blocked by the GFW`
  —— 实测只有域名含 `apple`/`icloud` 会触发，候选列表已剔除，手填也会提示
- `Listening on non-443 ports may get your IP blocked by the GFW`
  —— 选非 443 端口时提示（只提示一次，别重复调用 `warn_port_risk`）

**6. 前导零端口会生成非法 JSON。**
`08443` 能过 `valid_port`（内部用 `10#` 求值），但原样写进配置就是
`"port": 08443`，JSON 不允许前导零。接受后必须 `$((10#$PORT))` 归一化。

**7. 位置参数不能静默忽略。**
`reality change-port 8443`（漏写 `--port`）曾经会静默走到"端口未变化"。
`apply_positional()` 现在把位置参数映射到对应选项，不接受参数的命令一律报错。
**静默做错事比报错更糟。**

**8. 开发沙箱会透明 MITM 443 端口。**
在本容器里 `openssl s_client` 拿到的证书签发者是
`O = Anthropic, CN = Egress Gateway SDS Issuing CA`，
**所以在这里无法验证真实站点的 TLS1.3/h2 特征**，`check_dest()` 的效果只能在
真实 VPS 上验证。不要在开发环境里得出"伪装目标全部可用"的结论。

**9. 官方安装脚本已是最新版时只打印一行就 `exit 0`**，不改动任何文件。
自动更新定时任务正是依赖这一点才能安全地每天跑。

**10. 中文是双宽字符。**
任何对齐都要用 `disp_width()`（在 `LC_ALL=C` 下逐字节解析 UTF-8），
不能用 `printf %-Ns`（按字节算，必然错位）。注意框线字符 `─` 是 3 字节但**单宽**。

**11. `meta.conf` 是被 `source` 的，写进去的任何值都可能被当成代码。**
v1.2.1 及之前 `save_meta` 直接写 `KEY='${VAL}'`，而 `valid_addr` 只拦空格：
- 一个单引号 → 那一行解析失败、地址读回为空，下次保存再把空值**永久写回**，全程显示成功
- 构造的值（如 `x'$(cmd)'x`）→ 每次加载都执行，包括 root 身份跑的自动更新定时器

现在是三层防护，**哪一层都不要去掉**：
1. `valid_addr` / `valid_dest` 只接受 IPv4、IPv6、域名这几种格式
2. `save_meta` 用 `printf '%s=%q'` 写入，任何值都原样往返、逃不出引号
3. `load_meta` 先 `bash -n` 检查，语法都不对就拒绝加载（报"已损坏"），
   而不是读进半截数据再写回去

新增任何会进 `meta.conf` 的字段，都要加进 `save_meta` 的字段列表并做格式校验。

**12. 入站监听地址不能写死 `0.0.0.0`。**
`0.0.0.0` 只绑 IPv4。v1.2.1 及之前就是这样写死的，而 `get_public_ip` 在 IPv4
探测失败时会退到 IPv6——结果纯 IPv6 机器生成的链接是 `[v6]:443`，Xray 却不在
IPv6 上监听，节点完全不可达。现在由 `listen_addr()` 按机器实际情况决定，
决策表见该函数注释。沙箱内核没有 IPv6，`"::"` 在这里会自动退回 IPv4——
所以双栈行为在沙箱里测不了，只能靠 mock `ip` / `sysctl` 测决策逻辑。

## 如何测试

```bash
bash tests/unit.sh          # 单元测试：不需要 root，只读写临时目录
sudo bash tests/e2e.sh      # 端到端：真实安装再卸载，会写 /usr/local 等系统路径
```

两套测试都会自动下载**最新版** Xray 二进制（与脚本线上行为一致）；
`XRAY_TEST_VERSION=v26.3.27` 可固定版本复现某次结果。CI（见下）每次提交都会跑全部。

**⚠ `e2e.sh` 会覆盖本机的 Xray 安装。** 它检测到 `/usr/local/bin/xray` 等路径已存在
时会拒绝运行——这个保护是为了防止有人在自己的线上服务器上试跑。开发容器里
有残留时用 `REALITY_E2E_FORCE=1`。结束时只清理它自己新建的路径。

公共机制都在 `tests/helpers.sh`，改之前先理解为什么这么做：

- **必须用真实 Xray 校验配置**，别只看 `bash -n`——坑 1、4、6 都是只有真实二进制才暴露的
- **mock systemctl**：容器里没有 systemd。`is-active` 只在二进制真能跑时返回 0，
  这样才测得出"新版本起不来 → 自动回滚"的路径
- **打桩 `install_xray_core`**：官方安装脚本要访问 `api.github.com`，开发沙箱会拦截（403）。
  只替换这一个函数，其余全部走真实代码
- **`XRAY_LOCATION_ASSET`**：打桩后官方脚本不装 geodata，路由里的 `geoip:private`
  要靠它找到数据文件，否则 `apply_config` 的自检必然失败
- **把脚本当库测**：`REALITY_LIB=1` 时只加载函数不执行 `main`。路径常量是 `readonly`，
  所以用 `sed` 改写 `XRAY_CONF_DIR` / `DATA_DIR` / `XRAY_BIN` 后再 source；
  source 之后要 `trap - ERR; set +Eeuo pipefail` 恢复测试环境
- **升级路径以 `OLD_REF`（默认 `origin/main`）为基线**：先用线上版本装，再换新脚本执行命令，
  这正是用户 `selfupdate` 之后的真实状态。CI 里以 root 跑、仓库属于 runner 用户，
  git 会拒绝操作，所以要 `git -c safe.directory=…`
- **测试里的函数名别叫 `section`**：`install.sh` 里有同名 UI 函数，source 之后会被覆盖

**写断言的一个坑**：计数用 `pass=$((pass + 1))`，别用 `((pass++))`。
后者在 `pass` 为 0 时退出码为 1，`cmd && ok_ || bad_` 会两个分支都触发。

**静态检查的一个坑**：注释只要以 `# shellcheck` 开头就会被当成指令解析，
写说明文字时换个开头。

**交互路径**目前没有自动化测试，手动用 pty 测：
`printf '1\n443\n...\n' | script -qec "bash 打桩后的脚本" /dev/null`

**新增功能时**：往 `tests/unit.sh` 或 `tests/e2e.sh` 里加对应用例。
修 bug 时先写一个能复现它的用例，确认它失败，再修。

## 开发流程

- 在指定的 `claude/*` 分支开发，PR 合并到 `main`
- CI（`.github/workflows/ci.yml`）三个任务必须全绿：`shellcheck`（`bash -n` +
  `shellcheck -S warning`，含测试脚本）、`unit`、`e2e`
- CI 每周一还会用最新 Xray 内核自动重跑一次，专门捕捉上游变更。
  这时变红而代码没改过，说明 Xray 的行为变了，脚本需要跟进
- 一键命令实时从 `main` 拉取，**合并即生效**，没有缓存
- 改了用户可见行为就升版本号（`SCRIPT_VERSION`），虽然 `selfupdate` 按内容比对不依赖它
- 界面文案用中文

## 待办

- **`reality check` 诊断命令**（已讨论未实现，优先级最高）：一条命令查全链路——
  服务是否运行、端口是否监听、防火墙、**伪装目标当前是否仍可达**、DNS 能否解析、
  公网 IP 是否还与分享链接一致、配置权限、最近错误日志。
  动机很实在：曾有一台节点"突然不能用"，来回排查十几轮才定位，
  而这些检查加起来不到十秒。伪装目标悄悄失效是节点用着用着就挂掉的典型原因。
- 其它候选（未承诺）：备份/恢复、每用户流量统计（`xray api statsquery` 可用）、
  用户到期管理、WARP 分流。
- 明确不做：内置 Web 面板（新增攻击面）、塞进其它协议（项目定位是 Reality 专用）、
  订阅链接托管（一个明文 URL 泄露全部节点）。
