#!/usr/bin/env bash
# 端到端测试：mock systemctl + 真实 Xray 二进制，走真实的命令路径。
#
#   sudo bash tests/e2e.sh
#
# ⚠ 会写入 /usr/local/bin/xray、/usr/local/etc/xray 等真实系统路径，
#   只应在 CI 或一次性虚拟机中运行。本机已有安装时拒绝运行——
#   若确认可以覆盖（例如开发容器），设置 REALITY_E2E_FORCE=1。
#
# 升级路径测试以 OLD_REF（默认 origin/main）作为"用户当前在用的版本"。

# shellcheck source=tests/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
trap 'rm -rf "$WORK"' EXIT   # 守卫拒绝运行时也要清掉临时目录；开测后会换成完整清理

if [[ $EUID -ne 0 ]]; then
  echo '需要 root：本测试会真实安装与卸载 Xray。' >&2
  exit 1
fi

# 这些路径开测前若已存在，说明本机可能有真实安装，测试会把它覆盖掉
if [[ ${REALITY_E2E_FORCE:-0} != 1 ]]; then
  for p in /usr/local/bin/xray /usr/local/etc/xray /usr/local/bin/reality; do
    if [[ -e $p ]]; then
      echo "检测到 $p 已存在：本机可能有正在使用的安装，继续会将其覆盖并删除。" >&2
      echo '请在 CI 或一次性虚拟机中运行；确认可以覆盖请设置 REALITY_E2E_FORCE=1。' >&2
      exit 1
    fi
  done
fi

# 只清理本次测试新建的路径：开测前就存在的一律不删
CREATED=()
for p in /usr/local/etc/xray /usr/local/bin/xray /usr/local/bin/reality /var/log/xray \
         /run/systemd/system /etc/systemd/system/reality-update.service \
         /etc/systemd/system/reality-update.timer /etc/sysctl.d/99-reality-bbr.conf; do
  [[ -e $p ]] || CREATED+=("$p")
done
XRAY_PID=''
cleanup() {
  if [[ -n $XRAY_PID ]]; then kill "$XRAY_PID" 2>/dev/null; fi
  rm -rf "${CREATED[@]}" "$WORK"
}
trap cleanup EXIT

setup_xray
mock_systemd
# 打桩后官方脚本不会装 geodata，路由里的 geoip:private 要靠这个找到数据文件
export XRAY_LOCATION_ASSET=$XRAY_DIR

OLD_REF=${OLD_REF:-origin/main}
# CI 里以 root 跑、仓库属于 runner 用户，git 会拒绝操作"所有者不同"的仓库
git_() { git -c safe.directory="$REPO" -C "$REPO" "$@"; }
if ! git_ rev-parse -q --verify "$OLD_REF" >/dev/null; then
  echo "找不到 ${OLD_REF}（升级路径测试需要它）：请先 git fetch origin main，或设置 OLD_REF。" >&2
  exit 1
fi
git_ show "$OLD_REF:install.sh" >"$WORK/old-src.sh"
make_stub "$WORK/old-src.sh" "$WORK/old.sh"
make_stub "$REPO/install.sh"  "$WORK/new.sh"
OLD="bash $WORK/old.sh"
NEW="bash $WORK/new.sh"
printf '升级基线：%s（%s）\n' "$OLD_REF" "$(bash "$WORK/old-src.sh" version)"

META=/usr/local/etc/xray/reality/meta.conf
CONF=/usr/local/etc/xray/config.json
xtest()   { "$XRAY_DIR/xray" run -test -format json -config "$CONF" 2>&1 | grep -q 'Configuration OK'; }
host_of() { grep -oP '(?<=^NODE_HOST=).*' "$META"; }

group 'A. 升级路径：旧版装好 → 换成新版脚本（即用户 selfupdate 之后的状态）'
if $OLD install --yes --host 1.2.3.4 --name hk >/dev/null 2>&1; then ok_ '旧版安装成功'; else bad_ '旧版安装失败'; fi
cp "$WORK/new.sh" /usr/local/bin/reality   # 模拟 selfupdate
link=$($NEW link --yes 2>/dev/null)
if [[ $link == vless://*@1.2.3.4:443* ]]; then ok_ '新版读取旧配置正常，链接不变'; else bad_ "新版读取旧配置出错: $link"; fi
if $NEW change-port 8443 --yes >/dev/null 2>&1; then ok_ '新版对旧安装执行改端口'; else bad_ '改端口失败'; fi
eq_ '地址在格式迁移后保留' "$(host_of)" '1.2.3.4'
if xtest; then ok_ '迁移后配置通过 Xray 校验'; else bad_ '迁移后配置校验失败'; fi
$NEW change-port 443 --yes >/dev/null 2>&1

group 'B. 注入样本必须被拒绝'
PWNED="$WORK/PWNED"
before=$(sha256sum "$META")
if $NEW change-host "my'host.com" --yes >/dev/null 2>&1; then bad_ '单引号地址被接受'; else ok_ '单引号地址被拒绝'; fi
if $NEW change-host "x'\$(touch\${IFS}$PWNED)'x" --yes >/dev/null 2>&1; then bad_ '注入样本被接受'; else ok_ '注入样本被拒绝'; fi
$NEW link --yes >/dev/null 2>&1
$NEW info --yes >/dev/null 2>&1
if [[ -e $PWNED ]]; then bad_ '注入样本被执行了'; else ok_ '没有任何命令被执行'; fi
eq_ '被拒绝后 meta.conf 一字未改' "$(sha256sum "$META")" "$before"
msg=$($NEW change-host "my'host.com" --yes 2>&1)
if [[ $msg == *只接受\ IPv4、IPv6\ 或域名* ]]; then ok_ '报错信息说明了原因'; else bad_ "报错信息不清楚: $msg"; fi

group 'C. 合法地址照常可用'
$NEW change-host node.example.com --yes >/dev/null 2>&1
eq_ '域名' "$(host_of)" 'node.example.com'
$NEW change-host 2001:db8::1 --yes >/dev/null 2>&1
link=$($NEW link --yes 2>/dev/null)
if [[ $link == *@\[2001:db8::1\]:443* ]]; then ok_ 'IPv6，链接自动加方括号'; else bad_ "IPv6 链接: $link"; fi
$NEW change-host '[2001:db8::2]' --yes >/dev/null 2>&1
eq_ '带方括号粘贴的 IPv6 被规整' "$(host_of)" '2001:db8::2'
$NEW change-host 1.2.3.4 --yes >/dev/null 2>&1

group 'D. install 参数写错时立刻拒绝，且不先装内核'
# 参数错误应在任何耗时操作之前报出。判据不靠计时：被拒绝后内核根本不该被装上
reject_install() { # reject_install <说明> <install 的参数…>
  local what=$1; shift
  rm -rf /usr/local/etc/xray /usr/local/bin/xray
  if $NEW install --yes "$@" >/dev/null 2>&1; then
    bad_ "接受了错误参数：$what"
  elif [[ -e /usr/local/bin/xray ]]; then
    bad_ "拒绝了 $what，但已经先把内核装上了"
  else
    ok_ "立刻拒绝 $what，未安装内核"
  fi
}
for bad in "a'b" 'a"b.com' '$(id)'; do reject_install "--host [$bad]" --host "$bad"; done
for bad in "a'b.com:443" 'www.nvidia.com' 'a.com:99999'; do
  reject_install "--dest [$bad]" --host 1.2.3.4 --dest "$bad"
done
reject_install '--port 99999'      --host 1.2.3.4 --port 99999
reject_install '--sni 无效域名'     --host 1.2.3.4 --sni 'not a domain'
reject_install '--uuid 非法格式'    --host 1.2.3.4 --uuid not-a-uuid
reject_install '--name 带引号'      --host 1.2.3.4 --name 'a"b'
rm -rf /usr/local/etc/xray
if $NEW install --yes --host 1.2.3.4 --dest www.nvidia.com:443 --sni www.nvidia.com >/dev/null 2>&1; then
  ok_ '合法 --dest 正常安装'
else
  bad_ '合法 --dest 安装失败'
fi

group 'E. 损坏的配置明确报错，不再静默丢数据'
cp "$META" "$WORK/meta.good"
sed -i "s/^NODE_HOST=.*/NODE_HOST='my'host.com'/" "$META"
msg=$($NEW info --yes 2>&1)
if [[ $msg == *已损坏* ]]; then ok_ '明确报告配置已损坏'; else bad_ "没有报错: $(tail -n1 <<<"$msg")"; fi
if $NEW change-port 9999 --yes >/dev/null 2>&1; then
  bad_ '损坏状态下仍执行了写操作'
else
  ok_ '损坏状态下拒绝写入，不会把缺失值写回'
fi
cp "$WORK/meta.good" "$META"

group 'F. reality check 在真实安装上运行'
# 只断言本机就能确定的四项。DNS、伪装目标、公网 IP 取决于所在网络，
# 沙箱与 CI 的结果不同，交给单元测试用模拟覆盖
# 容器里没有 systemd，手动把 Xray 跑起来，端口检查才有东西可查
"$XRAY_DIR/xray" run -config "$CONF" >/dev/null 2>&1 &
XRAY_PID=$!
for _ in $(seq 40); do
  ss -ltn | awk '{print $4}' | grep -q ':443$' && break
  sleep 0.25
done
out=$($NEW check 2>&1)
for l in 'Xray 内核' '配置文件' '服务状态' '端口监听'; do
  if [[ $out == *"✓ $l"* ]]; then ok_ "✓ $l"; else bad_ "$l 不是 ✓：$(grep -F "$l" <<<"$out")"; fi
done
if [[ $out == *全部正常* || $out == *没有发现问题* || $out == *发现*个问题* ]]; then
  ok_ '给出总结'
else
  bad_ "没有总结：$(tail -n3 <<<"$out")"
fi
kill "$XRAY_PID"; wait "$XRAY_PID" 2>/dev/null; XRAY_PID=''
out=$($NEW check 2>&1); rc=$?
if [[ $out == *"✗ 端口监听"* ]]; then ok_ 'Xray 退出后报告端口没人监听'; else bad_ "没发现端口问题：$(grep -F '端口监听' <<<"$out")"; fi
eq_ '发现问题时退出码为 1（main 没有吞掉退出码）' "$rc" 1
chmod 644 "$CONF"
out=$($NEW check 2>&1)
if [[ $out == *"! 配置文件"*644* ]]; then ok_ '配置权限放宽时提醒'; else bad_ "没有提醒权限：$(grep -F '配置文件' <<<"$out")"; fi
chmod 600 "$CONF"
msg=$($NEW check extra 2>&1)
if [[ $msg == *不接受参数* ]]; then ok_ 'check 拒绝多余参数'; else bad_ "check 接受了多余参数：$msg"; fi
# 菜单是交互路径，用伪终端驱动：选 18 → 回车返回菜单 → 0 退出
out=$(printf '18\n\n0\n' | script -qec "$NEW" /dev/null 2>&1)
if [[ $out == *节点诊断* && $out == *端口监听* ]]; then ok_ '菜单 18 运行诊断'; else bad_ "菜单 18 没有运行诊断：$(tail -n5 <<<"$out")"; fi

group 'G. 甲骨文云式 iptables 自动放行（真实 iptables，独立网络命名空间）'
# 在独立的网络命名空间里跑，规则只存在于这个命名空间，绝不会碰到本机的防火墙
if ! command -v iptables >/dev/null 2>&1 || ! unshare -n true 2>/dev/null; then
  printf '  跳过：本机没有 iptables，或无法创建网络命名空间\n'
else
  mkdir -p "$WORK/ipt"
  cat >"$WORK/ipt-case.sh" <<'EOF'
# $1 当库加载的脚本  $2 模拟的开机规则文件  $3 输出目录
REALITY_LIB=1 source "$1"; trap - ERR; set +Eeuo pipefail
IPT_SAVE_FILES=("$2")
ufw_active() { return 1; }; firewalld_running() { return 1; }   # 只测 iptables 这一路
cat >"$3/orig" <<'RULES'
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A INPUT -p icmp -j ACCEPT
-A INPUT -i lo -j ACCEPT
-A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT
-A INPUT -j REJECT --reject-with icmp-host-prohibited
COMMIT
RULES
iptables-restore <"$3/orig"; cp "$3/orig" "$2"
firewall_allow 443 >"$3/allow.out" 2>&1
iptables -S INPUT >"$3/after-allow"; cp "$2" "$3/file-allow"
iptables-restore --test <"$2"; echo $? >"$3/file-valid"
firewall_allow 443 >/dev/null 2>&1                  # 再执行一次，不应重复添加
iptables -S INPUT >"$3/after-again"; cp "$2" "$3/file-again"
PORT=443; ck_firewall; echo "$CK_STATUS" >"$3/ck"
iptables -I INPUT -p tcp --dport 443 -j ACCEPT      # 用户自己加的同端口规则，撤销时必须保留
firewall_revoke 443 >/dev/null 2>&1
iptables -S INPUT >"$3/after-revoke"; cp "$2" "$3/file-revoke"
iptables -F INPUT                                   # 全放行的机器：一条都不该加
firewall_allow 8443 >/dev/null 2>&1
iptables -S INPUT >"$3/permissive"
iptables-restore <"$3/orig"                         # 旧版本装的机器：节点已装好，端口却被拦着
cmd_open_port >"$3/open.out" 2>&1; echo $? >"$3/open-rc"
iptables -S INPUT >"$3/after-open"
EOF
  unshare -n bash "$WORK/ipt-case.sh" "$WORK/new.sh" "$WORK/rules.v4" "$WORK/ipt"
  I=$WORK/ipt
  TAG_RT='--dport 443 -m comment --comment reality -j ACCEPT'
  line_of() { grep -nF -- "$1" "$2" | head -n1 | cut -d: -f1; }
  before_reject() { # before_reject <规则片段> <文件>：该规则存在，且排在 REJECT 之前
    local a b; a=$(line_of "$1" "$2"); b=$(line_of 'REJECT' "$2")
    [[ -n $a && -n $b ]] && ((a < b))
  }
  if before_reject "$TAG_RT" "$I/after-allow"; then ok_ '放行规则插在 REJECT 之前'; else bad_ "没有放行，或排在 REJECT 之后：$(cat "$I/after-allow")"; fi
  if before_reject "$TAG_RT" "$I/file-allow"; then ok_ '同时写进开机规则文件，位置正确'; else bad_ "开机规则文件没写对：$(cat "$I/file-allow")"; fi
  eq_ '写过的规则文件仍能被 iptables-restore 载入' "$(cat "$I/file-valid")" 0
  if grep -q '已写入开机规则' "$I/allow.out"; then ok_ '告知用户已持久化'; else bad_ "输出：$(cat "$I/allow.out")"; fi
  eq_ '重复执行不重复添加（运行时）' "$(grep -cF -- "$TAG_RT" "$I/after-again")" 1
  eq_ '重复执行不重复添加（规则文件）' "$(grep -cF -- "$TAG_RT" "$I/file-again")" 1
  eq_ 'reality check 认可放行结果' "$(cat "$I/ck")" ok
  eq_ '撤销后本脚本的规则已删除' "$(grep -cF -- "$TAG_RT" "$I/after-revoke")" 0
  eq_ '用户自己的同端口规则原样保留' "$(grep -cF -- '--dport 443 -j ACCEPT' "$I/after-revoke")" 1
  if cmp -s "$I/file-revoke" "$I/orig"; then ok_ '规则文件恢复原样'; else bad_ "规则文件有残留：$(diff "$I/orig" "$I/file-revoke")"; fi
  eq_ '本来就全放行的机器不加规则' "$(cat "$I/permissive")" '-P INPUT ACCEPT'
  eq_ 'reality open-port 补救已装好的机器' "$(cat "$I/open-rc")" 0
  if before_reject "$TAG_RT" "$I/after-open"; then ok_ 'open-port 之后端口已放行'; else bad_ "open-port 没有放行：$(cat "$I/open.out")"; fi
fi
# 本机（非命名空间）上只验证命令接线：本机 INPUT 若全放行，它什么都不改
if $NEW open-port >/dev/null 2>&1; then ok_ 'open-port 命令可用'; else bad_ 'open-port 执行失败'; fi
msg=$($NEW open-port 443 2>&1)
if [[ $msg == *不接受参数* ]]; then ok_ 'open-port 拒绝多余参数'; else bad_ "open-port 接受了多余参数：$msg"; fi

group 'H. 完整生命周期'
for c in 'change-port 8443' 'add-user 手机' 'rekey' 'change-sni www.microsoft.com' 'del-user 手机' 'change-port 443'; do
  # shellcheck disable=SC2086  # $c 需要按空格拆成命令与参数
  if $NEW $c --yes >/dev/null 2>&1; then ok_ "$c"; else bad_ "$c"; fi
done
if xtest; then ok_ '全部操作后配置仍通过 Xray 校验'; else bad_ '配置校验失败'; fi
eq_ 'config.json 权限 600 且归属 nobody' "$(stat -c '%a %U' "$CONF")" '600 nobody'
eq_ 'meta.conf 权限 600'                "$(stat -c %a "$META")"      '600'
$NEW uninstall --yes >/dev/null 2>&1
if [[ -e /usr/local/etc/xray || -e /usr/local/bin/xray ]]; then bad_ '卸载有残留'; else ok_ '卸载干净'; fi

summary
