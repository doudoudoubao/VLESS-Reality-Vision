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
cleanup() { rm -rf "${CREATED[@]}" "$WORK"; }
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

group 'D. install 的 --host / --dest 校验'
for bad in "a'b" 'a"b.com' '$(id)'; do
  rm -rf /usr/local/etc/xray
  if $NEW install --yes --host "$bad" >/dev/null 2>&1; then bad_ "install --host 接受了 [$bad]"; else ok_ "install --host 拒绝 [$bad]"; fi
done
for bad in "a'b.com:443" 'www.nvidia.com' 'a.com:99999'; do
  rm -rf /usr/local/etc/xray
  if $NEW install --yes --host 1.2.3.4 --dest "$bad" >/dev/null 2>&1; then bad_ "install --dest 接受了 [$bad]"; else ok_ "install --dest 拒绝 [$bad]"; fi
done
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

group 'F. 完整生命周期'
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
