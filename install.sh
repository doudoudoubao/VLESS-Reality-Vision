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

readonly SCRIPT_VERSION='1.1.1'
readonly SCRIPT_NAME='VLESS + Reality + Vision 一键脚本'
readonly REPO_RAW='https://raw.githubusercontent.com/doudoudoubao/VLESS-Reality-Vision/main/install.sh'
readonly XRAY_INSTALLER='https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh'

readonly XRAY_BIN='/usr/local/bin/xray'
readonly XRAY_CONF_DIR='/usr/local/etc/xray'
readonly XRAY_CONF="${XRAY_CONF_DIR}/config.json"
readonly XRAY_UNIT='/etc/systemd/system/xray.service'
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
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_OFF=''
fi

info() { printf '%s[信息]%s %s\n' "$C_BLUE" "$C_OFF" "$*"; }
ok()   { printf '%s[成功]%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
warn() { printf '%s[警告]%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
error(){ printf '%s[错误]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
die()  { error "$*"; exit 1; }
hr()   { printf '%s\n' '----------------------------------------------------------------'; }

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

# Reality 握手带时间戳，时间偏差过大会直接导致连不上
check_clock() {
  command -v timedatectl >/dev/null 2>&1 || return 0
  local synced
  synced=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo '')
  [[ $synced == 'yes' ]] && return 0
  warn '系统时间未与 NTP 同步；Reality 对时间偏差敏感，正在尝试开启时间同步…'
  timedatectl set-ntp true >/dev/null 2>&1 ||
    warn '自动开启失败，请手动校时后再使用（否则可能握手失败）。'
}

has_ipv6() { ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; }

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
valid_host()   { [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && $1 == *.* ]]; }
valid_key()    { [[ $1 =~ ^[A-Za-z0-9_-]{43}$ ]]; }
valid_addr()   { [[ -n $1 && $1 != *[[:space:]]* && ${#1} -le 253 ]]; }
# 节点名允许中文，但禁止空白、引号与反斜杠，避免破坏 JSON 与分享链接
valid_label()  { [[ -n $1 && ${#1} -le 32 && $1 != *[$'\t\n\r "\\']* ]]; }

port_in_use() {
  command -v ss >/dev/null 2>&1 || return 1
  ss -Hltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$1\$"
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

# 检查偷取目标是否满足 Reality 要求：TLS1.3 + HTTP/2
check_dest() { # check_dest <host> [port]
  local host=$1 port=${2:-443} out=''
  openssl_has_tls13 || return 4
  out=$(run_timeout 10 openssl s_client -connect "${host}:${port}" -servername "$host" \
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

get_public_ip() {
  local url ip
  for url in 'https://api.ipify.org' 'https://ipv4.icanhazip.com' 'https://ifconfig.me/ip'; do
    ip=$(curl -fsS4 --max-time 6 "$url" 2>/dev/null | tr -d '[:space:]') || ip=''
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { printf '%s' "$ip"; return 0; }
  done
  for url in 'https://api6.ipify.org' 'https://ipv6.icanhazip.com'; do
    ip=$(curl -fsS6 --max-time 6 "$url" 2>/dev/null | tr -d '[:space:]') || ip=''
    [[ $ip == *:* ]] && { printf '%s' "$ip"; return 0; }
  done
  return 1
}

#============================= 元数据存取 =============================#

PORT=''; DEST=''; SNI=''; PRIVATE_KEY=''; PUBLIC_KEY=''
SHORT_IDS=''; NODE_HOST=''; BLOCK_BT='1'; BLOCK_ADS='0'
HOST_CACHE=''

save_meta() {
  install -d -m 700 "$DATA_DIR"
  umask 077
  cat >"$META_FILE" <<EOF
# 由 ${SCRIPT_NAME} 生成，请勿手工编辑
PORT='${PORT}'
DEST='${DEST}'
SNI='${SNI}'
PRIVATE_KEY='${PRIVATE_KEY}'
PUBLIC_KEY='${PUBLIC_KEY}'
SHORT_IDS='${SHORT_IDS}'
NODE_HOST='${NODE_HOST}'
BLOCK_BT='${BLOCK_BT}'
BLOCK_ADS='${BLOCK_ADS}'
EOF
  chmod 600 "$META_FILE"
}

load_meta() {
  [[ -r $META_FILE ]] || return 1
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

render_config() {
  local strategy='UseIP'
  has_ipv6 || strategy='UseIPv4'

  cat <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "none",
    "error": "/var/log/xray/error.log"
  },
  "dns": {
    "servers": ["1.1.1.1", "8.8.8.8", "localhost"],
    "queryStrategy": "${strategy}"
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
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

# 配置中的 error 日志指向 /var/log/xray，缺失时 Xray 连自检都无法通过
ensure_log_dir() {
  local u g
  install -d -m 755 /var/log/xray 2>/dev/null || return 0
  u=$(service_user)
  g=$(id -gn "$u" 2>/dev/null || printf '%s' "$u")
  chown "$u:$g" /var/log/xray 2>/dev/null || true
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

firewall_allow() {
  local port=$1
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "${port}/tcp" >/dev/null 2>&1 && info "ufw 已放行 ${port}/tcp"
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 &&
      firewall-cmd --reload >/dev/null 2>&1 &&
      info "firewalld 已放行 ${port}/tcp"
  fi
  return 0
}

firewall_revoke() {
  local port=$1
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  return 0
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

show_node() { # show_node <uuid> <label> [--qr]
  local link; link=$(share_link "$1" "$2")
  hr
  printf ' %s节点：%s%s\n' "$C_BOLD" "$2" "$C_OFF"
  hr
  printf '  地址 (address)   : %s\n' "$(link_host)"
  printf '  端口 (port)      : %s\n' "$PORT"
  printf '  用户 ID (uuid)   : %s\n' "$1"
  printf '  流控 (flow)      : xtls-rprx-vision\n'
  printf '  传输 (network)   : tcp\n'
  printf '  安全 (security)  : reality\n'
  printf '  域名 (sni)       : %s\n' "$SNI"
  printf '  公钥 (publicKey) : %s\n' "$PUBLIC_KEY"
  printf '  短 ID (shortId)  : %s\n' "$(first_shortid)"
  printf '  指纹 (fp)        : chrome\n'
  hr
  printf '%s分享链接：%s\n%s\n' "$C_GREEN" "$C_OFF" "$link"
  [[ ${3:-} == '--qr' ]] && print_qr "$link"
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

cmd_install() {
  require_systemd
  detect_os

  if is_installed && ((OPT_FORCE == 0)); then
    warn '检测到已安装。重装请先执行 reality uninstall，或使用 reality install --force 强制重装。'
    return 1
  fi

  printf '\n%s%s v%s%s\n' "$C_BOLD" "$SCRIPT_NAME" "$SCRIPT_VERSION" "$C_OFF"
  printf '系统：%s\n\n' "$OS_PRETTY"

  install_deps
  check_clock
  install_xray_core

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
    valid_host "$OPT_SNI" || die "SNI 格式不正确：${OPT_SNI}"
    warn_dest_risk "$OPT_SNI"
    DEST_HOST=$OPT_SNI
  else
    choose_dest
  fi
  SNI=$DEST_HOST
  DEST=${OPT_DEST:-"${DEST_HOST}:443"}

  # ---- 密钥 ----
  info '生成 Reality 密钥对…'
  gen_keypair || die '密钥生成失败，请确认 Xray 安装完整。'
  SHORT_IDS="$(gen_shortid),$(gen_shortid)"

  # ---- 首个用户 ----
  local uuid label
  uuid=$OPT_UUID
  if [[ -n $uuid ]]; then
    valid_uuid "$uuid" || die "UUID 格式不正确：${uuid}"
  else
    uuid=$(gen_uuid) || die 'UUID 生成失败。'
  fi
  label=${OPT_NAME:-'reality'}
  valid_label "$label" || die "节点名不能含空格、引号或反斜杠，且不超过 32 字符：${label}"

  NODE_HOST=$OPT_HOST
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

cmd_info() {
  require_installed
  local uuid label ver
  ver=$("$XRAY_BIN" version 2>/dev/null | head -n1 | awk '{print $2}')
  printf '\n%s服务状态：%s' "$C_BOLD" "$C_OFF"
  if systemctl is-active --quiet xray; then
    printf '%s运行中%s' "$C_GREEN" "$C_OFF"
  else
    printf '%s已停止%s' "$C_RED" "$C_OFF"
  fi
  printf '    Xray 版本：%s\n' "${ver:-未知}"
  printf '握手目标：%s    用户数：%s\n' "$DEST" "$(users_count)"
  while IFS=$'\t' read -r uuid label || [[ -n ${uuid:-} ]]; do
    [[ -n ${uuid:-} ]] || continue
    show_node "$uuid" "${label:-user}"
  done <"$USERS_FILE"
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
    printf '\n%s%s%s\n' "$C_BOLD" "${label:-user}" "$C_OFF"
    print_qr "$(share_link "$uuid" "${label:-user}")"
  done <"$USERS_FILE"
}

cmd_client() {
  require_installed
  local uuid label
  IFS=$'\t' read -r uuid label <"$USERS_FILE" || true
  [[ -n ${uuid:-} ]] || die '没有可用用户。'
  label=${label:-user}
  hr; printf ' %ssing-box 出站片段%s\n' "$C_BOLD" "$C_OFF"; hr
  print_singbox "$uuid" "$label"
  printf '\n'
  hr; printf ' %sClash.Meta / mihomo 节点片段%s\n' "$C_BOLD" "$C_OFF"; hr
  print_clash "$uuid" "$label"
  printf '\n'
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
  if [[ -z $new ]]; then
    new=$(get_public_ip) || die '自动探测失败，请手动指定。'
  fi
  valid_addr "$new" || die "地址不合法：${new}"
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

cmd_log() {
  info '按 Ctrl+C 退出日志跟踪。'
  journalctl -u xray -n 50 -f --no-pager 2>/dev/null ||
    tail -n 50 -f /var/log/xray/error.log
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

#=============================== 菜单 =================================#

show_menu() {
  local state
  if is_installed; then
    if systemctl is-active --quiet xray; then
      state="${C_GREEN}已安装 · 运行中${C_OFF}"
    else
      state="${C_RED}已安装 · 已停止${C_OFF}"
    fi
  else
    state="${C_YELLOW}未安装${C_OFF}"
  fi

  printf '\n'
  hr
  printf ' %s%s%s  v%s\n' "$C_BOLD" "$SCRIPT_NAME" "$C_OFF" "$SCRIPT_VERSION"
  printf ' 状态：%s\n' "$state"
  hr
  printf '  %s1%s) 安装 / 重装\n'                "$C_GREEN" "$C_OFF"
  printf '  %s2%s) 查看节点信息与二维码\n'       "$C_GREEN" "$C_OFF"
  printf '  %s3%s) 导出 sing-box / Clash 配置\n' "$C_GREEN" "$C_OFF"
  printf '\n'
  printf '  %s4%s) 添加用户\n'                   "$C_GREEN" "$C_OFF"
  printf '  %s5%s) 删除用户\n'                   "$C_GREEN" "$C_OFF"
  printf '  %s6%s) 重新生成全部 UUID\n'          "$C_GREEN" "$C_OFF"
  printf '\n'
  printf '  %s7%s) 修改监听端口\n'               "$C_GREEN" "$C_OFF"
  printf '  %s8%s) 更换偷取目标 (SNI)\n'         "$C_GREEN" "$C_OFF"
  printf '  %s9%s) 修改分享地址（IP / 域名）\n'  "$C_GREEN" "$C_OFF"
  printf ' %s10%s) 更换 Reality 密钥对\n'        "$C_GREEN" "$C_OFF"
  printf ' %s11%s) 路由拦截规则\n'               "$C_GREEN" "$C_OFF"
  printf '\n'
  printf ' %s12%s) 服务管理（启动 / 停止 / 重启 / 状态）\n' "$C_GREEN" "$C_OFF"
  printf ' %s13%s) 查看实时日志\n'               "$C_GREEN" "$C_OFF"
  printf ' %s14%s) 更新 Xray-core\n'             "$C_GREEN" "$C_OFF"
  printf ' %s15%s) 自动更新开关（当前：%s）\n'   "$C_GREEN" "$C_OFF" "$(autoupdate_state)"
  printf ' %s16%s) 开启 BBR 加速\n'              "$C_GREEN" "$C_OFF"
  printf ' %s17%s) 卸载\n'                       "$C_RED"   "$C_OFF"
  printf '  %s0%s) 退出\n'                       "$C_GREEN" "$C_OFF"
  hr
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
