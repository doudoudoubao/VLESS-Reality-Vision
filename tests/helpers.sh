# shellcheck shell=bash
# 测试公用：断言函数、下载 Xray、把 install.sh 改造成可测形态。
# 由 unit.sh / e2e.sh source，不单独执行。

# shellcheck disable=SC2034  # 供 source 本文件的测试脚本使用
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/reality-test.XXXXXX")
XRAY_DIR=${XRAY_TEST_DIR:-${TMPDIR:-/tmp}/reality-test-xray}

pass=0
fail=0

# 计数必须写成 x=$((x + 1))：((x++)) 在 x 为 0 时退出码为 1，
# 会让 `cmd && ok_ || bad_` 两个分支都触发
ok_()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad_() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
yes_() { if eval "$2" >/dev/null 2>&1; then ok_ "$1"; else bad_ "$1"; fi; }
no_()  { if eval "$2" >/dev/null 2>&1; then bad_ "$1（本应拒绝）"; else ok_ "$1"; fi; }
eq_()  { if [[ $2 == "$3" ]]; then ok_ "$1"; else bad_ "$1: 期望[$3] 实际[$2]"; fi; }
group() { printf '\n== %s ==\n' "$1"; }   # 不能叫 section：install.sh 里已有同名函数

summary() {
  printf '\n通过 %d 项，失败 %d 项\n' "$pass" "$fail"
  [[ $fail -eq 0 ]]
}

# 默认用最新版 Xray——脚本线上装的就是最新版，测试应与之一致；
# 需要复现某次结果时用 XRAY_TEST_VERSION=v26.3.27 固定版本
setup_xray() {
  if [[ ! -x $XRAY_DIR/xray ]]; then
    local url='https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip'
    [[ -n ${XRAY_TEST_VERSION:-} ]] &&
      url="https://github.com/XTLS/Xray-core/releases/download/${XRAY_TEST_VERSION}/Xray-linux-64.zip"
    mkdir -p "$XRAY_DIR"
    curl -fsSL --retry 3 -o "$XRAY_DIR/xray.zip" "$url" ||
      { echo "下载 Xray 失败：$url" >&2; exit 1; }
    unzip -oq "$XRAY_DIR/xray.zip" xray geoip.dat geosite.dat -d "$XRAY_DIR"
    chmod +x "$XRAY_DIR/xray"
  fi
  printf '使用 %s\n' "$("$XRAY_DIR/xray" version | head -n1)"
}

# install.sh 的系统路径是 readonly，改写到临时目录后才能当库 source。
# 日志也要改：run -test 会初始化日志组件，非 root 写不了 /var/log
make_lib() { # make_lib <源脚本> <输出>
  mkdir -p "$WORK/etc/reality" "$WORK/log"
  sed -e "s#^readonly XRAY_CONF_DIR=.*#readonly XRAY_CONF_DIR='$WORK/etc'#" \
      -e "s#^readonly DATA_DIR=.*#readonly DATA_DIR='$WORK/etc/reality'#" \
      -e "s#^readonly XRAY_LOG=.*#readonly XRAY_LOG='$WORK/log/error.log'#" \
      -e "s#^readonly XRAY_BIN=.*#readonly XRAY_BIN='$XRAY_DIR/xray'#" "$1" >"$2"
}

# 官方安装脚本要访问 api.github.com（开发沙箱会拦截），
# 打桩成直接放二进制，其余全部走真实代码
make_stub() { # make_stub <源脚本> <输出>
  awk -v bin="$XRAY_DIR/xray" '
    /^install_xray_core\(\) \{/ {
      print "install_xray_core() {"
      print "  install -m 755 \"" bin "\" /usr/local/bin/xray"
      skip = 1; next
    }
    skip && /^\}/ { skip = 0 }
    skip { next }
    { print }' "$1" >"$2"
}

# 容器里通常没有 systemd。is-active 只在二进制真能跑起来时返回 0，
# 这样才测得出「新版本起不来 → 自动回滚」这条路径
mock_systemd() {
  mkdir -p "$WORK/bin" /run/systemd/system
  cat >"$WORK/bin/systemctl" <<'EOF'
#!/bin/bash
case "$*" in
  *"show -p User --value xray"*) echo nobody; exit 0 ;;
  *"is-active"*) /usr/local/bin/xray version >/dev/null 2>&1 && exit 0 || exit 3 ;;
esac
exit 0
EOF
  printf '#!/bin/bash\nexit 0\n' >"$WORK/bin/journalctl"
  chmod +x "$WORK/bin/systemctl" "$WORK/bin/journalctl"
  export PATH="$WORK/bin:$PATH"
}
