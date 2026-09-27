#!/usr/bin/env bash
# 单元测试：把 install.sh 当库加载，直接调用内部函数。
# 不需要 root，所有读写都在临时目录里，不会改动系统。
#
#   bash tests/unit.sh

# 本文件的写法是"先设全局变量，再调用 install.sh 里的函数去读它们"
# （如 save_meta 经 ${!k} 读 PRIVATE_KEY），以及在 eval 字符串里引用变量。
# 静态检查单独分析本文件时看不到这些读取，会误报"变量未使用"。
# shellcheck disable=SC2034

# shellcheck source=tests/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
trap 'rm -rf "$WORK"' EXIT

setup_xray
make_lib "$REPO/install.sh" "$WORK/lib.sh"
export REALITY_LIB=1
# shellcheck disable=SC1091
source "$WORK/lib.sh"
trap - ERR            # install.sh 自带的 ERR trap 与 set -e 不适合测试环境
set +Eeuo pipefail

# 全部必须被 valid_addr 拒绝。注入样本写到本次的临时目录，避免被上一次残留误判
PWNED="$WORK/PWNED"
PAYLOADS=(
  "my'host.com"
  "x'\$(touch\${IFS}$PWNED)'x"
  'a"b.com'
  'a$b.com'
  'a;b.com'
  'a`id`b.com'
  'a|b.com'
  'a&b.com'
  'a\b.com'
  ''
)

group '1. valid_ipv4'
yes_ '1.2.3.4'            'valid_ipv4 1.2.3.4'
yes_ '255.255.255.255'    'valid_ipv4 255.255.255.255'
no_  '256.1.1.1 越界'     'valid_ipv4 256.1.1.1'
no_  '1.2.3 缺段'         'valid_ipv4 1.2.3'
no_  '1.2.3.4.5 多段'     'valid_ipv4 1.2.3.4.5'
no_  '带引号'             "valid_ipv4 \"1.2.3.4'\""

group '2. valid_ipv6'
yes_ '2001:db8::1'        'valid_ipv6 2001:db8::1'
yes_ '::1'                'valid_ipv6 ::1'
yes_ 'v4 映射 ::ffff:1.2.3.4' 'valid_ipv6 ::ffff:1.2.3.4'
yes_ '完整写法'           'valid_ipv6 2001:0db8:0000:0000:0000:0000:0000:0001'
no_  '1:2 冒号不够'       'valid_ipv6 1:2'
no_  '非十六进制'         'valid_ipv6 2001:db8::zz'
no_  '带命令替换'         "valid_ipv6 '2001:db8::\$(id)'"

group '3. valid_addr 接受合法地址'
yes_ 'IPv4'  'valid_addr 1.2.3.4'
yes_ 'IPv6'  'valid_addr 2001:db8::1'
yes_ '域名'  'valid_addr node.example.com'

group '3b. valid_addr 拒绝全部注入样本'
for p in "${PAYLOADS[@]}"; do
  if valid_addr "$p"; then bad_ "放行了危险值: [$p]"; else ok_ "拒绝 [$p]"; fi
done

group '4. valid_dest'
yes_ '域名:端口'          'valid_dest www.nvidia.com:443'
yes_ 'IPv4:端口'          'valid_dest 1.2.3.4:443'
yes_ '[IPv6]:端口'        'valid_dest "[2001:db8::1]:443"'
no_  '缺端口'             'valid_dest www.nvidia.com'
no_  '缺主机'             'valid_dest :443'
no_  '端口 0'             'valid_dest a.com:0'
no_  '端口越界'           'valid_dest a.com:99999'
no_  '带引号'             "valid_dest \"a'b.com:443\""
no_  'IPv6 不带方括号'    'valid_dest 2001:db8::1:443'
no_  '方括号里不是 IPv6'  'valid_dest "[zzz]:443"'

group '5. strip_brackets'
eq_ '去掉方括号' "$(strip_brackets '[2001:db8::1]')" '2001:db8::1'
eq_ 'IPv4 不变'  "$(strip_brackets 1.2.3.4)"         '1.2.3.4'

group '6. save_meta / load_meta：危险值原样往返且绝不执行'
# 绕过 valid_addr 直接喂给 save_meta，验证第二层防护独立生效
for p in "${PAYLOADS[@]}"; do
  PORT=443; SNI=www.nvidia.com; DEST=www.nvidia.com:443
  PRIVATE_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
  PUBLIC_KEY=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
  SHORT_IDS=0123456789abcdef; BLOCK_BT=1; BLOCK_ADS=0
  NODE_HOST=$p
  save_meta
  NODE_HOST='<未加载>'
  load_meta
  if [[ $NODE_HOST == "$p" ]]; then ok_ "往返一致 [$p]"; else bad_ "往返不一致 [$p] → [$NODE_HOST]"; fi
done
if [[ -e $PWNED ]]; then bad_ '注入样本被执行了'; else ok_ '注入样本均未被执行'; fi
eq_ 'meta.conf 权限'   "$(stat -c %a "$META_FILE")"                  '600'
eq_ '没有残留临时文件' "$(find "$DATA_DIR" -name '.meta.*' | wc -l)" '0'

group '7. load_meta 拒绝已损坏的文件（旧 bug 写出来的样子）'
cat >"$META_FILE" <<'EOF'
PORT='443'
SNI='www.nvidia.com'
PRIVATE_KEY='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
PUBLIC_KEY='BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
NODE_HOST='my'host.com'
BLOCK_BT='1'
EOF
no_ '未闭合引号的文件被拒绝加载' 'load_meta'

group '8. 向后兼容：v1.2.1 及之前格式的 meta.conf 仍能加载'
cat >"$META_FILE" <<'EOF'
# 由 VLESS + Reality + Vision 一键脚本 生成，请勿手工编辑
PORT='8443'
DEST='www.nvidia.com:443'
SNI='www.nvidia.com'
PRIVATE_KEY='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
PUBLIC_KEY='BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
SHORT_IDS='0123456789abcdef,fedcba9876543210'
NODE_HOST='1.2.3.4'
BLOCK_BT='1'
BLOCK_ADS='0'
EOF
PORT=''; NODE_HOST=''; SHORT_IDS=''
yes_ '旧格式可加载' 'load_meta'
eq_  'PORT'      "$PORT"      '8443'
eq_  'NODE_HOST' "$NODE_HOST" '1.2.3.4'
eq_  'SHORT_IDS' "$SHORT_IDS" '0123456789abcdef,fedcba9876543210'

group '9. listen_addr 决策表（模拟不同网络环境）'
# 用同名函数盖掉真实命令，listen_addr 在 $() 子 shell 里调用时同样生效
ip() {
  case $1 in
    -6) [[ $MOCK_V6 == 1 ]] && echo '    inet6 2001:db8::1/64 scope global' ;;
    -4) [[ $MOCK_V4 == 1 ]] && echo '    inet 1.2.3.4/24 scope global' ;;
  esac
}
sysctl() { [[ $* == *bindv6only* ]] && echo "$MOCK_BINDV6ONLY"; }
MOCK_V4=1 MOCK_V6=0 MOCK_BINDV6ONLY=0; eq_ '纯 IPv4'                     "$(listen_addr)" '0.0.0.0'
MOCK_V4=1 MOCK_V6=1 MOCK_BINDV6ONLY=0; eq_ '双栈（默认）'                "$(listen_addr)" '::'
MOCK_V4=0 MOCK_V6=1 MOCK_BINDV6ONLY=0; eq_ '纯 IPv6'                     "$(listen_addr)" '::'
MOCK_V4=0 MOCK_V6=1 MOCK_BINDV6ONLY=1; eq_ '纯 IPv6 + bindv6only=1'      "$(listen_addr)" '::'
MOCK_V4=1 MOCK_V6=1 MOCK_BINDV6ONLY=1; eq_ '双栈 + bindv6only=1 保 IPv4' "$(listen_addr)" '0.0.0.0'

group '10. 生成的配置交给真实 Xray 校验（两种监听地址）'
PORT=443; SNI=www.nvidia.com; DEST=www.nvidia.com:443; BLOCK_BT=1; BLOCK_ADS=1
gen_keypair
SHORT_IDS="$(gen_shortid),$(gen_shortid)"
printf 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\thk\n' >"$USERS_FILE"
for v6 in 0 1; do
  MOCK_V4=1 MOCK_V6=$v6 MOCK_BINDV6ONLY=0
  render_config >"$WORK/cfg-$v6.json"
  # run -test 会初始化日志组件，把日志指到临时目录，免得非 root 时写不了 /var/log
  sed -i "s#/var/log/xray/error.log#$WORK/error.log#" "$WORK/cfg-$v6.json"
  l=$(grep -oP '(?<="listen": ")[^"]+' "$WORK/cfg-$v6.json")
  if XRAY_LOCATION_ASSET=$XRAY_DIR "$XRAY_DIR/xray" run -test -format json \
       -config "$WORK/cfg-$v6.json" 2>&1 | grep -q 'Configuration OK'; then
    ok_ "listen=\"$l\" 的配置通过 Xray 校验"
  else
    bad_ "listen=\"$l\" 的配置未通过校验"
  fi
done
unset -f ip sysctl

group '11. 原有核心行为未被改坏'
yes_ 'valid_port 443'      'valid_port 443'
no_  'valid_port 0'        'valid_port 0'
yes_ 'valid_host 域名'     'valid_host www.apple.com'
no_  'valid_host 无点'     'valid_host localhost'
yes_ 'valid_label 中文'    'valid_label 香港节点'
no_  'valid_label 引号'    "valid_label 'a\"b'"
eq_  'urlencode 中文'      "$(urlencode '香港')"     '%E9%A6%99%E6%B8%AF'
eq_  'disp_width 中英混排' "$(disp_width '中文abc')" '7'
eq_  'disp_width 框线单宽' "$(disp_width '─')"       '1'
NODE_HOST=203.0.113.9; HOST_CACHE=''
link=$(share_link aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee hk)
yes_ '分享链接主体'        '[[ $link == vless://aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee@203.0.113.9:443\?* ]]'
yes_ '分享链接含 Vision'   '[[ $link == *flow=xtls-rprx-vision* ]]'
yes_ '分享链接含 Reality'  '[[ $link == *security=reality* ]]'
NODE_HOST=2001:db8::1; HOST_CACHE=''
eq_  'IPv6 链接加方括号'   "$(link_host)" '[2001:db8::1]'

summary
