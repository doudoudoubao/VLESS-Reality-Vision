#!/usr/bin/env bash
# 单元测试：把 install.sh 当库加载，直接调用内部函数。
# 不需要 root，所有读写都在临时目录里，不会改动系统。
#
#   bash tests/unit.sh

# 本文件的写法是"先设全局变量，再调用 install.sh 里的函数去读它们"
# （如 save_meta 经 ${!k} 读 PRIVATE_KEY），以及在 eval 字符串里引用变量。
# 静态检查单独分析本文件时看不到这些读取，会误报"变量未使用"。
# 同理，有些用例先调用 install.sh 里的真实函数、再定义同名函数去模拟它，
# 静态检查只看得到后者，会误报"函数在定义之前被调用"（SC2218）。
# shellcheck disable=SC2034,SC2218

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
  render_config >"$WORK/cfg-$v6.json"   # 日志路径已由 make_lib 指到临时目录
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

# ---------------------------------------------------------------------------
# 12–15：reality check 的各项检查。检查函数只设置 CK_STATUS / CK_DETAIL / CK_HINT，
# 用同名函数盖掉系统命令来模拟各种机器状态，不依赖本机网络与防火墙。
# 外部的 timeout 调不到 shell 函数，所以先把 run_timeout 换成直接执行
run_timeout() { shift; "$@"; }
# 模拟系统命令的函数用完 unset -f 即可；install.sh 自己的函数不行——
# unset 会连真实实现一起删掉，要先 save_fn 存下，测完 restore_fns 放回去
SAVED_FNS=()
save_fn()     { SAVED_FNS+=("$(declare -f "$1")"); }
restore_fns() { local f; for f in "${SAVED_FNS[@]}"; do eval "$f"; done; SAVED_FNS=(); }
ck_is() { # ck_is <说明> <期望状态> [详情应包含] [提示应包含]
  local what="$1（${CK_STATUS}：${CK_DETAIL}${CK_HINT:+ → ${CK_HINT}}）"
  if [[ $CK_STATUS == "$2" && $CK_DETAIL == *"${3:-}"* && $CK_HINT == *"${4:-}"* ]]; then
    ok_ "$what"
  else
    bad_ "$what，期望 $2${3:+ / 详情含「$3」}${4:+ / 提示含「$4」}"
  fi
}

group '12. 探测函数的参数与返回值'
# check_dest 在 $() 里调用 openssl，参数只能经文件带出来
openssl() {
  if [[ $1 == s_client && $2 == -help ]]; then [[ $MOCK_OSSL == old ]] || echo ' -tls1_3'; return 0; fi
  printf '%s\n' "$*" >"$WORK/openssl-args"
  case $MOCK_OSSL in
    ok)      printf 'Protocol  : TLSv1.3\nALPN protocol: h2\n' ;;
    noh2)    printf 'Protocol  : TLSv1.3\nNo ALPN negotiated\n' ;;
    notls13) printf 'Protocol  : TLSv1.2\nALPN protocol: h2\n' ;;
    *)       return 1 ;;
  esac
}
args() { cat "$WORK/openssl-args"; }
MOCK_OSSL=ok
check_dest www.nvidia.com
yes_ 'SNI 默认与目标相同'  '[[ $(args) == *"-connect www.nvidia.com:443 -servername www.nvidia.com "* ]]'
check_dest 1.2.3.4 8443 www.nvidia.com
yes_ '目标与 SNI 不同时分别传入' '[[ $(args) == *"-connect 1.2.3.4:8443 -servername www.nvidia.com "* ]]'
check_dest 2001:db8::1 443 www.nvidia.com
yes_ 'IPv6 目标加方括号'   '[[ $(args) == *"-connect [2001:db8::1]:443 "* ]]'
for c in ok:0 fail:1 noh2:2 notls13:3 old:4; do
  MOCK_OSSL=${c%:*}; check_dest www.nvidia.com; eq_ "check_dest 返回码（${c%:*}）" "$?" "${c#*:}"
done
unset -f openssl args

# public_ip 的结果会写进 meta.conf 和分享链接，服务返回什么都不能原样收下
curl() { printf '%s\n' "$1" >"$WORK/curl-flag"; printf '%s' "$MOCK_CURL"; }
MOCK_CURL=1.2.3.4;       eq_ 'IPv4 正常返回'    "$(public_ip 4)" '1.2.3.4'
MOCK_CURL=999.1.1.1;     no_ '拒绝越界的 IPv4'  'public_ip 4'
MOCK_CURL='<html>err';   no_ '拒绝 HTML 错误页' 'public_ip 4'
MOCK_CURL=2001:db8::1;   eq_ 'IPv6 正常返回'    "$(public_ip 6)" '2001:db8::1'
eq_ 'IPv6 探测强制走 IPv6' "$(cat "$WORK/curl-flag")" '-fsS6'
MOCK_CURL='a:$(reboot)'; no_ '拒绝带命令替换的"IPv6"' 'public_ip 6'
MOCK_CURL=1.2.3.4;       no_ 'IPv6 探测不收 IPv4'   'public_ip 6'
unset -f curl

group '13. 端口与防火墙'
for c in 443:443 443:80,443 443:400:500 443:80,400:500 \
         443:4430! 443:44! 443:80,8443! 443:444:500! 443:abc!; do
  p=${c%%:*} l=${c#*:}
  if [[ $l == *! ]]; then no_ "port_listed $p 不在 ${l%!} 里" "port_listed $p '${l%!}'"
  else yes_ "port_listed $p 在 $l 里" "port_listed $p '$l'"; fi
done

PORT=443
MOCK_SS_HEAD='State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process'
# 模拟老版本 ss：不认识 -H（去掉表头）选项，直接报错
ss() {
  [[ $1 == -*H* ]] && { echo "ss: invalid option -- 'H'" >&2; return 255; }
  printf '%s\n%s\n' "$MOCK_SS_HEAD" "$MOCK_SS"
}
MOCK_SS='LISTEN 0 4096 *:443 *:*'
yes_ '老版本 ss 也能查出端口占用' 'port_in_use 443'
no_  '4430 不算 443 被占用'      'port_in_use 4430'
no_  '表头不会被当成端口'        'port_in_use Port'
MOCK_SS='LISTEN 0 4096 *:443 *:* users:(("xray",pid=1,fd=3))';       ck_port; ck_is 'Xray 在听' ok Xray
MOCK_SS='LISTEN 0 4096 [::]:443 [::]:* users:(("xray",pid=1,fd=3))'; ck_port; ck_is 'Xray 在听 IPv6' ok Xray
MOCK_SS='';                                                          ck_port; ck_is '没人在听' fail '没有程序' 'reality log'
MOCK_SS='LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=2,fd=6))'
ck_port; ck_is '被 nginx 占用' fail nginx 'change-port'
MOCK_SS='LISTEN 0 4096 *:4430 *:* users:(("xray",pid=1,fd=3))';      ck_port; ck_is '4430 不算 443' fail
MOCK_SS='LISTEN 0 4096 *:443 *:*';                                   ck_port; ck_is '看不到进程信息' ok '正在监听'
unset -f ss
PATH=/nonexistent ck_port; ck_is '没有 ss 命令' skip

# 防火墙三家都用函数模拟；iptables 在开发容器里是真实存在的，也必须盖掉
ufw()          { [[ $* == 'status verbose' ]] && printf '%s\n' "$MOCK_UFW"; }
firewall-cmd() {
  case $1 in
    --state)          [[ $MOCK_FWD != off ]] ;;
    --query-port=*)   [[ $MOCK_FWD == *"port:${1#*=}"* ]] ;;
    --query-service=*) [[ $MOCK_FWD == *"svc:${1#*=}"* ]] ;;
  esac
}
iptables()     { [[ $* == '-S INPUT' ]] && printf '%s\n' "$MOCK_IPT"; }
UFW_HEAD=$'Status: active\nDefault: deny (incoming), allow (outgoing), disabled (routed)\n\nTo                         Action      From\n--                         ------      ----'
ufw_rules() { MOCK_UFW="$UFW_HEAD"$'\n'"$(printf '%s\n' "$@")"; }

MOCK_FWD=off MOCK_IPT='-P INPUT ACCEPT'
ufw_rules '22/tcp                     ALLOW IN    Anywhere' \
          '443/tcp                    ALLOW IN    Anywhere' \
          '443/tcp (v6)               ALLOW IN    Anywhere (v6)'
ck_firewall; ck_is 'ufw 放行了 443/tcp' ok ufw
ufw_rules '22/tcp                     ALLOW IN    Anywhere'
ck_firewall; ck_is 'ufw 只放行了 22' fail ufw 'reality open-port'
ufw_rules '4430/tcp                   ALLOW IN    Anywhere'
ck_firewall; ck_is 'ufw 的 4430 不算 443' fail
ufw_rules '443/udp                    ALLOW IN    Anywhere'
ck_firewall; ck_is 'ufw 只放行了 UDP' fail
ufw_rules '80,443/tcp                 ALLOW IN    Anywhere'
ck_firewall; ck_is 'ufw 多端口写法' ok
ufw_rules '400:500/tcp                ALLOW IN    Anywhere'
ck_firewall; ck_is 'ufw 端口范围' ok
ufw_rules '443                        LIMIT IN    Anywhere'
ck_firewall; ck_is 'ufw LIMIT 也算放行' ok
MOCK_UFW=${UFW_HEAD/deny (incoming)/allow (incoming)}
ck_firewall; ck_is 'ufw 默认放行入站' ok '默认放行'
MOCK_UFW='Status: inactive'
ck_firewall; ck_is 'ufw 未启用时不看它' ok '未发现'

MOCK_FWD='port:443/tcp'; ck_firewall; ck_is 'firewalld 放行了端口' ok firewalld
MOCK_FWD='svc:https';    ck_firewall; ck_is 'firewalld 的 https 服务等于放行 443' ok
PORT=8443;               ck_firewall; ck_is 'https 服务不管 8443' fail firewalld 'reality open-port'
PORT=443 MOCK_FWD='svc:ssh'
ck_firewall; ck_is 'firewalld 没放行' fail firewalld 'reality open-port'
MOCK_FWD=off

# 甲骨文云系统镜像自带的规则：只放行 22，最后一条拒绝其余所有入站
ORACLE_HEAD='-P INPUT ACCEPT
-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A INPUT -p icmp -j ACCEPT
-A INPUT -i lo -j ACCEPT
-A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT'
ORACLE_REJECT='-A INPUT -j REJECT --reject-with icmp-host-prohibited'
ACCEPT_443='-A INPUT -p tcp -m state --state NEW -m tcp --dport 443 -j ACCEPT'
MOCK_IPT="$ORACLE_HEAD"$'\n'"$ORACLE_REJECT"
ck_firewall; ck_is '甲骨文云默认规则拒绝 443' fail iptables 'reality open-port'
MOCK_IPT="$ORACLE_HEAD"$'\n'"$ACCEPT_443"$'\n'"$ORACLE_REJECT"
ck_firewall; ck_is '放行规则在拒绝之前' ok iptables
MOCK_IPT="$ORACLE_HEAD"$'\n'"$ORACLE_REJECT"$'\n'"$ACCEPT_443"
ck_firewall; ck_is '用 -A 追加到拒绝之后：不生效' fail '排在拒绝规则后面' 'reality open-port'
MOCK_IPT="$ORACLE_HEAD"$'\n''-A INPUT -p tcp -m multiport --dports 80,443 -j ACCEPT'$'\n'"$ORACLE_REJECT"
ck_firewall; ck_is 'multiport 写法' ok
MOCK_IPT="$ORACLE_HEAD"$'\n''-A INPUT -p udp -m udp --dport 443 -j ACCEPT'$'\n'"$ORACLE_REJECT"
ck_firewall; ck_is '只放行了 UDP 443' fail
MOCK_IPT="$ORACLE_HEAD"$'\n''-A INPUT -p tcp -m tcp --dport 4430 -j ACCEPT'$'\n'"$ORACLE_REJECT"
ck_firewall; ck_is 'iptables 的 4430 不算 443' fail
MOCK_IPT=$'-P INPUT DROP\n-A INPUT -p tcp -m tcp --dport 22 -j ACCEPT'
ck_firewall; ck_is '默认策略 DROP' fail iptables
MOCK_IPT=$'-P INPUT DROP\n-A INPUT -p tcp -m tcp --dport 443 -j ACCEPT'
ck_firewall; ck_is '默认策略 DROP 但放行了 443' ok
MOCK_IPT=$'-P INPUT ACCEPT\n-A INPUT -s 10.0.0.0/8 -j DROP'
ck_firewall; ck_is '带条件的 DROP 不当作全部拒绝' ok '未发现'
iptables() { return 1; }   # 非 root 时 iptables -S 会失败
ck_firewall; ck_is 'iptables 读不到规则时不误报' ok '未发现'
unset -f ufw firewall-cmd iptables ufw_rules

group '14. 服务、配置、时间、DNS、伪装目标、分享地址、日志'
systemctl() {
  case "$*" in
    *is-active*)       echo "$MOCK_STATE"; [[ $MOCK_STATE == active ]] ;;
    *'show -p User'*)  id -un ;;
  esac
}
MOCK_STATE=active;     ck_service; ck_is '服务运行中' ok
MOCK_STATE=failed;     ck_service; ck_is '服务启动失败' fail '启动失败' 'reality restart'
MOCK_STATE=activating; ck_service; ck_is '服务反复重启' fail '反复崩溃重启'
MOCK_STATE=inactive;   ck_service; ck_is '服务已停止' fail '已停止'
MOCK_STATE='';         ck_service; ck_is '状态未知' fail '状态未知'

ck_binary; ck_is '内核能运行' ok Xray
eq_ '内核正常时不影响配置检查' "$CK_BIN_OK" 1
export XRAY_LOCATION_ASSET=$XRAY_DIR   # 路由里的 geoip:private 要读数据文件
PORT=443 NODE_HOST=1.2.3.4
render_config >"$XRAY_CONF"; chmod 600 "$XRAY_CONF" "$META_FILE"
ck_config; ck_is '配置通过自检、权限正确' ok
chmod 644 "$XRAY_CONF"
ck_config; ck_is '配置 644 时提醒' warn 644 "chmod 600 $XRAY_CONF"
chmod 600 "$XRAY_CONF"; chmod 644 "$META_FILE"
ck_config; ck_is 'meta.conf 644 时提醒' warn meta.conf "chmod 600 $META_FILE"
chmod 600 "$META_FILE"
cp "$XRAY_CONF" "$WORK/good.json"
printf '{ "inbounds": [ { "port": 08443 } ] }' >"$XRAY_CONF"
ck_config; ck_is '配置坏了：直接给出 Xray 的原因' fail 'invalid character' 'xray run -test'
cp "$WORK/good.json" "$XRAY_CONF"
save_fn xray_version; xray_version() { :; }
ck_binary; ck_is '内核跑不起来' fail '' 'reality update'
ck_config; ck_is '内核跑不起来时跳过配置检查，不重复报错' skip
restore_fns; CK_BIN_OK=1

timedatectl() { [[ $1 == show && $MOCK_NTP != fail ]] && echo "$MOCK_NTP"; }
MOCK_NTP=yes;  ck_clock; ck_is '时间已同步' ok
MOCK_NTP=no;   ck_clock; ck_is '时间未同步只提醒' warn
MOCK_NTP=fail; ck_clock; ck_is '读不到状态时跳过，不当成未同步' skip
# 安装时的 check_clock 同理：容器型 VPS 读不到状态，不该刷出一串用户改不了的警告
MOCK_NTP=fail; eq_ '安装时读不到时间状态：不提示' "$(check_clock 2>&1)" ''
MOCK_NTP=no;   yes_ '安装时确实未同步：照常提示' '[[ $(check_clock 2>&1) == *未与\ NTP\ 同步* ]]'
unset -f timedatectl

getent() {
  local a
  case $1 in
    hosts)  [[ -n $MOCK_DNS ]] && echo "$MOCK_DNS $2" ;;
    ahosts) for a in ${MOCK_AHOSTS:-}; do printf '%s  STREAM %s\n' "$a" "$2"; done
            [[ -n ${MOCK_AHOSTS:-} ]] ;;
  esac
}
SNI=www.nvidia.com
MOCK_DNS=1.2.3.4; ck_dns; ck_is 'DNS 正常' ok;   eq_ 'DNS 正常时放行后续检查' "$CK_DNS_OK" 1
MOCK_DNS='';      ck_dns; ck_is 'DNS 不通' fail; eq_ 'DNS 不通时标记'         "$CK_DNS_OK" 0

save_fn check_dest; check_dest() { MOCK_DEST_ARGS="$*"; return "$MOCK_DEST_RC"; }
CK_DNS_OK=1 MOCK_DEST_RC=0
DEST=www.nvidia.com:443;  ck_dest; ck_is '伪装目标可用' ok
eq_ '按 DEST 拆出主机与端口，SNI 另传' "$MOCK_DEST_ARGS" 'www.nvidia.com 443 www.nvidia.com'
DEST=1.2.3.4:8443;        ck_dest; eq_ 'IP:端口形式' "$MOCK_DEST_ARGS" '1.2.3.4 8443 www.nvidia.com'
DEST='[2001:db8::1]:443'; ck_dest; eq_ 'IPv6 去掉方括号' "$MOCK_DEST_ARGS" '2001:db8::1 443 www.nvidia.com'
DEST=www.nvidia.com:443
MOCK_DEST_RC=1; ck_dest; ck_is '握手失败' fail '' 'change-sni'
MOCK_DEST_RC=2; ck_dest; ck_is '不再支持 h2' fail 'HTTP/2' 'change-sni'
MOCK_DEST_RC=3; ck_dest; ck_is '不再支持 TLS1.3' fail 'TLS1.3'
MOCK_DEST_RC=4; ck_dest; ck_is 'openssl 太旧' skip
CK_DNS_OK=0 MOCK_DEST_ARGS=''
ck_dest; ck_is 'DNS 不通时跳过域名目标' skip; eq_ '且没有去探测' "$MOCK_DEST_ARGS" ''
DEST=1.2.3.4:443 MOCK_DEST_RC=0
ck_dest; ck_is 'DNS 不通不影响 IP 目标' ok
CK_DNS_OK=1; restore_fns

save_fn public_ip; save_fn local_addrs
public_ip()   { local v="MOCK_PUB$1"; [[ -n ${!v:-} ]] && printf '%s' "${!v}"; }
local_addrs() { printf '%s\n' ${MOCK_LOCAL:-}; }
host_case() { # host_case <说明> <NODE_HOST> <解析结果> <出口 v4> <出口 v6> <期望> [详情] [提示]
  NODE_HOST=$2 MOCK_AHOSTS=$3 MOCK_PUB4=$4 MOCK_PUB6=$5
  ck_host; ck_is "$1" "${@:6}"
}
MOCK_LOCAL='10.0.0.5'
host_case '未设置地址'          ''              ''                        ''      ''            warn '' 'change-host'
host_case 'IP 与出口一致'        1.2.3.4         1.2.3.4                   1.2.3.4 ''            ok   '指向本机'
host_case '服务器换了 IP'        1.2.3.4         1.2.3.4                   5.6.7.8 ''            fail 5.6.7.8 'change-host 5.6.7.8'
host_case '探测不到公网 IP'      1.2.3.4         1.2.3.4                   ''      ''            skip
host_case '域名指向本机'         node.example.com 1.2.3.4                  1.2.3.4 ''            ok
host_case '域名指向别处'         node.example.com 9.9.9.9                  1.2.3.4 ''            fail node.example.com
host_case '域名解析不到'         node.example.com ''                       1.2.3.4 ''            fail '解析不到'
host_case 'IPv6 地址'            2001:db8::1     2001:db8::1               ''      2001:db8::1   ok
host_case '双栈：v6 对上即可'    node.example.com '1.2.3.4 2001:db8::1'    5.6.7.8 2001:db8::1   ok
host_case '本机无 v6 栈时按原值比' 2001:DB8::1   ''                        ''      2001:db8::1   ok
host_case '/etc/hosts 指到回环'  node.example.com 127.0.1.1                1.2.3.4 ''            skip '回环'
MOCK_LOCAL='10.0.0.5 203.0.113.7'
host_case '多 IP 机器：地址在网卡上' 203.0.113.7 203.0.113.7               1.2.3.4 ''            ok
restore_fns; unset -f getent host_case

: >"$XRAY_LOG"
ck_log; ck_is '没有日志' ok
now=$(date '+%Y/%m/%d %H:%M:%S') old=$(date -d '3 days ago' '+%Y/%m/%d %H:%M:%S')
cat >"$XRAY_LOG" <<EOF
$old.100000 [Error] 三天前的错误
$now.100000 [Warning] core: Xray 26.3.27 started
EOF
ck_log; ck_is '只有旧错误和警告' ok '没有错误'
cat >>"$XRAY_LOG" <<EOF
$now.200000 [Error] [1234567890] app/dispatcher: first
$now.300000 [Error] [3183754453] proxy/freedom: second
EOF
ck_log; ck_is '近期错误计数并显示最近一条' warn '2 条错误，最近一条：proxy/freedom: second' 'reality log'
unset -f systemctl

group '15. reality check 汇总与退出码'
run_check() { # run_check [检查项=状态]…：其余项都返回 ok
  (
    require_installed() { :; }
    local c kv
    for c in binary config service port firewall clock dns dest host log; do
      eval "ck_${c}() { ck_set ok 'DETAIL'; }"
    done
    for kv in "$@"; do
      eval "ck_${kv%%=*}() { ck_set ${kv#*=} 'DETAIL' 'HINT-${kv%%=*}'; }"
    done
    cmd_check
  )
}
out=$(run_check); rc=$?
eq_ '全部正常：退出码 0' "$rc" 0
yes_ '全部正常：总结'     '[[ $out == *全部正常* ]]'
no_  '正常项不显示提示'   '[[ $out == *→* ]]'
for l in 'Xray 内核' '配置文件' '服务状态' '端口监听' '本机防火墙' '系统时间' 'DNS 解析' '伪装目标' '分享地址' '错误日志'; do
  yes_ "列出「$l」" "[[ \$out == *'✓ $l'* ]]"
done
# 中文是双宽字符，按字节补空格会错位：每行详情都应从同一列开始
widths=$(grep DETAIL <<<"$out" | while IFS= read -r line; do disp_width "${line%%DETAIL*}"; echo; done | sort -u)
eq_ '十行详情左对齐' "$(wc -l <<<"$widths")" 1

out=$(run_check log=warn); rc=$?
eq_ '只有提醒：退出码 0' "$rc" 0
yes_ '只有提醒：总结'     '[[ $out == *"没有发现问题，有 1 个提醒"* ]]'
yes_ '提醒项显示提示'     '[[ $out == *"→ HINT-log"* ]]'
out=$(run_check port=fail log=warn); rc=$?
eq_ '有问题：退出码 1'    "$rc" 1
yes_ '有问题：总结'       '[[ $out == *"发现 1 个问题，另有 1 个提醒"* ]]'
yes_ '失败项标记为 ✗'     '[[ $out == *"✗ 端口监听"* ]]'
out=$(run_check dest=skip); rc=$?
eq_ '跳过不算问题'        "$rc" 0
yes_ '跳过项标记为 -'     '[[ $out == *"- 伪装目标"* ]]'

out=$(is_installed() { return 1; }; show_menu)
yes_ '菜单里有 18 节点诊断' '[[ $out == *"18"*节点诊断* ]]'

group '16. 甲骨文云式 iptables：安装时自动放行'
# 真实 iptables 的行为由 e2e 在独立网络命名空间里测；这里测规则文件的改写与各种决策分支
RULES=$WORK/rules.v4
cat >"$WORK/rules.orig" <<'EOF'
*nat
:PREROUTING ACCEPT [0:0]
-A PREROUTING -p tcp -m tcp --dport 8080 -j REDIRECT --to-ports 80
COMMIT
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT
-A INPUT -j REJECT --reject-with icmp-host-prohibited
COMMIT
EOF
TAG443='-A INPUT -p tcp -m tcp --dport 443 -m comment --comment reality -j ACCEPT'
TAG4430='-A INPUT -p tcp -m tcp --dport 4430 -m comment --comment reality -j ACCEPT'
line_of() { grep -nF -- "$1" "$2" | head -n1 | cut -d: -f1; }
cnt()     { grep -cF -- "$1" "$2"; }

cp "$WORK/rules.orig" "$RULES"
yes_ '写入开机规则文件'                  'ipt_file_add "$RULES" 443'
eq_  '插在 filter 表第一条 INPUT 规则之前' "$(line_of "$TAG443" "$RULES")" "$(( $(line_of '-A INPUT -m state' "$RULES") - 1 ))"
yes_ '不会插进 nat 表'                    '(( $(line_of "$TAG443" "$RULES") > $(line_of "*filter" "$RULES") ))'
ipt_file_add "$RULES" 443
eq_  '重复写入不重复'                     "$(cnt "$TAG443" "$RULES")" 1
ipt_file_add "$RULES" 4430
sed -i "s/^-A INPUT -j REJECT/-A INPUT -p tcp -m tcp --dport 443 -j ACCEPT\n&/" "$RULES"   # 用户自己的规则
ipt_file_del "$RULES" 443
eq_  '删除本脚本的 443 规则'              "$(cnt "$TAG443" "$RULES")" 0
eq_  '不动 4430 的规则'                   "$(cnt "$TAG4430" "$RULES")" 1
eq_  '不动用户自己的 443 规则'            "$(cnt '--dport 443 -j ACCEPT' "$RULES")" 1
cp "$WORK/rules.orig" "$RULES"; ipt_file_add "$RULES" 443; ipt_file_del "$RULES" 443
yes_ '加了再删，文件恢复原样'             'cmp -s "$RULES" "$WORK/rules.orig"'
cp "$WORK/rules.orig" "$RULES"; ipt_file_add "$RULES" 443
sed -i 's/--comment reality/--comment "reality"/' "$RULES"   # 旧版 iptables-nft 保存时会给注释加引号
ipt_file_del "$RULES" 443
yes_ '带引号的注释也认得'                 'cmp -s "$RULES" "$WORK/rules.orig"'
printf '*nat\n:PREROUTING ACCEPT [0:0]\nCOMMIT\n' >"$RULES"; cp "$RULES" "$WORK/nat-only"
no_  '没有 filter 表时不写'               'ipt_file_add "$RULES" 443'
yes_ '且文件不变'                         'cmp -s "$RULES" "$WORK/nat-only"'
printf '*filter\n:INPUT DROP [0:0]\nCOMMIT\n' >"$RULES"
ipt_file_add "$RULES" 443
eq_  'filter 表没有 INPUT 规则时插在 COMMIT 之前' "$(sed -n 3p "$RULES")" "$TAG443"

# 决策：什么时候动 iptables、动完怎么提示
# 有状态：-I 插入的规则会出现在之后的 -S 里（插在第一行的策略之后），
# 这样才测得出"放行之后再检查就通过了"
iptables() {
  printf '%s\n' "$*" >>"$WORK/ipt-calls"
  case $1 in
    -S) printf '%s\n' "$MOCK_IPT" ;;
    -I) [[ ${MOCK_IPT_RC:-0} == 0 ]] || return 1
        MOCK_IPT=$(sed "1a -A ${*:2}" <<<"$MOCK_IPT") ;;
    *)  return 1 ;;   # -D：没有可删的规则
  esac
}
ufw() { :; }
save_fn ufw_active; save_fn firewalld_running
ufw_active() { [[ $MOCK_UFW_ON == 1 ]]; }
firewalld_running() { return 1; }
allow_case() { # allow_case <INPUT 链规则>：跑一次 firewall_allow 443，记录调用和输出
  MOCK_IPT=$1; : >"$WORK/ipt-calls"; cp "$WORK/rules.orig" "$RULES"
  ALLOW_OUT=$(firewall_allow 443 2>&1)
}
IPT_SAVE_FILES=("$RULES") MOCK_UFW_ON=0 MOCK_IPT_RC=0
allow_case "$ORACLE_HEAD"$'\n'"$ORACLE_REJECT"
yes_ '拒绝 443 时插到最前面' 'grep -qx -- "-I INPUT -p tcp --dport 443 -m comment --comment reality -j ACCEPT" "$WORK/ipt-calls"'
eq_  '并写进开机规则文件'    "$(cnt "$TAG443" "$RULES")" 1
yes_ '提示已持久化'          '[[ $ALLOW_OUT == *已写入开机规则* ]]'
allow_case "$ORACLE_HEAD"$'\n'"$ORACLE_REJECT"$'\n'"$ACCEPT_443"
yes_ '放行规则排在拒绝之后时也插' 'grep -q -- "^-I INPUT" "$WORK/ipt-calls"'
allow_case '-P INPUT ACCEPT'
no_  '全放行的机器不动 iptables'  'grep -q -- "^-I INPUT" "$WORK/ipt-calls"'
yes_ '也不动规则文件'             'cmp -s "$RULES" "$WORK/rules.orig"'
allow_case "$ORACLE_HEAD"$'\n'"$ACCEPT_443"$'\n'"$ORACLE_REJECT"
no_  '已经放行的端口不重复加'     'grep -q -- "^-I INPUT" "$WORK/ipt-calls"'
MOCK_UFW_ON=1
allow_case "$ORACLE_HEAD"$'\n'"$ORACLE_REJECT"
eq_  'ufw 在管事时完全不碰 iptables' "$(cat "$WORK/ipt-calls")" ''
MOCK_UFW_ON=0 MOCK_IPT_RC=1
allow_case "$ORACLE_HEAD"$'\n'"$ORACLE_REJECT"
yes_ '插入失败时给出手动命令'     '[[ $ALLOW_OUT == *"iptables -I INPUT -p tcp --dport 443 -j ACCEPT"* ]]'
yes_ '且不写规则文件'             'cmp -s "$RULES" "$WORK/rules.orig"'
MOCK_IPT_RC=0 IPT_SAVE_FILES=("$WORK/no-such-file")
allow_case "$ORACLE_HEAD"$'\n'"$ORACLE_REJECT"
yes_ '没有开机规则文件时提醒重启后会失效' '[[ $ALLOW_OUT == *重启后*失效* ]]'

# reality open-port：reality check 报告端口被拦时的一键补救
IPT_SAVE_FILES=("$RULES")
open_port() { # open_port <INPUT 链规则>：跑一次 reality open-port，记下输出与退出码
  MOCK_IPT=$1; : >"$WORK/ipt-calls"; cp "$WORK/rules.orig" "$RULES"
  OPEN_OUT=$(require_installed() { :; }; cmd_open_port 2>&1); OPEN_RC=$?
}
PORT=443
open_port "$ORACLE_HEAD"$'\n'"$ORACLE_REJECT"
eq_  'open-port 修好甲骨文云规则：退出码 0' "$OPEN_RC" 0
yes_ 'open-port 放行后复查通过'             '[[ $OPEN_OUT == *"iptables 已放行 443/tcp"* && $OPEN_OUT != *仍未放行* ]]'
open_port '-P INPUT ACCEPT'
eq_  'open-port 在无需放行时也正常结束'     "$OPEN_RC" 0
yes_ '且如实说明没有拦截'                   '[[ $OPEN_OUT == *未发现本机防火墙拦截* ]]'
MOCK_IPT_RC=1
open_port "$ORACLE_HEAD"$'\n'"$ORACLE_REJECT"
eq_  'open-port 放行失败：退出码 1'         "$OPEN_RC" 1
yes_ '放行失败时如实报告'                   '[[ $OPEN_OUT == *仍未放行* ]]'
MOCK_IPT_RC=0
restore_fns; unset -f iptables ufw allow_case open_port

group '17. set -e 下不会中途退出'
# ((x++)) 在 x 为 0 时退出码为 1。现在能正常工作只是因为 main 以 `dispatch || exit` 调用，
# 屏蔽了 set -e——这层保护一旦改动，reality info 就会在列第一个用户时直接退出
out=$(set -Eeuo pipefail; show_all_nodes >/dev/null 2>&1; echo END)
eq_ 'show_all_nodes 列完全部用户' "$out" 'END'
# 直接调用而不是放进 $()：命令替换里 set -e 会被清掉，看不出问题
out=$(set -Eeuo pipefail; pad_to '' 3; echo '|')
eq_ 'pad_to 处理空字符串' "$out" '   |'

summary
