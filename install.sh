#!/usr/bin/env bash
#
# VLESS + Reality + Vision 一键脚本
#
# 基于 Xray-core 官方安装脚本（XTLS/Xray-install）构建：
# 内核安装完全交给官方脚本，本脚本只负责生成参数、渲染配置与日常管理。
#
# 用法：
#   bash <(curl -fsSL https://raw.githubusercontent.com/doudoudoubao/VLESS-Reality-Vision/main/install.sh)
#   reality                 # 安装后的管理命令
#   reality install --yes   # 全自动安装（非交互）
#   reality help            # 查看全部子命令
#
# 项目地址: https://github.com/doudoudoubao/VLESS-Reality-Vision
# 许可协议: MIT

set -Eeuo pipefail

#=============================== 常量 ==================================#

readonly SCRIPT_VERSION='1.3.0'
readonly SCRIPT_NAME='VLESS + Reality + Vision 一键脚本'
readonly REPO_RAW='https://raw.githubusercontent.com/doudoudoubao/VLESS-Reality-Vision/main/install.sh'
readonly XRAY_INSTALLER='https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh'

readonly XRAY_BIN='/usr/local/bin/xray'
readonly XRAY_CONF_DIR='/usr/local/etc/xray'
readonly XRAY_CONF="${XRAY_CONF_DIR}/config.json"
readonly XRAY_UNIT='/etc/systemd/system/xray.service'
readonly XRAY_LOG='/var/log/xray/error.log'
readonly DATA_DIR='/usr/local/etc/xray/reality'
readonly META_FILE="${DATA_DIR}/meta.conf"
readonly USERS_FILE="${DATA_DIR}/users.tsv"
readonly BACKUP_DIR="${DATA_DIR}/backup"
readonly CMD_PATH='/usr/local/bin/reality'
readonly UPDATE_SERVICE='/etc/systemd/system/reality-update.service'
readonly UPDATE_TIMER='/etc/systemd/system/reality-update.timer'

# 备选偷取目标：逐个实测支持 TLS1.3 + HTTP/2，未套 Cloudflare，
# 且不属于 Xray-core 官方点名警告的 apple / icloud 系域名。
readonly DEST_CANDIDATES=(
  'www.microsoft.com'
  'www.amazon.com'
  'www.nvidia.com'
  'www.samsung.com'
  'www.tesla.com'
  'www.asus.com'
  'dl.google.com'
  'addons.mozilla.org'
  'www.lovelive-anime.jp'
  'shopping.yahoo.co.jp'
)

#=============================== 输出 ==================================#

if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
  C_BLUE=$'\033[0;36m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
  C_CYAN=$'\033[1;36m'; C_GRAY=$'\033[0;90m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_OFF=''
  C_CYAN=''; C_GRAY=''
fi

# 界面本身就是中文，终端不支持 UTF-8 的话中文早就乱码了，
# 因此默认直接用制表符；仅在 REALITY_ASCII=1 时退回纯 ASCII。
if [[ ${REALITY_ASCII:-0} == '1' ]]; then
  GL_H='-'; GL_TL='+'; GL_BL='+'; GL_DOT='-'; GL_ON='*'; GL_OFF='o'
  GL_PASS='+'; GL_FAIL='x'
else
  GL_H='─'; GL_TL='╭'; GL_BL='╰'; GL_DOT='·'; GL_ON='●'; GL_OFF='○'
  GL_PASS='✓'; GL_FAIL='✗'   # 都是单宽字符；⚠ 可能被渲染成双宽 emoji，所以提醒用 !
fi
GL_WARN='!'; GL_SKIP='-'
readonly UI_WIDTH=62

info() { printf '%s[信息]%s %s\n' "$C_BLUE" "$C_OFF" "$*"; }
ok()   { printf '%s[成功]%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
warn() { printf '%s[警告]%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
error(){ printf '%s[错误]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
die()  { error "$*"; exit 1; }

repeat_char() { # repeat_char <字符> <次数>
  local i; for ((i = 0; i < $2; i++)); do printf '%s' "$1"; done
}

hr() { printf '%s' "$C_GRAY"; repeat_char "$GL_H" "$UI_WIDTH"; printf '%s\n' "$C_OFF"; }

# 计算显示宽度：中文/全角按 2 列，其余按 1 列。
# 在 LC_ALL=C 下逐字节解析 UTF-8，不依赖终端 locale 是否正确设置。
disp_width() {
  local LC_ALL=C s=${1-} i=0 w=0 n b1 b2 b3 cp
  n=${#s}
  while ((i < n)); do
    b1=$(( $(printf '%d' "'${s:i:1}") & 255 ))
    if ((b1 < 0x80)); then
      ((w += 1, i += 1))
    elif ((b1 < 0xE0)); then
      ((w += 1, i += 2))
    elif ((b1 < 0xF0)); then
      b2=$(( $(printf '%d' "'${s:i+1:1}") & 255 ))
      b3=$(( $(printf '%d' "'${s:i+2:1}") & 255 ))
      cp=$(( (b1 & 0x0F) << 12 | (b2 & 0x3F) << 6 | (b3 & 0x3F) ))
      # CJK、假名、谚文与全角标点为双宽；框线、箭头等符号仍是单宽
      if (( (cp >= 0x1100 && cp <= 0x115F) \
         || (cp >= 0x2E80 && cp <= 0xA4CF && cp != 0x303F) \
         || (cp >= 0xAC00 && cp <= 0xD7A3) \
         || (cp >= 0xF900 && cp <= 0xFAFF) \
         || (cp >= 0xFE30 && cp <= 0xFE6F) \
         || (cp >= 0xFF00 && cp <= 0xFF60) \
         || (cp >= 0xFFE0 && cp <= 0xFFE6) )); then
        ((w += 2))
      else
        ((w += 1))
      fi
      ((i += 3))
    else
      ((w += 2, i += 4))
    fi
  done
  printf '%d' "$w"
}

pad_to() { # pad_to <字符串> <目标显示宽度>
  local s=${1-} w
  w=$(disp_width "$s")
  printf '%s' "$s"
  while ((w < $2)); do printf ' '; w=$((w + 1)); done   # 别写 ((w++))：w 为 0 时退出码为 1
}

# 标题栏：╭─ 标题 ─────…
rule_top() {
  local title=$1 used
  used=$(disp_width "$title")
  printf '%s%s%s %s%s%s ' "$C_GRAY" "$GL_TL" "$GL_H" "$C_OFF$C_BOLD" "$title" "$C_OFF$C_GRAY"
  repeat_char "$GL_H" "$(( UI_WIDTH - used - 4 > 0 ? UI_WIDTH - used - 4 : 0 ))"
  printf '%s\n' "$C_OFF"
}

rule_bottom() {
  printf '%s%s' "$C_GRAY" "$GL_BL"; repeat_char "$GL_H" "$((UI_WIDTH - 1))"
  printf '%s\n' "$C_OFF"
}

section() { printf '\n  %s%s%s\n' "$C_BOLD" "$1" "$C_OFF"; }

field() { # field <标签> <值> [值的颜色]
  printf '    %s%s%s  %s%s%s\n' \
    "$C_GRAY" "$(pad_to "$1" 12)" "$C_OFF" "${3:-}" "$2" "${3:+$C_OFF}"
}

trap 'error "脚本在第 ${LINENO} 行意外中止（退出码 $?）"' ERR

#=============================== 环境 ==================================#

PKG_MGR=''
OS_PRETTY=''
INTERACTIVE=1
ASSUME_YES=0

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die '请使用 root 用户运行（或先执行 sudo -i）。'
}

require_systemd() {
  [[ -d /run/systemd/system ]] ||
    die '未检测到 systemd。官方 Xray 安装脚本仅支持 systemd 系统（Alpine/OpenRC 暂不支持）。'
}

detect_os() {
  [[ -r /etc/os-release ]] || die '无法读取 /etc/os-release，系统不受支持。'
  local ID='' ID_LIKE='' PRETTY_NAME=''
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_PRETTY=${PRETTY_NAME:-${ID:-unknown}}

  case " ${ID:-} ${ID_LIKE:-} " in
    *debian*|*ubuntu*)        PKG_MGR='apt' ;;
    *fedora*|*rhel*|*centos*) PKG_MGR=$(command -v dnf >/dev/null 2>&1 && echo dnf || echo yum) ;;
    *arch*)                   PKG_MGR='pacman' ;;
    *suse*)                   PKG_MGR='zypper' ;;
    *)
      if   command -v apt-get >/dev/null 2>&1; then PKG_MGR='apt'
      elif command -v dnf     >/dev/null 2>&1; then PKG_MGR='dnf'
      elif command -v yum     >/dev/null 2>&1; then PKG_MGR='yum'
      elif command -v pacman  >/dev/null 2>&1; then PKG_MGR='pacman'
      elif command -v zypper  >/dev/null 2>&1; then PKG_MGR='zypper'
      else die '无法识别包管理器，请手动安装 curl / openssl / qrencode 后重试。'
      fi ;;
  esac
}

pkg_install() {
  (($# > 0)) || return 0
  case $PKG_MGR in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq >/dev/null 2>&1 || true
      apt-get install -y -qq "$@" >/dev/null ;;
    dnf)    dnf install -y -q "$@" >/dev/null ;;
    yum)    yum install -y -q "$@" >/dev/null ;;
    pacman) pacman -Sy --noconfirm --needed "$@" >/dev/null ;;
    zypper) zypper --non-interactive --quiet install "$@" >/dev/null ;;
    *)      return 1 ;;
  esac
}

# curl / openssl 为必需；qrencode 与 ss 缺失时只降级、不报错
install_deps() {
  local need=()
  command -v curl    >/dev/null 2>&1 || need+=('curl')
  command -v openssl >/dev/null 2>&1 || need+=('openssl')

  if ((${#need[@]} > 0)); then
    info "安装依赖：${need[*]}"
    pkg_install "${need[@]}" || die "依赖安装失败，请手动安装：${need[*]}"
  fi
  command -v curl    >/dev/null 2>&1 || die 'curl 不可用。'
  command -v openssl >/dev/null 2>&1 || die 'openssl 不可用。'

  if ! command -v qrencode >/dev/null 2>&1; then
    info '安装二维码工具 qrencode（可选）'
    pkg_install qrencode >/dev/null 2>&1 || warn 'qrencode 安装失败，将跳过二维码显示。'
  fi
  if ! command -v ss >/dev/null 2>&1; then
    pkg_install iproute2 >/dev/null 2>&1 || pkg_install iproute >/dev/null 2>&1 || true
  fi
}

# 本脚本未设置 maxTimeDiff（Xray 默认 0 = 不校验时间差），因此时钟偏差
# 不会导致握手失败；但偏差过大会让 HTTPS 证书校验出错，影响后续更新下载。
check_clock() {
  command -v timedatectl >/dev/null 2>&1 || return 0
  local synced
  # 读不到状态（OpenVZ/LXC 这类时间归宿主机管的容器）时不提示：用户改不了，提示只是噪音
  synced=$(timedatectl show -p NTPSynchronized --value 2>/dev/null) || return 0
  [[ -n $synced && $synced != 'yes' ]] || return 0
  warn '系统时间未与 NTP 同步，正在尝试开启…'
  timedatectl set-ntp true >/dev/null 2>&1 || {
    warn '自动开启失败。不影响节点连接（当前配置未启用时间差校验），'
    warn '但时间偏差过大会导致 HTTPS 证书校验失败，影响后续更新。'
    warn '需要校时可执行：apt install -y systemd-timesyncd 或 apt install -y chrony'
  }
}

has_ipv6() { ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; }
has_ipv4() { ip -4 addr show scope global 2>/dev/null | grep -q 'inet '; }

# 入站监听地址。"::" 在 Linux 默认（bindv6only=0）下同时接受 IPv4 与 IPv6，
# 没有 IPv6 时 Xray 会自动退回只监听 IPv4。
# 唯一的例外是 bindv6only=1：此时 "::" 只收 IPv6，若机器还有 IPv4
# 就保持 0.0.0.0，免得 IPv4 客户端全部断掉。
# 每种情况下都只会比原先写死 0.0.0.0 更好或持平。
listen_addr() {
  has_ipv6 || { printf '0.0.0.0'; return 0; }
  if [[ $(sysctl -n net.ipv6.bindv6only 2>/dev/null) == '1' ]] && has_ipv4; then
    printf '0.0.0.0'
  else
    printf '::'
  fi
}

#=============================== 交互 ==================================#

# 从管道运行（curl | bash）时把标准输入接回终端，保证菜单可交互
attach_tty() {
  [[ -t 0 ]] && return 0
  [[ -r /dev/tty ]] || return 1
  (exec </dev/tty) 2>/dev/null || return 1
  exec </dev/tty
}

is_interactive() { [[ $INTERACTIVE -eq 1 && -t 0 ]]; }

# 提示信息走 stderr，返回值走 stdout，便于 $(ask ...) 取值
ask() { # ask <提示> [默认值]
  local prompt=$1 default=${2:-} reply=''
  if ! is_interactive; then printf '%s' "$default"; return 0; fi
  if [[ -n $default ]]; then
    printf '%s%s%s [%s]: ' "$C_BOLD" "$prompt" "$C_OFF" "$default" >&2
  else
    printf '%s%s%s: ' "$C_BOLD" "$prompt" "$C_OFF" >&2
  fi
  read -r reply || true
  printf '%s' "${reply:-$default}"
}

confirm() { # confirm <提示> [y|n]
  local prompt=$1 default=${2:-n} reply='' hint='[y/N]'
  [[ $default == 'y' ]] && hint='[Y/n]'
  # -y/--yes 等同于「全部同意」（语义同 apt-get -y）；
  # 仅仅是无终端（如管道运行）时则回退到各自的安全默认值
  if ((ASSUME_YES == 1)); then return 0; fi
  if ! is_interactive; then [[ $default == 'y' ]]; return; fi
  printf '%s%s %s%s ' "$C_BOLD" "$prompt" "$hint" "$C_OFF" >&2
  read -r reply || true
  reply=${reply:-$default}
  [[ ${reply,,} == 'y' || ${reply,,} == 'yes' ]]
}

pause() {
  is_interactive || return 0
  printf '\n%s按回车键返回菜单…%s' "$C_BLUE" "$C_OFF" >&2
  read -r _ || true
}

#=============================== 工具 ==================================#

urlencode() {
  local LC_ALL=C s=${1-} out='' i c
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in
      [a-zA-Z0-9.~_-]) out+=$c ;;
      *) out+=$(printf '%%%02X' "$(( $(printf '%d' "'$c") & 255 ))") ;;
    esac
  done
  printf '%s' "$out"
}

valid_port()   { [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
valid_uuid()   { [[ ${1,,} =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; }
valid_host()   { [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && $1 == *.* && ${#1} -le 253 ]]; }
valid_key()    { [[ $1 =~ ^[A-Za-z0-9_-]{43}$ ]]; }

valid_ipv4() {
  [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local o
  for o in "${BASH_REMATCH[@]:1}"; do ((10#$o <= 255)) || return 1; done
}

# 不做完整的 RFC 4291 校验，目的是只放行十六进制、冒号和点——
# 这样任何 shell 元字符都进不来，而所有合法 IPv6 写法都能通过
valid_ipv6() { [[ $1 =~ ^[0-9A-Fa-f:.]+$ && $1 == *:*:* && ${#1} -le 45 ]]; }

# 分享链接用的地址：只接受 IPv4、IPv6 或域名三种格式。
# 这里放行的值会写进 meta.conf 并在之后被 source，所以必须严格。
valid_addr() { valid_ipv4 "$1" || valid_ipv6 "$1" || valid_host "$1"; }

# 握手目标：host:port 或 [ipv6]:port
valid_dest() {
  local h p
  if [[ $1 =~ ^\[([0-9A-Fa-f:.]+)\]:([0-9]+)$ ]]; then
    h=${BASH_REMATCH[1]}; p=${BASH_REMATCH[2]}
    valid_ipv6 "$h" || return 1
  elif [[ $1 =~ ^([^:]+):([0-9]+)$ ]]; then
    h=${BASH_REMATCH[1]}; p=${BASH_REMATCH[2]}
    valid_ipv4 "$h" || valid_host "$h" || return 1
  else
    return 1
  fi
  valid_port "$p"
}

# 用户可能直接粘贴带方括号的 IPv6，统一去掉；输出链接时 link_host 会再加回来
strip_brackets() { local s=$1; s=${s#\[}; s=${s%\]}; printf '%s' "$s"; }

# 节点名允许中文，但禁止空白、引号与反斜杠，避免破坏 JSON 与分享链接
valid_label()  { [[ -n $1 && ${#1} -le 32 && $1 != *[$'\t\n\r "\\']* ]]; }

port_in_use() {
  command -v ss >/dev/null 2>&1 || return 1
  # 不用 -H：老版本 ss 不认识它，会直接报错，结果永远是"未占用"；表头第 4 列是 "Local"，匹配不上
  ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$1\$"
}

run_timeout() { # run_timeout <秒> <命令…>
  local secs=$1; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  else
    "$@"
  fi
}

#=========================== 参数生成 / 检测 ===========================#

gen_uuid() {
  if [[ -x $XRAY_BIN ]]; then
    local u; u=$("$XRAY_BIN" uuid 2>/dev/null | tr -d '[:space:]') || u=''
    [[ -n $u ]] && { printf '%s' "$u"; return 0; }
  fi
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    tr -d '[:space:]' </proc/sys/kernel/random/uuid && return 0
  fi
  return 1
}

gen_shortid() { openssl rand -hex 8; }

# 兼容新旧两种 `xray x25519` 输出：
#   Private key: xxx / Public key: yyy   （旧版）
#   PrivateKey: xxx  / Password: yyy     （新版）
gen_keypair() {
  local out k1 k2
  out=$("$XRAY_BIN" x25519 2>/dev/null) || return 1
  k1=$(printf '%s\n' "$out" | grep -m1 ':'  | sed 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]')
  k2=$(printf '%s\n' "$out" | grep ':' | sed -n '2p' | sed 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]')
  valid_key "$k1" && valid_key "$k2" || return 1
  PRIVATE_KEY=$k1
  PUBLIC_KEY=$k2
}

openssl_has_tls13() { openssl s_client -help 2>&1 | grep -q -- '-tls1_3'; }

# 检查偷取目标是否满足 Reality 要求：TLS1.3 + HTTP/2。
# SNI 默认同 host；--dest 与 SNI 不同时要传入 SNI，因为 Xray 转发的握手里带的是 SNI。
check_dest() { # check_dest <host> [port] [SNI]
  local host=$1 port=${2:-443} sni=${3:-$1} target out=''
  openssl_has_tls13 || return 4
  target="${host}:${port}"
  valid_ipv6 "$host" && target="[${host}]:${port}"   # 不加方括号时 IPv6 与端口无法区分
  out=$(run_timeout 10 openssl s_client -connect "$target" -servername "$sni" \
        -tls1_3 -alpn h2 </dev/null 2>/dev/null) || return 1
  grep -q 'ALPN protocol: h2' <<<"$out" || return 2
  grep -q 'TLSv1.3' <<<"$out" || return 3
  return 0
}

# 以下两条为 Xray-core 官方在配置自检时给出的风险提示，提前告知用户
warn_dest_risk() {
  case ${1,,} in
    *apple*|*icloud*)
      warn '官方提示：使用 apple / icloud 系域名作为目标，可能导致服务器 IP 被 GFW 封锁，建议更换。' ;;
  esac
  return 0
}

warn_port_risk() {
  if [[ $1 != '443' ]]; then
    warn '官方提示：Reality 监听非 443 端口更容易被识别，如无特殊需求建议使用 443。'
  fi
  return 0
}

describe_dest_result() {
  case $1 in
    0) ok   '目标可用：支持 TLS1.3 与 HTTP/2' ;;
    1) warn '无法完成 TLS1.3 握手（网络不通、被墙或目标不支持）' ;;
    2) warn '目标不支持 HTTP/2（h2），Reality 需要 h2' ;;
    3) warn '目标不支持 TLS1.3' ;;
    4) warn '当前 openssl 版本过旧，无法检测，将跳过校验' ;;
    *) warn "检测异常（代码 $1）" ;;
  esac
}

# 通过外部服务探测本机公网 IP。返回值必须严格校验：它会写进 meta.conf 和分享链接，
# 不能因为某个服务返回了奇怪的内容就原样收下（此前 IPv6 只检查了"含冒号"）
public_ip() { # public_ip <4|6>
  local url ip
  local -a urls=('https://api.ipify.org' 'https://ipv4.icanhazip.com' 'https://ifconfig.me/ip')
  [[ $1 == 6 ]] && urls=('https://api6.ipify.org' 'https://ipv6.icanhazip.com')
  for url in "${urls[@]}"; do
    ip=$(curl -fsS"$1" --max-time "${IP_PROBE_TIMEOUT:-6}" "$url" 2>/dev/null | tr -d '[:space:]') || ip=''
    if { [[ $1 == 4 ]] && valid_ipv4 "$ip"; } || { [[ $1 == 6 ]] && valid_ipv6 "$ip"; }; then
      printf '%s' "$ip"
      return 0
    fi
  done
  return 1
}

get_public_ip() { public_ip 4 || public_ip 6; }

#============================= 元数据存取 =============================#

PORT=''; DEST=''; SNI=''; PRIVATE_KEY=''; PUBLIC_KEY=''
SHORT_IDS=''; NODE_HOST=''; BLOCK_BT='1'; BLOCK_ADS='0'
HOST_CACHE=''

# meta.conf 会被 source，所以每个值都用 %q 转义：无论值里有什么字符，
# 读回来都原样还原，不可能逃出引号被当成命令执行。
# 先写同目录临时文件再 mv，写到一半中断也不会留下半截文件。
save_meta() {
  install -d -m 700 "$DATA_DIR"
  local tmp k
  tmp=$(mktemp "${DATA_DIR}/.meta.XXXXXX") || return 1   # mktemp 默认即 600
  {
    printf '# 由 %s 生成，请勿手工编辑\n' "$SCRIPT_NAME"
    for k in PORT DEST SNI PRIVATE_KEY PUBLIC_KEY SHORT_IDS NODE_HOST BLOCK_BT BLOCK_ADS; do
      printf '%s=%q\n' "$k" "${!k}"
    done
  } >"$tmp"
  mv -f "$tmp" "$META_FILE"
}

load_meta() {
  [[ -r $META_FILE ]] || return 1
  # 文件语法都不对时拒绝加载：否则只会读进一半字段，
  # 下次保存时再把缺失的值永久写回去——静默丢数据比报错更糟
  bash -n "$META_FILE" 2>/dev/null || return 1
  # shellcheck disable=SC1090
  . "$META_FILE"
  [[ -n $PORT && -n $SNI && -n $PRIVATE_KEY && -n $PUBLIC_KEY ]]
}

is_installed() { [[ -x $XRAY_BIN && -r $META_FILE ]]; }

require_installed() {
  is_installed || die "尚未安装，请先执行：${C_BOLD}reality install${C_OFF}"
  load_meta || die "配置数据 ${META_FILE} 已损坏，建议卸载后重新安装。"
  [[ -r $USERS_FILE ]] || die "用户列表 ${USERS_FILE} 丢失，建议卸载后重新安装。"
}

users_count() {
  local n=''
  if [[ -r $USERS_FILE ]]; then
    n=$(grep -c '[^[:space:]]' "$USERS_FILE" 2>/dev/null || true)
  fi
  printf '%s' "${n:-0}"
}

user_add() { # user_add <uuid> <label>
  install -d -m 700 "$DATA_DIR"
  touch "$USERS_FILE"; chmod 600 "$USERS_FILE"
  printf '%s\t%s\n' "$1" "$2" >>"$USERS_FILE"
}

user_exists_label() { [[ -r $USERS_FILE ]] && awk -F'\t' -v l="$1" '$2==l{f=1} END{exit !f}' "$USERS_FILE"; }
user_exists_uuid()  { [[ -r $USERS_FILE ]] && awk -F'\t' -v u="$1" '$1==u{f=1} END{exit !f}' "$USERS_FILE"; }

#============================= 配置渲染 ===============================#

render_clients() {
  local uuid label first=1
  while IFS=$'\t' read -r uuid label || [[ -n ${uuid:-} ]]; do
    [[ -n ${uuid:-} ]] || continue
    ((first)) || printf ',\n'
    first=0
    printf '          { "id": "%s", "flow": "xtls-rprx-vision", "email": "%s" }' "$uuid" "${label:-user}"
  done <"$USERS_FILE"
  printf '\n'
}

render_shortids() {
  local id first=1
  local -a sids=()
  IFS=',' read -r -a sids <<<"$SHORT_IDS"
  for id in "${sids[@]}"; do
    [[ -n $id ]] || continue
    ((first)) || printf ', '
    first=0
    printf '"%s"' "$id"
  done
}

render_rules() {
  printf '        { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" }'
  [[ $BLOCK_BT == '1' ]] &&
    printf ',\n        { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" }'
  [[ $BLOCK_ADS == '1' ]] &&
    printf ',\n        { "type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "block" }'
  printf '\n'
}

# DNS 把 localhost（系统解析器）排在最前：机器能上网就说明它必然可用。
# 公共 DNS 只作兜底——部分 VPS 到 1.1.1.1 / 8.8.8.8 不通（国内机，或商家
# 封了出站 53 端口），若把它们排在前面，配合 IPIfNonMatch 会导致每个域名
# 连接都卡在解析上，表现为"已连接但打不开网页"。
render_config() {
  local strategy='UseIP' listen
  has_ipv6 || strategy='UseIPv4'
  listen=$(listen_addr)

  cat <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "none",
    "error": "${XRAY_LOG}"
  },
  "dns": {
    "servers": ["localhost", "1.1.1.1", "8.8.8.8"],
    "queryStrategy": "${strategy}"
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "${listen}",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
$(render_clients)
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST}",
          "xver": 0,
          "serverNames": ["${SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [$(render_shortids)]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": { "domainStrategy": "${strategy}" }
    },
    {
      "tag": "block",
      "protocol": "blackhole",
      "settings": { "response": { "type": "http" } }
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
$(render_rules)
    ]
  }
}
EOF
}

# 注意：新版 Xray 会按文件扩展名推断配置格式，临时文件必须显式指定 -format
xray_test_config() { # xray_test_config <file>
  "$XRAY_BIN" run -test -format json -config "$1" 2>&1 ||
    "$XRAY_BIN" run -test -config "$1" 2>&1 ||
    "$XRAY_BIN" -test -config "$1" 2>&1
}

service_user() {
  local u=''
  u=$(systemctl show -p User --value xray 2>/dev/null || true)
  u=${u#User=}
  if [[ -z $u && -r $XRAY_UNIT ]]; then
    u=$(sed -n 's/^[[:space:]]*User[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' "$XRAY_UNIT" | tail -n1)
  fi
  id "${u:-root}" >/dev/null 2>&1 || u='root'
  printf '%s' "${u:-root}"
}

# 配置中的 error 日志指向 XRAY_LOG，其目录缺失时 Xray 连自检都无法通过
ensure_log_dir() {
  local u g dir=${XRAY_LOG%/*}
  install -d -m 755 "$dir" 2>/dev/null || return 0
  u=$(service_user)
  g=$(id -gn "$u" 2>/dev/null || printf '%s' "$u")
  chown "$u:$g" "$dir" 2>/dev/null || true
  return 0
}

# 配置里含 Reality 私钥，收紧到仅 Xray 运行用户可读
harden_conf() {
  local u g
  u=$(service_user)
  g=$(id -gn "$u" 2>/dev/null || printf '%s' "$u")
  chown "$u:$g" "$XRAY_CONF" 2>/dev/null || true
  chmod 600 "$XRAY_CONF" 2>/dev/null || true

  # 万一权限收紧后 Xray 反而读不到，回退到 644，保证服务可用
  if [[ $u != 'root' ]] && command -v runuser >/dev/null 2>&1; then
    runuser -u "$u" -- test -r "$XRAY_CONF" 2>/dev/null || {
      warn "用户 ${u} 无法读取配置，已回退为 644 权限。"
      chmod 644 "$XRAY_CONF" 2>/dev/null || true
    }
  fi
}

# 渲染 → 语法自检 → 备份 → 落盘 → 重启 → 失败自动回滚
apply_config() {
  local tmp out
  # 扩展名保留 .json，避免 Xray 因无法识别格式而拒绝加载
  tmp=$(mktemp "${TMPDIR:-/tmp}/reality-config.XXXXXX.json") || return 1
  render_config >"$tmp"
  ensure_log_dir

  if ! out=$(xray_test_config "$tmp"); then
    error '生成的配置未通过 Xray 自检，已放弃写入：'
    printf '%s\n' "$out" | tail -n 15 >&2
    rm -f "$tmp"
    return 1
  fi

  install -d -m 700 "$BACKUP_DIR"
  if [[ -f $XRAY_CONF ]]; then
    cp -a "$XRAY_CONF" "${BACKUP_DIR}/config.json.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    # 文件名由脚本自己生成，形如 config.json.20240101000000，可安全用 ls 排序
    # shellcheck disable=SC2012
    ls -1t "${BACKUP_DIR}"/config.json.* 2>/dev/null | tail -n +11 | xargs -r rm -f
  fi

  install -d -m 755 "$XRAY_CONF_DIR"
  install -m 600 "$tmp" "$XRAY_CONF"
  rm -f "$tmp"
  harden_conf

  systemctl enable xray >/dev/null 2>&1 || true
  if ! systemctl restart xray 2>/dev/null; then
    error 'Xray 服务重启失败，正在回滚…'
    rollback_config
    return 1
  fi
  sleep 1
  if ! systemctl is-active --quiet xray; then
    error 'Xray 启动后立即退出，最近日志：'
    journalctl -u xray -n 15 --no-pager 2>/dev/null | sed 's/^/    /' >&2 || true
    rollback_config
    return 1
  fi
  return 0
}

rollback_config() {
  local last
  # shellcheck disable=SC2012
  last=$(ls -1t "${BACKUP_DIR}"/config.json.* 2>/dev/null | head -n1 || true)
  if [[ -n $last ]]; then
    install -m 600 "$last" "$XRAY_CONF"
    harden_conf
    systemctl restart xray >/dev/null 2>&1 || true
    warn "已回滚到上一份配置：${last}"
  else
    warn '没有可用备份，未执行回滚。'
  fi
}

#============================== 防火墙 ================================#

# ufw 的输出会随系统语言翻译，必须在 C locale 下解析
ufw_active()        { command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status 2>/dev/null | grep -q 'Status: active'; }
firewalld_running() { command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; }

# <端口> 是否在端口列表里：ufw 与 iptables 都允许 80,443 和 400:500 这类写法
port_listed() { # port_listed <端口> <列表>
  local p
  local -a parts=()
  IFS=',' read -r -a parts <<<"$2"
  for p in "${parts[@]}"; do
    if [[ $p =~ ^([0-9]+):([0-9]+)$ ]]; then
      ((10#$1 >= 10#${BASH_REMATCH[1]} && 10#$1 <= 10#${BASH_REMATCH[2]})) && return 0
    elif [[ $p =~ ^[0-9]+$ ]]; then
      ((10#$p == 10#$1)) && return 0
    fi
  done
  return 1
}

# 从标准输入读 `ufw status verbose`，看有没有放行 <端口>/tcp 的规则
ufw_allows() { # ufw_allows <端口>
  local to action _
  while read -r to action _; do
    [[ $action == 'ALLOW' || $action == 'LIMIT' ]] || continue   # (v6) 行的第二列不是动作，顺带跳过
    [[ $to != */udp ]] || continue
    port_listed "$1" "${to%/tcp}" && return 0
  done
  return 1
}

# 从标准输入读 `iptables -S INPUT`，判断 <端口>/tcp 会不会被放行。只认最常见的写法：
# 带端口的 ACCEPT，以及不带条件（或只限定 tcp）的 REJECT / DROP——
# 甲骨文云的系统镜像自带的就是后者，只放行 22 端口。输出：
#   accept  放行规则在拒绝规则之前
#   late    放行规则排在拒绝规则之后，永远轮不到它（用 iptables -A 追加的典型错误）
#   deny    有拒绝规则，没有放行规则
#   none    没有拒绝规则
iptables_verdict() { # iptables_verdict <端口>
  local line verdict='' late=0 policy_deny=0
  local accept_re=' -j ACCEPT( |$)' port_re=' --dports? ([0-9,:]+)'
  local deny_re='^-A INPUT( -p tcp( -m tcp)?)? -j (REJECT|DROP)( --reject-with [^ ]+)?$'
  while read -r line; do
    case $line in
      '-P INPUT DROP') policy_deny=1 ;;
      '-A INPUT '*)
        if [[ $line =~ $accept_re && ( $line == *' -p tcp '* || $line != *' -p '* ) ]] &&
           [[ $line =~ $port_re ]] && port_listed "$1" "${BASH_REMATCH[1]}"; then
          if [[ $verdict == 'deny' ]]; then late=1; else verdict=${verdict:-accept}; fi
        elif [[ $line =~ $deny_re ]]; then
          verdict=${verdict:-deny}
        fi ;;
    esac
  done
  if [[ $verdict == 'accept' ]]; then
    echo accept
  elif [[ $verdict == 'deny' ]] || ((policy_deny)); then
    if ((late)); then echo late; else echo deny; fi
  else
    echo none
  fi
}

# 本脚本加的 iptables 规则都带这个注释：撤销时只删自己加的，用户原有的同端口规则不动
readonly IPT_TAG='reality'
# 开机时整份载入的规则文件（iptables-save 格式）：Debian/Ubuntu 的 iptables-persistent、
# RHEL 系的 iptables-services。不设为 readonly，测试要把它指到临时文件
IPT_SAVE_FILES=(/etc/iptables/rules.v4 /etc/sysconfig/iptables)

ipt_file_has() { # ipt_file_has <文件> <端口>：旧版 iptables-nft 保存时会给注释加引号
  grep -Eq -- "--dport $2 .*--comment \"?${IPT_TAG}\"? " "$1" 2>/dev/null
}

# 往规则文件里加一行，插在 *filter 表第一条 -A INPUT 之前（表里没有 INPUT 规则就插在
# 它的 COMMIT 之前），其余内容原样保留。不用 netfilter-persistent save：它会把 Docker、
# fail2ban 运行时加的规则一并存进去，重启后与它们自己再加的规则重复甚至冲突
ipt_file_add() { # ipt_file_add <文件> <端口>
  local f=$1 tmp rc=0
  ipt_file_has "$f" "$2" && return 0
  tmp=$(mktemp) || return 1
  if awk -v rule="-A INPUT -p tcp -m tcp --dport $2 -m comment --comment ${IPT_TAG} -j ACCEPT" '
       /^\*/ { table = $0 }
       table == "*filter" && !done && (/^-A INPUT / || /^COMMIT/) { print rule; done = 1 }
       { print }
       END { exit !done }' "$f" >"$tmp"; then
    cat "$tmp" >"$f" || rc=1   # 用 cat 写回：保留原文件的权限、属主与 SELinux 标签
  else
    rc=1                       # 没有 *filter 表，不是我们认得的格式，不动它
  fi
  rm -f "$tmp"
  return "$rc"
}

ipt_file_del() { # ipt_file_del <文件> <端口>：只删本脚本加的那一行
  local f=$1 tmp rc=0
  ipt_file_has "$f" "$2" || return 0
  tmp=$(mktemp) || return 1
  if awk -v p="--dport $2 " -v tag="--comment \"?${IPT_TAG}\"? " \
       '!(index($0, p) && $0 ~ tag)' "$f" >"$tmp"; then
    cat "$tmp" >"$f" || rc=1
  else
    rc=1
  fi
  rm -f "$tmp"
  return "$rc"
}

# 只在 iptables 会拒绝该端口时才动（典型是甲骨文云的系统镜像）：
# INPUT 本来就全放行的机器一条规则都不加
iptables_allow() { # iptables_allow <端口>
  local port=$1 rules f saved=0
  command -v iptables >/dev/null 2>&1 || return 0
  rules=$(iptables -S INPUT 2>/dev/null) || return 0
  case $(iptables_verdict "$port" <<<"$rules") in
    deny|late) ;;
    *) return 0 ;;
  esac
  # 必须 -I 插到最前面：-A 追加会排在拒绝规则后面，永远轮不到
  if ! iptables -I INPUT -p tcp --dport "$port" -m comment --comment "$IPT_TAG" -j ACCEPT 2>/dev/null; then
    warn "iptables 会拒绝 ${port}/tcp，自动放行失败。请手动执行：iptables -I INPUT -p tcp --dport ${port} -j ACCEPT"
    return 0
  fi
  for f in "${IPT_SAVE_FILES[@]}"; do
    [[ -f $f ]] || continue
    if ipt_file_add "$f" "$port"; then saved=1; fi
  done
  if ((saved)); then
    info "iptables 已放行 ${port}/tcp（已写入开机规则，重启后仍有效）"
  else
    info "iptables 已放行 ${port}/tcp"
    warn '没找到 iptables 的开机规则文件，重启后这条规则可能失效；届时执行 reality open-port 即可重新放行。'
  fi
}

iptables_revoke() { # iptables_revoke <端口>：只删带本脚本注释的规则
  local port=$1 f
  command -v iptables >/dev/null 2>&1 || return 0
  while iptables -D INPUT -p tcp --dport "$port" -m comment --comment "$IPT_TAG" -j ACCEPT 2>/dev/null; do :; done
  for f in "${IPT_SAVE_FILES[@]}"; do
    if [[ -f $f ]]; then ipt_file_del "$f" "$port" || true; fi
  done
  return 0
}

firewall_allow() {
  local port=$1 managed=0
  if ufw_active; then
    managed=1
    ufw allow "${port}/tcp" >/dev/null 2>&1 && info "ufw 已放行 ${port}/tcp"
  fi
  if firewalld_running; then
    managed=1
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 &&
      firewall-cmd --reload >/dev/null 2>&1 &&
      info "firewalld 已放行 ${port}/tcp"
  fi
  # ufw 与 firewalld 自己管理底层规则，它们在管事时不能再绕过它们直接动 iptables
  if ((managed == 0)); then iptables_allow "$port"; fi
  return 0
}

firewall_revoke() {
  local port=$1
  if ufw_active; then
    ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
  fi
  if firewalld_running; then
    firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  iptables_revoke "$port"   # 只删本脚本加过的，没加过就什么都不做
  return 0
}

# 按当前端口重新放行本机防火墙，逻辑与安装时完全相同（重复执行无副作用）。
# 用于事后补救：装完之后才启用的防火墙、旧版本装的甲骨文云机器、reality check 报告被拦
cmd_open_port() {
  require_installed
  firewall_allow "$PORT"
  ck_firewall
  if [[ $CK_STATUS == 'fail' ]]; then
    error "仍未放行：${CK_DETAIL}"
    return 1
  fi
  ok "本机防火墙：${CK_DETAIL}"
  cloud_firewall_hint
}

cloud_firewall_hint() {
  printf '%s提示：使用阿里云 / 腾讯云 / AWS 等云主机时，请在控制台安全组放行 TCP %s 端口。%s\n' \
    "$C_YELLOW" "$PORT" "$C_OFF"
}

#============================ 分享链接输出 ============================#

link_host() {
  if [[ -z $HOST_CACHE ]]; then
    HOST_CACHE=${NODE_HOST:-}
    [[ -n $HOST_CACHE ]] || HOST_CACHE=$(get_public_ip) || HOST_CACHE='YOUR_SERVER_IP'
    [[ $HOST_CACHE == *:* && $HOST_CACHE != \[* ]] && HOST_CACHE="[${HOST_CACHE}]"
  fi
  printf '%s' "$HOST_CACHE"
}

first_shortid() { printf '%s' "${SHORT_IDS%%,*}"; }

share_link() { # share_link <uuid> <label>
  printf 'vless://%s@%s:%s?encryption=none&security=reality&type=tcp&headerType=none&flow=xtls-rprx-vision&fp=chrome&sni=%s&pbk=%s&sid=%s#%s' \
    "$1" "$(link_host)" "$PORT" "$(urlencode "$SNI")" "$PUBLIC_KEY" "$(first_shortid)" "$(urlencode "$2")"
}

print_qr() {
  if command -v qrencode >/dev/null 2>&1; then
    printf '\n'
    qrencode -t ANSIUTF8 -m 1 "$1" 2>/dev/null || warn '二维码生成失败。'
  else
    warn '未安装 qrencode，已跳过二维码（可执行 apt install qrencode 后重试）。'
  fi
}

print_singbox() { # print_singbox <uuid> <label>
  cat <<EOF
{
  "type": "vless",
  "tag": "$2",
  "server": "$(link_host)",
  "server_port": ${PORT},
  "uuid": "$1",
  "flow": "xtls-rprx-vision",
  "packet_encoding": "xudp",
  "tls": {
    "enabled": true,
    "server_name": "${SNI}",
    "utls": { "enabled": true, "fingerprint": "chrome" },
    "reality": { "enabled": true, "public_key": "${PUBLIC_KEY}", "short_id": "$(first_shortid)" }
  }
}
EOF
}

print_clash() { # print_clash <uuid> <label>
  cat <<EOF
- name: "$2"
  type: vless
  server: $(link_host)
  port: ${PORT}
  uuid: $1
  network: tcp
  udp: true
  tls: true
  flow: xtls-rprx-vision
  servername: ${SNI}
  client-fingerprint: chrome
  reality-opts:
    public-key: ${PUBLIC_KEY}
    short-id: "$(first_shortid)"
EOF
}

# 链接单独占一行且顶格输出，方便整行选中复制
print_link() { # print_link <链接>
  printf '\n  %s分享链接%s %s%s 整行复制即可导入客户端%s\n\n' \
    "$C_BOLD" "$C_OFF" "$C_GRAY" "$GL_DOT" "$C_OFF"
  printf '%s%s%s\n' "$C_CYAN" "$1" "$C_OFF"
}

show_node() { # show_node <uuid> <label> [--qr]
  local link; link=$(share_link "$1" "$2")
  printf '\n'
  rule_top "节点 ${2}"
  section '服务器'
  field '地址'     "$(link_host)"    "$C_BOLD"
  field '端口'     "$PORT"           "$C_BOLD"
  field '用户 ID'  "$1"              "$C_BOLD"
  section '伪装参数'
  field 'SNI 域名' "$SNI"
  field '公钥'     "$PUBLIC_KEY"
  field 'Short ID' "$(first_shortid)"
  field '指纹'     'chrome'
  section '协议'
  field '传输'     "tcp ${GL_DOT} reality"
  field '流控'     'xtls-rprx-vision'
  print_link "$link"
  [[ ${3:-} == '--qr' ]] && print_qr "$link"
  rule_bottom
  printf '\n'
}

# 多用户时共用参数只列一次，每个用户只显示各自的 UUID 与链接
show_all_nodes() {
  local uuid label idx=0
  printf '\n'
  rule_top '共用参数'
  field '地址'     "$(link_host)"    "$C_BOLD"
  field '端口'     "$PORT"           "$C_BOLD"
  field 'SNI 域名' "$SNI"
  field '公钥'     "$PUBLIC_KEY"
  field 'Short ID' "$(first_shortid)"
  field '指纹'     "chrome ${GL_DOT} tcp ${GL_DOT} reality ${GL_DOT} xtls-rprx-vision"
  section '用户'
  while IFS=$'\t' read -r uuid label || [[ -n ${uuid:-} ]]; do
    [[ -n ${uuid:-} ]] || continue
    idx=$((idx + 1))
    printf '\n    %s[%d]%s %s%s%s\n' "$C_GREEN" "$idx" "$C_OFF" "$C_BOLD" "${label:-user}" "$C_OFF"
    printf '        %s%s%s\n' "$C_GRAY" "$uuid" "$C_OFF"
    printf '%s%s%s\n' "$C_CYAN" "$(share_link "$uuid" "${label:-user}")" "$C_OFF"
  done <"$USERS_FILE"
  printf '\n'
  printf '  %s链接可整行复制导入客户端；%sreality qr%s 可输出二维码%s\n' \
    "$C_GRAY" "$C_OFF$C_GRAY$C_BOLD" "$C_OFF$C_GRAY" "$C_OFF"
  rule_bottom
  printf '\n'
}

#============================== 安装流程 ==============================#

install_xray_core() {
  local tmp rc=0
  tmp=$(mktemp -d)
  info '下载 Xray-core 官方安装脚本…'
  if ! curl -fsSL --retry 3 --retry-delay 2 --max-time 120 -o "${tmp}/install-release.sh" "$XRAY_INSTALLER"; then
    rm -rf "$tmp"
    die "无法下载官方安装脚本：${XRAY_INSTALLER}"
  fi
  head -n1 "${tmp}/install-release.sh" | grep -q '^#!' ||
    { rm -rf "$tmp"; die '下载到的安装脚本内容异常，已中止。'; }

  info '安装 / 更新 Xray-core（官方脚本，服务默认以 nobody 身份运行）…'
  local args=('install')
  [[ -n ${XRAY_VERSION:-} ]] && args+=('--version' "$XRAY_VERSION")
  [[ -n ${PROXY:-} ]] && args+=('-p' "$PROXY")
  bash "${tmp}/install-release.sh" "${args[@]}" || rc=$?
  rm -rf "$tmp"
  ((rc == 0)) || die "Xray-core 安装失败（退出码 ${rc}）。"
  [[ -x $XRAY_BIN ]] || die "未找到 ${XRAY_BIN}，安装未成功。"
}

install_self() {
  local src=${BASH_SOURCE[0]:-}
  if [[ -n $src && -f $src && -r $src ]] && install -m 755 "$src" "$CMD_PATH" 2>/dev/null; then
    return 0
  fi
  if curl -fsSL --max-time 30 -o "$CMD_PATH" "$REPO_RAW" 2>/dev/null; then
    chmod 755 "$CMD_PATH"
    return 0
  fi
  warn "管理命令安装失败，可稍后手动下载：curl -fsSL -o ${CMD_PATH} ${REPO_RAW} && chmod +x ${CMD_PATH}"
  return 0
}

# 结果写入调用方的 DEST_HOST 变量
choose_dest() {
  local pick host rc
  if ! is_interactive; then
    DEST_HOST=${OPT_SNI:-${DEST_CANDIDATES[0]}}
    return 0
  fi
  printf '\n%s请选择 Reality 偷取目标（SNI）：%s\n' "$C_BOLD" "$C_OFF"
  local i
  for i in "${!DEST_CANDIDATES[@]}"; do
    printf '  %2d) %s\n' "$((i + 1))" "${DEST_CANDIDATES[i]}"
  done
  printf '  %2d) 自定义域名\n' "$((${#DEST_CANDIDATES[@]} + 1))"
  printf '%s提示：选与服务器地理位置相近、支持 TLS1.3+H2 且未套 CDN 的站点效果最好。%s\n' \
    "$C_BLUE" "$C_OFF"

  while :; do
    pick=$(ask '请输入序号' '1')
    if [[ $pick =~ ^[0-9]+$ ]] && ((10#$pick >= 1 && 10#$pick <= ${#DEST_CANDIDATES[@]})); then
      host=${DEST_CANDIDATES[$((10#$pick - 1))]}
    elif [[ $pick =~ ^[0-9]+$ ]] && ((10#$pick == ${#DEST_CANDIDATES[@]} + 1)); then
      host=$(ask '请输入目标域名（不含端口）' '')
      valid_host "$host" || { error '域名格式不正确。'; continue; }
      warn_dest_risk "$host"
    else
      error '序号无效，请重新输入。'; continue
    fi

    info "正在检测 ${host} …"
    rc=0; check_dest "$host" 443 || rc=$?
    describe_dest_result "$rc"
    if ((rc == 0 || rc == 4)) || confirm '该目标检测未通过，仍然使用吗？' 'n'; then
      DEST_HOST=$host
      return 0
    fi
  done
}

# install 的命令行参数在做任何耗时操作之前统一校验：写错了应当立刻报错，
# 而不是等装完 Xray（约半分钟）才发现，还留下一个没配置的内核
validate_install_opts() {
  [[ -z $OPT_PORT ]] || valid_port "$OPT_PORT" || die "端口非法：${OPT_PORT}"
  [[ -z $OPT_SNI  ]] || valid_host "$OPT_SNI"  || die "SNI 格式不正确：${OPT_SNI}"
  [[ -z $OPT_DEST ]] || valid_dest "$OPT_DEST" ||
    die "握手目标格式不正确，应为 域名:端口 或 [IPv6]:端口：${OPT_DEST}"
  [[ -z $OPT_UUID ]] || valid_uuid "$OPT_UUID" || die "UUID 格式不正确：${OPT_UUID}"
  [[ -z $OPT_NAME ]] || valid_label "$OPT_NAME" ||
    die "节点名不能含空格、引号或反斜杠，且不超过 32 字符：${OPT_NAME}"
  if [[ -n $OPT_HOST ]]; then
    valid_addr "$(strip_brackets "$OPT_HOST")" ||
      die "地址格式不正确，只接受 IPv4、IPv6 或域名：${OPT_HOST}"
  fi
  return 0
}

cmd_install() {
  require_systemd
  detect_os

  if is_installed && ((OPT_FORCE == 0)); then
    warn '检测到已安装。重装请先执行 reality uninstall，或使用 reality install --force 强制重装。'
    return 1
  fi

  validate_install_opts

  printf '\n%s%s v%s%s\n' "$C_BOLD" "$SCRIPT_NAME" "$SCRIPT_VERSION" "$C_OFF"
  printf '系统：%s\n\n' "$OS_PRETTY"

  install_deps    # 很快；下面检测端口占用要用 ss，检测伪装目标要用 openssl
  check_clock

  # 交互提问全部放在下载内核之前：答完就可以离开，不必守着等下载

  # ---- 端口 ----
  PORT=${OPT_PORT:-}
  if [[ -z $PORT ]]; then
    if is_interactive; then
      while :; do
        PORT=$(ask '监听端口' '443')
        valid_port "$PORT" || { error '端口需在 1-65535 之间。'; continue; }
        if port_in_use "$PORT"; then
          confirm "端口 ${PORT} 已被占用，仍要使用吗？" 'n' || continue
        fi
        break
      done
    else
      PORT='443'
    fi
  fi
  valid_port "$PORT" || die "端口非法：${PORT}"
  PORT=$((10#$PORT))   # 去掉前导零，否则写进 JSON 会变成非法数字
  warn_port_risk "$PORT"

  # ---- 偷取目标 ----
  local DEST_HOST=''
  if [[ -n $OPT_SNI ]]; then
    warn_dest_risk "$OPT_SNI"   # 格式已由 validate_install_opts 校验
    DEST_HOST=$OPT_SNI
  else
    choose_dest
  fi
  SNI=$DEST_HOST
  DEST=${OPT_DEST:-"${DEST_HOST}:443"}
  valid_dest "$DEST" || die "握手目标格式不正确，应为 域名:端口 或 [IPv6]:端口：${DEST}"

  # 以上是全部需要用户参与的部分，下面开始耗时的安装
  install_xray_core

  # ---- 密钥（需要 xray 二进制）----
  info '生成 Reality 密钥对…'
  gen_keypair || die '密钥生成失败，请确认 Xray 安装完整。'
  SHORT_IDS="$(gen_shortid),$(gen_shortid)"

  # ---- 首个用户 ----
  # --uuid / --name / --host 的格式都已由 validate_install_opts 校验
  local uuid label
  uuid=$OPT_UUID
  [[ -n $uuid ]] || uuid=$(gen_uuid) || die 'UUID 生成失败。'
  label=${OPT_NAME:-'reality'}

  NODE_HOST=$(strip_brackets "$OPT_HOST")
  [[ -n $NODE_HOST ]] || NODE_HOST=$(get_public_ip) || NODE_HOST=''
  if [[ -z $NODE_HOST ]]; then
    warn '未能自动获取公网 IP，可稍后执行 reality change-host 手动指定。'
  fi

  install -d -m 700 "$DATA_DIR"
  : >"$USERS_FILE"; chmod 600 "$USERS_FILE"
  user_add "$uuid" "$label"
  save_meta

  info '写入配置并启动服务…'
  if ! apply_config; then
    # 全新安装失败时清掉半成品状态，避免下次被"已安装"挡住
    rm -rf "$DATA_DIR"
    die '配置应用失败，详情见上方日志。'
  fi

  firewall_allow "$PORT"
  install_self

  ok 'VLESS + Reality + Vision 部署完成！'
  printf '\n'
  show_node "$uuid" "$label" '--qr'
  cloud_firewall_hint
  printf '%s以后直接运行 %sreality%s 即可管理节点。%s\n\n' "$C_BLUE" "$C_BOLD" "$C_OFF$C_BLUE" "$C_OFF"
}

#============================== 管理命令 ==============================#

status_line() {
  local ver n
  ver=$("$XRAY_BIN" version 2>/dev/null | head -n1 | awk '{print $2}')
  n=$(users_count)
  printf '  '
  if systemctl is-active --quiet xray; then
    printf '%s%s 运行中%s' "$C_GREEN" "$GL_ON" "$C_OFF"
  else
    printf '%s%s 已停止%s' "$C_RED" "$GL_OFF" "$C_OFF"
  fi
  printf '%s   %s   Xray %s   %s   %s 个用户' \
    "$C_GRAY" "$GL_DOT" "${ver:-未知}" "$GL_DOT" "$n"
  if autoupdate_enabled; then printf '   %s   自动更新已开' "$GL_DOT"; fi
  printf '%s\n' "$C_OFF"
}

cmd_info() {
  require_installed
  printf '\n'
  status_line
  if (( $(users_count) > 1 )); then
    show_all_nodes
  else
    local uuid label
    IFS=$'\t' read -r uuid label <"$USERS_FILE" || true
    show_node "${uuid:-}" "${label:-user}"
  fi
}

cmd_link() {
  require_installed
  local uuid label
  while IFS=$'\t' read -r uuid label || [[ -n ${uuid:-} ]]; do
    [[ -n ${uuid:-} ]] || continue
    share_link "$uuid" "${label:-user}"; printf '\n'
  done <"$USERS_FILE"
}

cmd_qr() {
  require_installed
  local uuid label
  while IFS=$'\t' read -r uuid label || [[ -n ${uuid:-} ]]; do
    [[ -n ${uuid:-} ]] || continue
    printf '\n'
    rule_top "${label:-user}"
    print_qr "$(share_link "$uuid" "${label:-user}")"
    rule_bottom
  done <"$USERS_FILE"
  printf '\n'
}

cmd_client() {
  require_installed
  local uuid label
  IFS=$'\t' read -r uuid label <"$USERS_FILE" || true
  [[ -n ${uuid:-} ]] || die '没有可用用户。'
  label=${label:-user}
  printf '\n'
  rule_top 'sing-box 出站片段'
  printf '%s' "$C_CYAN"; print_singbox "$uuid" "$label"; printf '%s' "$C_OFF"
  rule_bottom
  printf '\n'
  rule_top 'Clash.Meta / mihomo 节点片段'
  printf '%s' "$C_CYAN"; print_clash "$uuid" "$label"; printf '%s' "$C_OFF"
  rule_bottom
  printf '\n  %s以上片段可直接粘贴进对应客户端的配置文件%s\n\n' "$C_GRAY" "$C_OFF"
}

cmd_add_user() {
  require_installed
  local label uuid
  label=$OPT_NAME
  [[ -n $label ]] || label=$(ask '新用户名称（用于区分设备）' "user$(( $(users_count) + 1 ))")
  valid_label "$label" || die "名称不能含空格、引号或反斜杠，且不超过 32 字符：${label}"
  user_exists_label "$label" && die "名称已存在：${label}"

  uuid=$OPT_UUID
  [[ -n $uuid ]] || uuid=$(gen_uuid) || die 'UUID 生成失败。'
  valid_uuid "$uuid" || die "UUID 格式不正确：${uuid}"
  user_exists_uuid "$uuid" && die 'UUID 已存在。'

  user_add "$uuid" "$label"
  if ! apply_config; then
    awk -F'\t' -v u="$uuid" '$1!=u' "$USERS_FILE" >"${USERS_FILE}.tmp" || true
    mv "${USERS_FILE}.tmp" "$USERS_FILE"; chmod 600 "$USERS_FILE"
    die '添加失败，已撤销改动。'
  fi
  ok "已添加用户：${label}"
  show_node "$uuid" "$label" '--qr'
}

cmd_del_user() {
  require_installed
  local total; total=$(users_count)
  ((total > 1)) || die '至少需要保留一个用户。'

  local -a uuids=() labels=()
  local uuid label i target
  while IFS=$'\t' read -r uuid label || [[ -n ${uuid:-} ]]; do
    [[ -n ${uuid:-} ]] || continue
    uuids+=("$uuid"); labels+=("${label:-user}")
  done <"$USERS_FILE"

  target=$OPT_NAME
  if [[ -z $target ]]; then
    printf '\n%s当前用户：%s\n' "$C_BOLD" "$C_OFF"
    for i in "${!uuids[@]}"; do
      printf '  %2d) %s  (%s)\n' "$((i + 1))" "${labels[i]}" "${uuids[i]}"
    done
    local pick; pick=$(ask '请输入要删除的序号' '')
    if ! [[ $pick =~ ^[0-9]+$ ]] || ((10#$pick < 1 || 10#$pick > ${#uuids[@]})); then
      die '序号无效。'
    fi
    target=${labels[$((10#$pick - 1))]}
  fi
  user_exists_label "$target" || die "找不到用户：${target}"

  cp -a "$USERS_FILE" "${USERS_FILE}.bak"
  awk -F'\t' -v l="$target" '$2!=l' "$USERS_FILE" >"${USERS_FILE}.tmp"
  mv "${USERS_FILE}.tmp" "$USERS_FILE"; chmod 600 "$USERS_FILE"
  if ! apply_config; then
    mv "${USERS_FILE}.bak" "$USERS_FILE"
    die '删除失败，已撤销改动。'
  fi
  rm -f "${USERS_FILE}.bak"
  ok "已删除用户：${target}"
}

cmd_change_port() {
  require_installed
  local old=$PORT new
  new=$OPT_PORT
  [[ -n $new ]] || new=$(ask '新的监听端口' "$old")
  valid_port "$new" || die "端口非法：${new}"
  new=$((10#$new))   # 去掉前导零，否则写进 JSON 会变成非法数字
  if [[ $new == "$old" ]]; then info '端口未变化。'; return 0; fi
  if port_in_use "$new"; then
    confirm "端口 ${new} 已被占用，仍要使用吗？" 'n' || return 1
  fi
  warn_port_risk "$new"
  PORT=$new
  if ! apply_config; then PORT=$old; die '端口修改失败，已回滚。'; fi
  save_meta
  firewall_allow "$new"
  firewall_revoke "$old"
  ok "端口已由 ${old} 改为 ${new}（请同步修改客户端）"
  cloud_firewall_hint
}

cmd_change_sni() {
  require_installed
  local old_sni=$SNI old_dest=$DEST host DEST_HOST=''
  host=$OPT_SNI
  if [[ -z $host ]]; then
    choose_dest
    host=$DEST_HOST
  fi
  valid_host "$host" || die "域名格式不正确：${host}"
  warn_dest_risk "$host"
  SNI=$host
  DEST="${host}:443"
  if ! apply_config; then
    SNI=$old_sni; DEST=$old_dest
    die 'SNI 修改失败，已回滚。'
  fi
  save_meta
  ok "握手目标已改为 ${host}（所有客户端需同步修改 SNI）"
  cmd_info
}

cmd_change_uuid() {
  require_installed
  confirm '重新生成全部用户 UUID？旧客户端将立即失效。' 'n' || return 0
  cp -a "$USERS_FILE" "${USERS_FILE}.bak"
  local uuid label
  : >"${USERS_FILE}.tmp"
  while IFS=$'\t' read -r uuid label || [[ -n ${uuid:-} ]]; do
    [[ -n ${uuid:-} ]] || continue
    printf '%s\t%s\n' "$(gen_uuid)" "${label:-user}" >>"${USERS_FILE}.tmp"
  done <"$USERS_FILE"
  mv "${USERS_FILE}.tmp" "$USERS_FILE"; chmod 600 "$USERS_FILE"
  if ! apply_config; then mv "${USERS_FILE}.bak" "$USERS_FILE"; die '修改失败，已撤销。'; fi
  rm -f "${USERS_FILE}.bak"
  ok 'UUID 已全部重新生成。'
  cmd_info
}

cmd_rekey() {
  require_installed
  confirm '重新生成 Reality 密钥对与 shortId？所有客户端都需更新公钥。' 'n' || return 0
  local opk=$PUBLIC_KEY osk=$PRIVATE_KEY osid=$SHORT_IDS
  gen_keypair || die '密钥生成失败。'
  SHORT_IDS="$(gen_shortid),$(gen_shortid)"
  if ! apply_config; then
    PUBLIC_KEY=$opk; PRIVATE_KEY=$osk; SHORT_IDS=$osid
    die '密钥更新失败，已回滚。'
  fi
  save_meta
  ok '密钥已更新。'
  cmd_info
}

cmd_change_host() {
  require_installed
  local new=$OPT_HOST
  [[ -n $new ]] || new=$(ask '分享链接使用的地址（IP 或域名，留空自动探测）' "$NODE_HOST")
  new=$(strip_brackets "$new")
  if [[ -z $new ]]; then
    new=$(get_public_ip) || die '自动探测失败，请手动指定。'
  fi
  valid_addr "$new" || die "地址格式不正确，只接受 IPv4、IPv6 或域名：${new}"
  NODE_HOST=$new
  HOST_CACHE=''
  save_meta
  ok "分享地址已设置为：${new}"
}

cmd_rules() {
  require_installed
  printf '\n当前路由策略：\n'
  printf '  内网地址拦截 : %s开启%s（固定开启，防止代理被用来探测本机内网）\n' "$C_GREEN" "$C_OFF"
  printf '  BT 流量拦截  : %s\n' "$([[ $BLOCK_BT == '1' ]] && printf '%s开启%s' "$C_GREEN" "$C_OFF" || printf '关闭')"
  printf '  广告域名拦截 : %s\n\n' "$([[ $BLOCK_ADS == '1' ]] && printf '%s开启%s' "$C_GREEN" "$C_OFF" || printf '关闭')"

  local ob=$BLOCK_BT oa=$BLOCK_ADS
  if confirm '拦截 BT / PT 流量？（多数 VPS 商家禁止）' "$([[ $BLOCK_BT == '1' ]] && echo y || echo n)"; then
    BLOCK_BT='1'; else BLOCK_BT='0'
  fi
  if confirm '拦截广告域名（geosite:category-ads-all）？' "$([[ $BLOCK_ADS == '1' ]] && echo y || echo n)"; then
    BLOCK_ADS='1'; else BLOCK_ADS='0'
  fi
  if [[ $BLOCK_BT == "$ob" && $BLOCK_ADS == "$oa" ]]; then info '规则未变化。'; return 0; fi
  if ! apply_config; then BLOCK_BT=$ob; BLOCK_ADS=$oa; die '修改失败，已回滚。'; fi
  save_meta
  ok '路由规则已更新。'
}

xray_version() { "$XRAY_BIN" version 2>/dev/null | head -n1 | awk '{print $2}'; }

# 官方脚本在「已是最新」时只打印一行提示并 exit 0，不会改动任何文件，
# 因此本命令可以安全地反复执行（定时任务正是依赖这一点）。
cmd_update() {
  detect_os
  local backup='' old_ver='' new_ver=''

  if [[ -x $XRAY_BIN ]]; then
    old_ver=$(xray_version)
    install -d -m 700 "$DATA_DIR"
    backup="${DATA_DIR}/xray.prev"
    cp -a "$XRAY_BIN" "$backup" 2>/dev/null || backup=''
  fi

  install_xray_core
  new_ver=$(xray_version)

  if [[ -n $old_ver && $old_ver == "$new_ver" ]]; then
    ok "已是最新版本：${new_ver}"
    return 0
  fi

  if is_installed && load_meta; then
    if apply_config; then
      ok "Xray 已从 ${old_ver:-未知} 更新到 ${new_ver}，配置已重新载入。"
    else
      # 新版本起不来时退回上一版二进制，避免无人值守更新把代理搞挂
      if [[ -n $backup && -s $backup ]]; then
        warn "新版本（${new_ver:-版本号未知}）启动失败，正在回滚到 ${old_ver}…"
        install -m 755 "$backup" "$XRAY_BIN"
        systemctl restart xray >/dev/null 2>&1 || true
        sleep 1
        if systemctl is-active --quiet xray; then
          ok "已回滚到 ${old_ver} 并恢复运行。"
        else
          error '回滚后服务仍未运行，请执行 reality log 查看原因。'
        fi
      fi
      return 1
    fi
  else
    ok "Xray 已更新到 ${new_ver}。"
  fi
}

cmd_autoupdate() {
  local action=${ARG1:-status}
  case $action in
    on|enable)
      [[ -x $CMD_PATH ]] || die "未找到 ${CMD_PATH}，请先完成安装。"
      cat >"$UPDATE_SERVICE" <<EOF
[Unit]
Description=Reality 自动更新 Xray-core
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${CMD_PATH} update --yes
EOF
      # RandomizedDelaySec 把请求打散，避免所有机器同一分钟去打 GitHub API
      cat >"$UPDATE_TIMER" <<'EOF'
[Unit]
Description=每天检查一次 Xray-core 更新

[Timer]
OnCalendar=daily
RandomizedDelaySec=4h
Persistent=true

[Install]
WantedBy=timers.target
EOF
      chmod 644 "$UPDATE_SERVICE" "$UPDATE_TIMER"
      systemctl daemon-reload >/dev/null 2>&1 || true
      systemctl enable --now reality-update.timer >/dev/null 2>&1 ||
        die '定时器启用失败。'
      ok '已开启自动更新：每天检查一次，随机延迟 0-4 小时。'
      info '更新失败或新版本起不来时会自动回滚到上一版本。'
      cmd_autoupdate_status
      ;;
    off|disable)
      systemctl disable --now reality-update.timer >/dev/null 2>&1 || true
      rm -f "$UPDATE_SERVICE" "$UPDATE_TIMER"
      systemctl daemon-reload >/dev/null 2>&1 || true
      ok '已关闭自动更新。'
      ;;
    status) cmd_autoupdate_status ;;
    *) die "用法：reality autoupdate <on|off|status>" ;;
  esac
}

cmd_autoupdate_status() {
  if [[ -f $UPDATE_TIMER ]] && systemctl is-enabled --quiet reality-update.timer 2>/dev/null; then
    printf '自动更新：%s已开启%s\n' "$C_GREEN" "$C_OFF"
    systemctl list-timers reality-update.timer --no-pager 2>/dev/null | head -n2 || true
  else
    printf '自动更新：%s未开启%s（执行 reality autoupdate on 开启）\n' "$C_YELLOW" "$C_OFF"
  fi
  return 0
}

# 更新管理脚本自身。刻意只提供手动方式：让服务器无人值守地自动执行
# 来自网络的新代码，风险远大于收益。
cmd_selfupdate() {
  local tmp new_ver
  tmp=$(mktemp "${TMPDIR:-/tmp}/reality.XXXXXX.sh") || return 1
  info '下载最新版管理脚本…'
  if ! curl -fsSL --retry 3 --max-time 60 -o "$tmp" "$REPO_RAW"; then
    rm -f "$tmp"; die "下载失败：${REPO_RAW}"
  fi
  if ! head -n1 "$tmp" | grep -q '^#!' || ! bash -n "$tmp" 2>/dev/null; then
    rm -f "$tmp"; die '下载到的脚本未通过语法检查，已放弃更新。'
  fi
  new_ver=$(grep -m1 "^readonly SCRIPT_VERSION=" "$tmp" | cut -d"'" -f2)
  # 按内容而非版本号判断：修了 bug 却忘记改版本号时，也不会漏掉更新
  if [[ -f $CMD_PATH ]] && cmp -s "$tmp" "$CMD_PATH"; then
    rm -f "$tmp"
    ok "已是最新版本：v${SCRIPT_VERSION}"
    return 0
  fi
  install -m 755 "$tmp" "$CMD_PATH"
  rm -f "$tmp"
  if [[ $new_ver == "$SCRIPT_VERSION" ]]; then
    ok "管理脚本已更新到最新提交（版本号仍为 v${SCRIPT_VERSION}）"
  else
    ok "管理脚本已从 v${SCRIPT_VERSION} 更新到 v${new_ver:-未知}"
  fi
}

cmd_restart() { systemctl restart xray && ok 'Xray 已重启。'; }
cmd_stop()    { systemctl stop xray && ok 'Xray 已停止。'; }
cmd_start()   { systemctl start xray && ok 'Xray 已启动。'; }
cmd_status()  { systemctl status xray --no-pager -l 2>&1 | head -n 20; }

# 日志分两处：配置错误导致起不来时，日志组件还没初始化，原因只进 journal；
# 运行起来以后的报错只写 XRAY_LOG。只看其中一处，总有一类问题看不到
cmd_log() {
  if command -v journalctl >/dev/null 2>&1; then
    section '最近的启动记录（起不来的原因在这里）'
    journalctl -u xray -n 15 --no-pager 2>/dev/null | sed 's/^/  /' || true
  fi
  section "运行日志 ${XRAY_LOG}"
  info '按 Ctrl+C 退出日志跟踪。'
  # 捕获 Ctrl+C 只为结束 tail 后回到菜单，而不是连脚本一起退出
  trap : INT
  tail -n 50 -F "$XRAY_LOG" 2>/dev/null || true
  trap - INT
}

cmd_bbr() {
  local cc
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '')
  if [[ $cc == 'bbr' ]]; then ok 'BBR 已处于开启状态。'; return 0; fi
  modprobe tcp_bbr 2>/dev/null || true
  if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q 'bbr'; then
    warn '当前内核不支持 BBR（常见于老旧内核或部分 OpenVZ / LXC 容器）。'
    return 1
  fi
  cat >/etc/sysctl.d/99-reality-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl --system >/dev/null 2>&1 || true
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '')
  if [[ $cc == 'bbr' ]]; then ok 'BBR + fq 已开启。'; else warn "开启失败，当前算法：${cc:-未知}"; fi
}

manual_remove_xray() {
  systemctl disable --now xray >/dev/null 2>&1 || true
  rm -f "$XRAY_UNIT" /etc/systemd/system/xray@.service
  rm -rf /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -f "$XRAY_BIN"
  return 0
}

cmd_uninstall() {
  confirm '确定卸载 Xray 及本脚本的全部数据吗？' 'n' || { info '已取消。'; return 0; }

  local port=''
  if load_meta 2>/dev/null; then port=$PORT; fi

  local tmp; tmp=$(mktemp -d)
  if curl -fsSL --max-time 120 -o "${tmp}/install-release.sh" "$XRAY_INSTALLER" 2>/dev/null; then
    bash "${tmp}/install-release.sh" remove --purge ||
      { warn '官方卸载脚本执行失败，改为手动清理。'; manual_remove_xray; }
  else
    warn '无法下载官方卸载脚本，改为手动清理。'
    manual_remove_xray
  fi
  rm -rf "$tmp"

  # 官方脚本在某些情况下会提前退出，这里兜底确认二进制确实已移除
  if [[ -e $XRAY_BIN ]]; then
    warn '检测到 Xray 二进制仍然存在，执行兜底清理。'
    manual_remove_xray
  fi

  systemctl disable --now reality-update.timer >/dev/null 2>&1 || true
  rm -f "$UPDATE_SERVICE" "$UPDATE_TIMER"
  systemctl daemon-reload >/dev/null 2>&1 || true

  [[ -n $port ]] && firewall_revoke "$port"
  rm -rf "$DATA_DIR" "$XRAY_CONF_DIR"
  rm -f "$CMD_PATH" /etc/sysctl.d/99-reality-bbr.conf
  ok '已全部卸载。'
}

#=============================== 诊断 =================================#

# 每项检查只设置三个值、不直接输出，便于单独测试：
#   CK_STATUS  ok | warn | fail | skip
#   CK_DETAIL  检查结果
#   CK_HINT    怎么修（ok 时不显示）
#   后面的检查依赖前面的结果时（内核跑不起来、DNS 不通），直接跳过而不是跟着报错，
#   免得一个根因刷出一串失败
CK_STATUS=''; CK_DETAIL=''; CK_HINT=''; CK_BIN_OK=1; CK_DNS_OK=1
ck_set() { CK_STATUS=$1; CK_DETAIL=$2; CK_HINT=${3:-}; }

ck_binary() {
  local v; v=$(xray_version)
  if [[ -n $v ]]; then
    ck_set ok "Xray ${v}"; CK_BIN_OK=1
  else
    ck_set fail '内核无法运行' '执行 reality update 重新安装内核'; CK_BIN_OK=0
  fi
}

ck_config() {
  if [[ $CK_BIN_OK == 0 ]]; then ck_set skip '跳过：内核无法运行，先解决上一项'; return; fi
  local out why
  if ! out=$(xray_test_config "$XRAY_CONF"); then
    # 报错形如 "Failed to start: main: … > … > 真正的原因"，只取最后一段
    why=$(grep -m1 'Failed to start' <<<"$out") || why=''
    why=${why##*> }
    ck_set fail "未通过 Xray 自检${why:+：${why:0:60}}" \
      "完整报错：xray run -test -config ${XRAY_CONF}"
    return
  fi
  local perm owner want meta_perm
  perm=$(stat -c %a "$XRAY_CONF" 2>/dev/null)
  owner=$(stat -c %U "$XRAY_CONF" 2>/dev/null)
  meta_perm=$(stat -c %a "$META_FILE" 2>/dev/null)
  want=$(service_user)
  if [[ $meta_perm != 600 ]]; then
    ck_set warn "通过自检，但 meta.conf 权限为 ${meta_perm}（其中有私钥）" "chmod 600 ${META_FILE}"
  elif [[ $perm != 600 || $owner != "$want" ]]; then
    ck_set warn "通过自检，但权限为 ${perm}（属于 ${owner}），私钥可能被本机其他用户读到" \
      "chown ${want} ${XRAY_CONF} && chmod 600 ${XRAY_CONF}"
  else
    ck_set ok '通过自检，权限正确'
  fi
}

ck_service() {
  local state
  if state=$(systemctl is-active xray 2>/dev/null); then ck_set ok '运行中'; return; fi
  case $state in
    failed)     state='启动失败' ;;
    activating) state='正在启动，可能在反复崩溃重启' ;;
    inactive)   state='已停止' ;;
  esac
  ck_set fail "未运行（${state:-状态未知}）" '执行 reality restart；还起不来就执行 reality log 查看原因'
}

# 进程在跑不等于端口在听：配置错、端口被占都会让服务反复重启
ck_port() {
  if ! command -v ss >/dev/null 2>&1; then ck_set skip '系统没有 ss 命令，跳过'; return; fi
  local lines who
  # 不用 -H：老版本 ss 不认识它；表头的第 4 列是 "Local"，本来就匹配不上
  lines=$(ss -ltnp 2>/dev/null | awk -v p=":${PORT}\$" '$4 ~ p')
  if [[ -z $lines ]]; then
    ck_set fail "没有程序在监听 ${PORT}/tcp" '服务可能一启动就退出了，执行 reality log 查看原因'
  elif [[ $lines == *'"xray"'* ]]; then
    ck_set ok "${PORT}/tcp 由 Xray 监听"
  elif [[ $lines != *users:* ]]; then
    ck_set ok "${PORT}/tcp 正在监听"   # 看不到进程信息时只能确认端口已打开
  else
    who=$(grep -oE 'users:\(\("[^"]+"' <<<"$lines" | head -n1 | cut -d'"' -f2)
    ck_set fail "${PORT}/tcp 被其它程序（${who:-未知}）占用" \
      '停掉占用端口的程序，或执行 reality change-port 换一个端口'
  fi
}

# 按 ufw → firewalld → iptables 的顺序找第一个在管事的防火墙。
# 直接写的 nftables 规则无法可靠判断，所以没发现拦截时措辞是"未发现"，而不是"没有"。
# 修复一律指向 reality open-port：它与安装时走同一套逻辑。别改回让用户手敲
# `netfilter-persistent save`——那会把 Docker、fail2ban 的运行时规则一并存进开机规则
ck_firewall() {
  local out fix='执行 reality open-port 自动放行'
  if command -v ufw >/dev/null 2>&1 && out=$(LC_ALL=C ufw status verbose 2>/dev/null) &&
     [[ $out == *'Status: active'* ]]; then
    if [[ $out == *'Default: allow (incoming)'* ]]; then
      ck_set ok 'ufw 默认放行所有入站'
    elif ufw_allows "$PORT" <<<"$out"; then
      ck_set ok "ufw 已放行 ${PORT}/tcp"
    else
      ck_set fail "ufw 已启用，但没有放行 ${PORT}/tcp 的规则" "$fix"
    fi
    return
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    if firewall-cmd --query-port="${PORT}/tcp" >/dev/null 2>&1 ||
       { [[ $PORT == 443 ]] && firewall-cmd --query-service=https >/dev/null 2>&1; }; then
      ck_set ok "firewalld 已放行 ${PORT}/tcp"
    else
      ck_set fail "firewalld 已启用，但没有放行 ${PORT}/tcp" "$fix"
    fi
    return
  fi
  if command -v iptables >/dev/null 2>&1 && out=$(iptables -S INPUT 2>/dev/null); then
    case $(iptables_verdict "$PORT" <<<"$out") in
      accept) ck_set ok "iptables 已放行 ${PORT}/tcp"; return ;;
      late)   ck_set fail "iptables 里放行 ${PORT}/tcp 的规则排在拒绝规则后面，不会生效" "$fix"; return ;;
      deny)   ck_set fail "iptables 会拒绝 ${PORT}/tcp（没有放行它的规则）" "$fix"; return ;;
    esac
  fi
  ck_set ok '未发现本机防火墙拦截'
}

# 时间不准不影响连接（见 check_clock 的说明），所以最多只是提醒
# 读不到状态（没有 timedatectl、OpenVZ/LXC 这类时间归宿主机管的容器）时跳过，
# 不能当成"未同步"去提醒一件用户根本改不了的事
ck_clock() {
  local synced
  if ! command -v timedatectl >/dev/null 2>&1 ||
     ! synced=$(timedatectl show -p NTPSynchronized --value 2>/dev/null) || [[ -z $synced ]]; then
    ck_set skip '读不到时间同步状态，跳过'
    return
  fi
  if [[ $synced == 'yes' ]]; then
    ck_set ok '已与 NTP 同步'
  else
    ck_set warn '未与 NTP 同步' \
      '不影响节点连接，但偏差过大会让 HTTPS 证书校验失败、更新下载不了。可执行 apt install -y chrony'
  fi
}

# 用伪装域名测系统解析器：它本身就必须能解析，Xray 的 DNS 也以系统解析器为首选
ck_dns() {
  if run_timeout 5 getent hosts "$SNI" >/dev/null 2>&1; then
    ck_set ok "系统解析器正常（${SNI}）"
    CK_DNS_OK=1
  else
    ck_set fail "无法解析 ${SNI}" \
      '检查 /etc/resolv.conf。DNS 不通时的典型表现是：节点能连上，但网页打不开'
    CK_DNS_OK=0
  fi
}

# 伪装目标悄悄失效（网站改了配置、上了 CDN、被墙）是节点用着用着就挂的典型原因，
# 而客户端那边只会显示连不上，看不出原因
ck_dest() {
  local host port rc=0
  port=${DEST##*:}
  host=$(strip_brackets "${DEST%:*}")
  # 目标是域名而 DNS 已经不通时，这一项必然失败，再报一次只会误导
  if [[ $CK_DNS_OK == 0 ]] && ! valid_ipv4 "$host" && ! valid_ipv6 "$host"; then
    ck_set skip '跳过：DNS 解析失败，先解决上一项'
    return
  fi
  check_dest "$host" "$port" "$SNI" || rc=$?
  case $rc in
    0) ck_set ok "${DEST} 支持 TLS1.3 + HTTP/2" ;;
    1) ck_set fail "从本机无法与 ${DEST} 完成 TLS1.3 握手" \
         '伪装目标可能已失效或被墙：执行 reality change-sni 换一个' ;;
    2) ck_set fail "${DEST} 不再支持 HTTP/2" '执行 reality change-sni 换一个' ;;
    3) ck_set fail "${DEST} 不再支持 TLS1.3" '执行 reality change-sni 换一个' ;;
    4) ck_set skip 'openssl 版本过旧，无法检测' ;;
    *) ck_set warn "检测异常（代码 ${rc}）" ;;
  esac
}

local_addrs() { ip -o addr show 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4}'; }

# 服务器换了 IP 后分享链接会整体失效，这是另一类"突然连不上"
ck_host() {
  if [[ -z $NODE_HOST ]]; then
    ck_set warn '未设置，分享链接里是 YOUR_SERVER_IP' '执行 reality change-host <本机 IP 或域名>'
    return
  fi
  local IP_PROBE_TIMEOUT=4 addrs a pub4='' pub6='' have4=0 have6=0 matched=0 now
  # getent 对字面 IP 直接原样返回（顺带把 IPv6 规整成标准写法），对域名则做解析。
  # 本机没有对应协议栈时它连字面 IP 都不返回，这时直接拿原值比较
  addrs=$(run_timeout 5 getent ahosts "$NODE_HOST" 2>/dev/null | awk '{print $1}' | sort -u)
  if [[ -z $addrs ]] && { valid_ipv4 "$NODE_HOST" || valid_ipv6 "$NODE_HOST"; }; then
    addrs=${NODE_HOST,,}
  fi
  if [[ -z $addrs ]]; then
    ck_set fail "${NODE_HOST} 解析不到任何地址" '检查该域名的 DNS 记录'
    return
  fi
  # 主机名与节点域名相同时，/etc/hosts 常把它指到 127.0.1.1，这说明不了公网 DNS 的情况
  addrs=$(grep -Ev '^(127\.|::1$)' <<<"$addrs") || addrs=''
  if [[ -z $addrs ]]; then
    ck_set skip "${NODE_HOST} 在本机解析为回环地址（多半来自 /etc/hosts），无法核对"
    return
  fi
  # 地址就在本机网卡上，肯定指向本机——多 IP 的机器出口 IP 未必是它，不能只比出口 IP
  if grep -qxFf <(local_addrs) <<<"$addrs"; then
    ck_set ok "${NODE_HOST} 指向本机"
    return
  fi
  while read -r a; do
    if valid_ipv6 "$a"; then have6=1; else have4=1; fi
  done <<<"$addrs"
  if ((have4)); then pub4=$(public_ip 4) || pub4=''; fi
  if ((have6)); then pub6=$(public_ip 6) || pub6=''; fi
  if [[ -z $pub4 && -z $pub6 ]]; then
    ck_set skip '无法探测本机公网 IP，跳过'
    return
  fi
  while read -r a; do
    if [[ $a == "$pub4" || $a == "$pub6" ]]; then matched=1; fi
  done <<<"$addrs"
  if ((matched)); then
    ck_set ok "${NODE_HOST} 指向本机"
  else
    now=${pub4:-$pub6}
    ck_set fail "${NODE_HOST} 与本机公网 IP ${now} 不一致，分享链接已失效" \
      "若是服务器换了 IP，执行 reality change-host ${now}，再把新链接导入客户端"
  fi
}

ck_log() {
  local since recent n last
  if [[ ! -s $XRAY_LOG ]]; then ck_set ok '没有错误记录'; return; fi
  # 日志行以 "2026/09/28 03:18:23" 开头，这种格式按字符串比较即按时间比较
  since=$(date -d '24 hours ago' '+%Y/%m/%d %H:%M:%S' 2>/dev/null) || since=''
  recent=$(awk -v s="$since" 'substr($0, 1, 19) >= s && /\[Error\]/' "$XRAY_LOG")
  if [[ -z $recent ]]; then ck_set ok '近 24 小时没有错误'; return; fi
  n=$(wc -l <<<"$recent")
  # 去掉时间、级别和连接编号：… [Error] [3183754453] app/…: 原因
  last=$(tail -n1 <<<"$recent" | sed -E 's/.*\[Error\][[:space:]]*(\[[0-9]+\][[:space:]]*)?//')
  ck_set warn "近 24 小时 ${n} 条错误，最近一条：${last:0:60}" '执行 reality log 查看完整日志'
}

print_ck() { # print_ck <标签>
  local mark color
  case $CK_STATUS in
    ok)   mark=$GL_PASS; color=$C_GREEN ;;
    warn) mark=$GL_WARN; color=$C_YELLOW ;;
    fail) mark=$GL_FAIL; color=$C_RED ;;
    *)    mark=$GL_SKIP; color=$C_GRAY ;;
  esac
  printf '  %s%s%s %s  %s\n' "$color" "$mark" "$C_OFF" "$(pad_to "$1" 10)" "$CK_DETAIL"
  if [[ -n $CK_HINT && $CK_STATUS != 'ok' ]]; then
    printf '               %s→ %s%s\n' "$C_GRAY" "$CK_HINT" "$C_OFF"
  fi
  return 0
}

# 按链路从本机往外逐项检查。发现问题时退出码为 1，可直接用于定时监控
cmd_check() {
  require_installed
  local item fails=0 warns=0
  local -a items=(
    'binary:Xray 内核'   'config:配置文件'   'service:服务状态'  'port:端口监听'
    'firewall:本机防火墙' 'clock:系统时间'   'dns:DNS 解析'      'dest:伪装目标'
    'host:分享地址'       'log:错误日志'
  )
  CK_BIN_OK=1; CK_DNS_OK=1
  printf '\n'
  rule_top '节点诊断'
  for item in "${items[@]}"; do
    ck_set skip ''
    "ck_${item%%:*}"
    print_ck "${item#*:}"
    case $CK_STATUS in
      fail) fails=$((fails + 1)) ;;
      warn) warns=$((warns + 1)) ;;
    esac
  done
  printf '\n  %s云服务器的安全组无法在本机检测：以上都正常却仍连不上时，请到控制台确认放行了 TCP %s。%s\n' \
    "$C_GRAY" "$PORT" "$C_OFF"
  rule_bottom
  if ((fails > 0)); then
    local extra=''
    if ((warns > 0)); then extra="，另有 ${warns} 个提醒"; fi
    printf '  %s发现 %d 个问题%s。按上面 → 的提示处理。%s\n\n' "$C_RED" "$fails" "$extra" "$C_OFF"
  elif ((warns > 0)); then
    printf '  %s没有发现问题，有 %d 个提醒。%s\n\n' "$C_YELLOW" "$warns" "$C_OFF"
  else
    printf '  %s全部正常。%s\n\n' "$C_GREEN" "$C_OFF"
  fi
  ((fails == 0))
}

#=============================== 菜单 =================================#

item() { # item <编号> <文字>：左列，按显示宽度补齐
  printf '  %s%2s%s %s' "$C_GREEN" "$1" "$C_OFF" "$(pad_to "$2" 24)"
}

item_end() { # item_end <编号> <文字> [颜色]：行末项，不补空格
  printf '  %s%2s%s %s\n' "${3:-$C_GREEN}" "$1" "$C_OFF" "$2"
}

show_menu() {
  printf '\n'
  rule_top "$SCRIPT_NAME"
  printf '  %sv%s%s\n' "$C_GRAY" "$SCRIPT_VERSION" "$C_OFF"
  if is_installed; then
    status_line
  else
    printf '  %s%s 未安装%s%s   %s   选 1 开始安装%s\n' \
      "$C_YELLOW" "$GL_OFF" "$C_OFF" "$C_GRAY" "$GL_DOT" "$C_OFF"
  fi

  section '节点'
  item  1 '安装 / 重装';       item_end  2 '查看节点与二维码'
  item_end 3 '导出客户端配置'

  section '用户'
  item  4 '添加用户';          item_end  5 '删除用户'
  item_end 6 '重新生成全部 UUID'

  section '参数'
  item  7 '修改监听端口';      item_end  8 '更换伪装域名 (SNI)'
  item  9 '修改分享地址';      item_end 10 '更换 Reality 密钥'
  item_end 11 '路由拦截规则'

  section '维护'
  item 12 '服务启停 / 状态';   item_end 13 '查看实时日志'
  item 14 '更新 Xray-core';    item_end 15 "自动更新（$(autoupdate_state)）"
  item 16 '开启 BBR 加速';     item_end 17 '卸载' "$C_RED"
  # 追加为 18 而不是插到前面：改动已有编号会让老用户按习惯输入时误触（比如误入卸载）
  item_end 18 '节点诊断（连不上时先跑这个）'

  printf '\n'
  item_end 0 '退出'
  rule_bottom
}

autoupdate_enabled() {
  [[ -f $UPDATE_TIMER ]] && systemctl is-enabled --quiet reality-update.timer 2>/dev/null
}

autoupdate_state() {
  if autoupdate_enabled; then printf '%s已开启%s' "$C_GREEN" "$C_OFF"
  else printf '未开启'; fi
}

autoupdate_toggle() {
  if autoupdate_enabled; then
    cmd_autoupdate_status
    confirm '要关闭自动更新吗？' 'n' && ARG1='off' || return 0
  else
    printf '开启后每天检查一次官方最新版（随机延迟 0-4 小时），\n'
    printf '新版本启动失败会自动回滚到上一版本。\n'
    confirm '要开启自动更新吗？' 'y' && ARG1='on' || return 0
  fi
  cmd_autoupdate
}

service_submenu() {
  printf '  1) 重启    2) 停止    3) 启动    4) 查看状态\n'
  case "$(ask '请选择' '1')" in
    1) cmd_restart ;;
    2) cmd_stop ;;
    3) cmd_start ;;
    4) cmd_status ;;
    *) warn '无效选择。' ;;
  esac
}

menu_loop() {
  attach_tty || die '当前环境无法交互，请改用子命令，例如：reality install --yes'
  local choice
  while :; do
    show_menu
    choice=$(ask '请输入选项' '0')
    printf '\n'
    case $choice in
      1)  cmd_install     || error '安装未完成。' ;;
      2)  cmd_info        || error '操作失败。' ;;
      3)  cmd_client      || error '操作失败。' ;;
      4)  cmd_add_user    || error '操作失败。' ;;
      5)  cmd_del_user    || error '操作失败。' ;;
      6)  cmd_change_uuid || error '操作失败。' ;;
      7)  cmd_change_port || error '操作失败。' ;;
      8)  cmd_change_sni  || error '操作失败。' ;;
      9)  cmd_change_host || error '操作失败。' ;;
      10) cmd_rekey       || error '操作失败。' ;;
      11) cmd_rules       || error '操作失败。' ;;
      12) service_submenu || error '操作失败。' ;;
      13) cmd_log         || error '操作失败。' ;;
      14) cmd_update      || error '操作失败。' ;;
      15) autoupdate_toggle || error '操作失败。' ;;
      16) cmd_bbr         || error '操作失败。' ;;
      17) cmd_uninstall   || error '操作失败。'
          is_installed    || exit 0 ;;
      18) cmd_check       || true ;;   # 非零只表示"发现了问题"，结果已在上面列出
      0)  exit 0 ;;
      *)  warn '无效选项。' ;;
    esac
    pause
  done
}

#=============================== 入口 =================================#

usage() {
  cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

用法：reality [命令] [选项]

命令：
  menu                    打开交互菜单（默认）
  install                 安装并生成节点
  info                    查看节点信息
  link                    仅输出分享链接
  qr                      输出二维码
  client                  输出 sing-box / Clash.Meta 配置片段
  add-user                添加用户
  del-user                删除用户
  change-port             修改监听端口
  change-sni              更换 Reality 偷取目标
  change-host             修改分享链接中的地址
  change-uuid             重新生成全部 UUID
  rekey                   重新生成 Reality 密钥对
  rules                   调整路由拦截规则
  update                  立即检查并更新 Xray-core（已是最新则不改动任何文件）
  autoupdate <on|off|status>
                          自动更新开关：每天检查一次官方最新版，
                          新版本起不来会自动回滚到上一版本
  selfupdate              更新管理脚本自身（仅手动）
  start | stop | restart | status | log
  check                   一键诊断：逐项检查内核、配置、服务、端口、防火墙、
                          DNS、伪装目标、分享地址与错误日志，并给出修复方法。
                          发现问题时退出码为 1，可用于定时监控
  open-port               按当前端口重新放行本机防火墙（ufw / firewalld / iptables），
                          逻辑与安装时相同，重复执行无副作用
  bbr                     开启 BBR 加速
  uninstall               卸载
  version                 显示版本

选项：
  --port <端口>           监听端口，默认 443
  --sni <域名>            Reality 偷取目标域名
  --dest <域名:端口>      握手目标，默认 <sni>:443
  --uuid <UUID>           指定用户 ID
  --name <名称>           节点 / 用户名称
  --host <IP或域名>       分享链接使用的地址
  --force                 已安装时强制重装
  -y, --yes               非交互模式：不再提问，且所有确认一律视为「是」
                          （对 rekey / change-uuid / uninstall 等操作请谨慎使用）

环境变量：
  XRAY_VERSION=v1.8.24         安装指定版本的 Xray-core
  PROXY=http://127.0.0.1:8118  通过代理下载官方脚本

示例：
  reality install --yes
  reality install --port 8443 --sni www.apple.com --name hk
  reality add-user --name phone
EOF
}

ACTION='menu'; ARG1=''
OPT_PORT=''; OPT_SNI=''; OPT_DEST=''; OPT_UUID=''; OPT_NAME=''; OPT_HOST=''
OPT_FORCE=0; OPT_YES=0

parse_args() {
  if (($# > 0)); then ACTION=$1; shift; fi
  while (($# > 0)); do
    case $1 in
      --port)    [[ $# -ge 2 ]] || die '--port 需要参数';  OPT_PORT=$2; shift 2 ;;
      --sni)     [[ $# -ge 2 ]] || die '--sni 需要参数';   OPT_SNI=$2;  shift 2 ;;
      --dest)    [[ $# -ge 2 ]] || die '--dest 需要参数';  OPT_DEST=$2; shift 2 ;;
      --uuid)    [[ $# -ge 2 ]] || die '--uuid 需要参数';  OPT_UUID=$2; shift 2 ;;
      --name)    [[ $# -ge 2 ]] || die '--name 需要参数';  OPT_NAME=$2; shift 2 ;;
      --host)    [[ $# -ge 2 ]] || die '--host 需要参数';  OPT_HOST=$2; shift 2 ;;
      --force)   OPT_FORCE=1; shift ;;
      -y|--yes)  OPT_YES=1;   shift ;;
      -h|--help) usage; exit 0 ;;
      -*) die "未知选项：$1（执行 reality help 查看帮助）" ;;
      *) # 子命令的位置参数，如 autoupdate on
         [[ -z $ARG1 ]] || die "多余的参数：$1"
         ARG1=$1; shift ;;
    esac
  done
}

dispatch() {
  case $ACTION in
    menu|'')          menu_loop ;;
    install)          cmd_install ;;
    info)             cmd_info ;;
    link)             cmd_link ;;
    qr)               cmd_qr ;;
    client|export)    cmd_client ;;
    add-user|adduser) cmd_add_user ;;
    del-user|deluser) cmd_del_user ;;
    change-port|port) cmd_change_port ;;
    change-sni|sni)   cmd_change_sni ;;
    change-host|host) cmd_change_host ;;
    change-uuid)      cmd_change_uuid ;;
    rekey)            cmd_rekey ;;
    rules)            cmd_rules ;;
    update)           cmd_update ;;
    autoupdate)       cmd_autoupdate ;;
    selfupdate)       cmd_selfupdate ;;
    restart)          cmd_restart ;;
    start)            cmd_start ;;
    stop)             cmd_stop ;;
    status)           cmd_status ;;
    log|logs)         cmd_log ;;
    bbr)              cmd_bbr ;;
    check)            cmd_check ;;
    open-port)        cmd_open_port ;;
    uninstall|remove) cmd_uninstall ;;
    version|-v|--version) printf '%s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" ;;
    help)             usage ;;
    *)                die "未知命令：${ACTION}（执行 reality help 查看帮助）" ;;
  esac
}

# 把位置参数映射到对应选项，如 `reality change-port 8443`。
# 不接受参数的命令必须报错——静默忽略会让敲错的命令看起来"执行成功"却什么都没做。
apply_positional() {
  [[ -n $ARG1 ]] || return 0
  case $ACTION in
    autoupdate) ;;  # 由 cmd_autoupdate 直接读取 ARG1
    change-port|port)  [[ -n $OPT_PORT ]] || OPT_PORT=$ARG1 ;;
    change-sni|sni)    [[ -n $OPT_SNI  ]] || OPT_SNI=$ARG1 ;;
    change-host|host)  [[ -n $OPT_HOST ]] || OPT_HOST=$ARG1 ;;
    add-user|adduser|del-user|deluser)
                       [[ -n $OPT_NAME ]] || OPT_NAME=$ARG1 ;;
    install)
      die "install 需要用具体选项，例如：reality install --port ${ARG1}（或 --sni / --name）" ;;
    *) die "命令 ${ACTION} 不接受参数：${ARG1}" ;;
  esac
  return 0
}

main() {
  parse_args "$@"
  apply_positional

  case $ACTION in
    help|version|-v|--version) ;;
    *) require_root; attach_tty || true ;;
  esac
  if ((OPT_YES == 1)); then INTERACTIVE=0; ASSUME_YES=1; fi

  # 子命令内部已用 die/error 自行报错，这里按其退出码结束，
  # 避免主动 return 1 的正常分支再触发 ERR trap 的“意外中止”提示
  dispatch || exit $?
}

# REALITY_LIB=1 时只加载函数不执行，供测试脚本 source 使用
[[ ${REALITY_LIB:-0} == '1' ]] || main "$@"
