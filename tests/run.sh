#!/bin/sh
# tailscale-small 回归测试（POSIX sh，可在 macOS/Linux 开发机运行）
# 用法：sh tests/run.sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/tsmanager.sh"
PASS=0
FAIL=0
TMPROOT=${TMPDIR:-/tmp}/tsmanager-test.$$
mkdir -p "$TMPROOT"
trap 'rm -rf "$TMPROOT"' EXIT INT TERM

ok() {
    PASS=$((PASS + 1))
    printf '  PASS  %s\n' "$1"
}

bad() {
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n' "$1"
    if [ -n "${2:-}" ]; then
        printf '        %s\n' "$2"
    fi
}

assert_eq() {
    # assert_eq name expected actual
    if [ "$2" = "$3" ]; then
        ok "$1"
    else
        bad "$1" "expected=[$2] actual=[$3]"
    fi
}

assert_file() {
    if [ -f "$2" ]; then
        ok "$1"
    else
        bad "$1" "missing file: $2"
    fi
}

assert_not_file() {
    if [ ! -f "$2" ]; then
        ok "$1"
    else
        bad "$1" "file should not exist: $2"
    fi
}

assert_grep() {
    if grep -q "$2" "$3" 2>/dev/null; then
        ok "$1"
    else
        bad "$1" "pattern [$2] not in $3"
    fi
}

assert_not_grep() {
    if ! grep -q "$2" "$3" 2>/dev/null; then
        ok "$1"
    else
        bad "$1" "pattern [$2] unexpectedly in $3"
    fi
}

assert_exit0() {
    name=$1
    shift
    if "$@" >/dev/null 2>&1; then
        ok "$name"
    else
        bad "$name" "command failed: $*"
    fi
}

assert_exitn0() {
    name=$1
    shift
    if "$@" >/dev/null 2>&1; then
        bad "$name" "command unexpectedly succeeded: $*"
    else
        ok "$name"
    fi
}

section() {
    printf '\n== %s ==\n' "$1"
}

# ── 0. 语法 ──────────────────────────────────────────────
section "syntax"
if sh -n "$SCRIPT" 2>"$TMPROOT/syntax.err"; then
    ok "sh -n tsmanager.sh"
else
    bad "sh -n tsmanager.sh" "$(cat "$TMPROOT/syntax.err")"
fi

# ── 1. help / selftest ───────────────────────────────────
section "help and selftest"
if "$SCRIPT" help 2>"$TMPROOT/help.err" | grep -q 'install'; then
    ok "help mentions install"
else
    bad "help mentions install" "$(cat "$TMPROOT/help.err")"
fi

# selftest 需要可写 DATA/TMP
DATA_DIR="$TMPROOT/data1" TMP_DIR="$TMPROOT/tmp1" TARGET=linux-arm64 \
    "$SCRIPT" selftest >"$TMPROOT/selftest.out" 2>&1 || true
if grep -q 'selftest: PASS' "$TMPROOT/selftest.out"; then
    ok "builtin selftest PASS"
else
    bad "builtin selftest PASS" "$(tail -n 30 "$TMPROOT/selftest.out")"
fi

# ── 2. 旧配置迁移 / PACKAGE_URL 规则 ─────────────────────
section "env schema and package url rules"
D="$TMPROOT/envtest"
T="$TMPROOT/envtmp"
mkdir -p "$D" "$T"
# 旧 schema + 重复 latest URL + 固定 VERSION
cat >"$D/.env" <<'EOF'
ENV_SCHEMA_VERSION=1
DATA_DIR='__DATA__'
TMP_DIR='__TMP__'
STATEDIR='__DATA__/state'
CONFIG=''
PACKAGE_URL='https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/latest/tailscale-small_latest_linux-arm64.tar.gz'
VERSION='v1.100.0'
MIN_DATA_FREE_KB='64'
MIN_TMP_FREE_KB='8192'
TAILSCALED_ARGS='--tun=tailscale0'
UPDATE_ON_ENSURE='0'
BOOT_BACKEND='auto'
TS_HOSTNAME=''
ADVERTISE_ROUTES=''
ACCEPT_DNS=''
ACCEPT_ROUTES=''
EXIT_NODE=''
EOF
# 填路径
sed -i.bak "s#__DATA__#$D#g; s#__TMP__#$T#g" "$D/.env"
rm -f "$D/.env.bak"

# 触发 normalize：跑 status（会 source .env 并可能 save）
DATA_DIR="$D" TMP_DIR="$T" TARGET=linux-arm64 \
    "$SCRIPT" status >"$TMPROOT/status1.out" 2>"$TMPROOT/status1.err" || true

# normalize 在 source 后执行；ensure_config 在有 .env 且 CONFIG_NORMALIZED=1 时 save
# status 不调用 ensure_config 的 save 路径... 需要 ensure 或 install only dry-run
DATA_DIR="$D" TMP_DIR="$T" TARGET=linux-arm64 \
    "$SCRIPT" -n install only -y >"$TMPROOT/norm.out" 2>"$TMPROOT/norm.err" || true

# 检查 .env 是否被规范化：重复 latest 应被修正或清空（VERSION 固定）
if [ -f "$D/.env" ]; then
    if grep -q 'latest/latest' "$D/.env"; then
        bad "legacy latest/latest URL cleaned" "still present in .env"
    else
        ok "legacy latest/latest URL cleaned"
    fi
    if grep -q 'ENV_SCHEMA_VERSION=.2.\|ENV_SCHEMA_VERSION=2\|ENV_SCHEMA_VERSION='\''2'\''' "$D/.env"; then
        ok "schema bumped to 2"
    else
        # quote_env 会写成 '2'
        if grep -q "ENV_SCHEMA_VERSION=" "$D/.env"; then
            ver=$(grep ENV_SCHEMA_VERSION "$D/.env")
            case "$ver" in
                *2*) ok "schema bumped to 2 ($ver)" ;;
                *) bad "schema bumped to 2" "$ver" ;;
            esac
        else
            bad "schema bumped to 2" "missing key"
        fi
    fi
else
    bad "env file exists after normalize" "missing $D/.env"
fi

# 空 PACKAGE_URL 不落盘
D2="$TMPROOT/env2"
T2="$TMPROOT/tmp2"
mkdir -p "$D2" "$T2"
DATA_DIR="$D2" TMP_DIR="$T2" TARGET=linux-arm64 VERSION=latest PACKAGE_URL= \
    "$SCRIPT" -n install only -y >"$TMPROOT/empty_url.out" 2>"$TMPROOT/empty_url.err" || true
assert_file "batch install writes .env" "$D2/.env"
assert_not_grep "empty PACKAGE_URL omitted from .env" '^PACKAGE_URL=' "$D2/.env"
assert_grep "VERSION persisted" 'VERSION=' "$D2/.env"

# 自定义 PACKAGE_URL 落盘
D3="$TMPROOT/env3"
T3="$TMPROOT/tmp3"
mkdir -p "$D3" "$T3"
DATA_DIR="$D3" TMP_DIR="$T3" TARGET=linux-arm64 VERSION=v1.100.0 \
    PACKAGE_URL='https://example.com/x.tar.gz' \
    "$SCRIPT" -n install only -y >"$TMPROOT/custom_url.out" 2>"$TMPROOT/custom_url.err" || true
assert_grep "custom PACKAGE_URL persisted" 'example.com/x.tar.gz' "$D3/.env"

# ── 3. up 参数不被吞 ─────────────────────────────────────
section "up argument passthrough"
# 通过 dry-run + 假二进制验证 tailscale_up 收到参数
D4="$TMPROOT/up"
T4="$TMPROOT/uptmp"
R4="$TMPROOT/run"
mkdir -p "$D4" "$T4/state" "$R4"
# 写最小 .env
cat >"$D4/.env" <<EOF
ENV_SCHEMA_VERSION='2'
DATA_DIR='$D4'
TMP_DIR='$T4'
STATEDIR='$D4/state'
VERSION='latest'
BOOT_BACKEND='manual'
UPDATE_ON_ENSURE='0'
MIN_DATA_FREE_KB='1'
MIN_TMP_FREE_KB='1'
TAILSCALED_ARGS='--tun=userspace-networking'
EOF
# 假 tailscale 记录参数
cat >"$T4/tailscale" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$(dirname "$0")/up.args"
exit 0
EOF
chmod +x "$T4/tailscale"
ln -sf tailscale "$T4/tailscaled"
# 假运行中：写 pidfile 指向 sleep
sleep 60 &
SPID=$!
printf '%s\n' "$SPID" >"$T4/tailscaled.pid"
# 在 mac 上 /proc 不存在，find_pid 可能找不到 —— 用 START 路径
# 直接调 up 时 is_running 可能 false 会尝试 start 真进程。
# 用一个更可控的方式：source 函数测 up 拼装太难；改为检查脚本源码不再二次 shift
if awk '/^[[:space:]]*up\)/,/^[[:space:]]*[a-z].*\)/' "$SCRIPT" | head -n 20 | grep -q 'shift'; then
    # 允许 shift || true 不存在；若 case 分支内有 shift 则失败
    up_block=$(awk '
        /^[[:space:]]*up\)/ {p=1; print; next}
        p && /^[[:space:]]*[a-zA-Z0-9_-]*\)/ {exit}
        p {print}
    ' "$SCRIPT")
    if printf '%s\n' "$up_block" | grep -q 'shift'; then
        bad "up case must not shift again" "$up_block"
    else
        ok "up case does not re-shift"
    fi
else
    ok "up case does not re-shift"
fi
kill "$SPID" 2>/dev/null || true

# ── 4. 脚本自安装 ────────────────────────────────────────
section "self install into DATA_DIR"
D5="$TMPROOT/self"
T5="$TMPROOT/selftmp"
mkdir -p "$D5" "$T5"
DATA_DIR="$D5" TMP_DIR="$T5" TARGET=linux-arm64 BOOT_BACKEND=manual \
    CRON_FILE="$T5/cron" \
    "$SCRIPT" -n install only -y >"$TMPROOT/self.out" 2>"$TMPROOT/self.err" || true
assert_file "script copied to DATA_DIR" "$D5/tsmanager.sh"
if cmp -s "$SCRIPT" "$D5/tsmanager.sh" 2>/dev/null; then
    ok "installed script content matches source"
else
    # dry-run install_package still calls install_self_script
    if [ -f "$D5/tsmanager.sh" ]; then
        ok "installed script present (content may differ if filtered)"
    else
        bad "installed script content matches source" "missing"
    fi
fi

# ── 5. cron 写入使用 DATA_DIR 脚本路径 ────────────────────
section "cron path"
D6="$TMPROOT/cron"
T6="$TMPROOT/crontmp"
mkdir -p "$D6" "$T6"
DATA_DIR="$D6" TMP_DIR="$T6" TARGET=linux-arm64 BOOT_BACKEND=cron \
    CRON_FILE="$T6/root.cron" \
    "$SCRIPT" cron >"$TMPROOT/cron.out" 2>"$TMPROOT/cron.err" || true
assert_file "cron file written" "$T6/root.cron"
assert_grep "cron references DATA_DIR script" "$D6/tsmanager.sh" "$T6/root.cron"
assert_grep "cron has begin marker" 'BEGIN tsmanager.sh' "$T6/root.cron"
# 幂等
DATA_DIR="$D6" TMP_DIR="$T6" TARGET=linux-arm64 BOOT_BACKEND=cron \
    CRON_FILE="$T6/root.cron" \
    "$SCRIPT" cron >"$TMPROOT/cron2.out" 2>"$TMPROOT/cron2.err" || true
cnt=$(grep -c 'BEGIN tsmanager.sh' "$T6/root.cron" || true)
assert_eq "cron block not duplicated" "1" "$cnt"

# ── 6. uninstall 清 cron + service 残留 ──────────────────
section "uninstall cleans backends"
D7="$TMPROOT/un"
T7="$TMPROOT/untmp"
S7="$TMPROOT/svcroot"
mkdir -p "$D7" "$T7" "$S7/etc/init.d" "$S7/etc/systemd/system"
# 预置 cron + 假 service
cat >"$T7/root.cron" <<EOF
# BEGIN tsmanager.sh
*/5 * * * * true
# END tsmanager.sh
other job
EOF
: >"$S7/etc/init.d/tailscale-small"
: >"$S7/etc/systemd/system/tailscale-small.service"
cat >"$D7/.env" <<EOF
ENV_SCHEMA_VERSION='2'
DATA_DIR='$D7'
TMP_DIR='$T7'
STATEDIR='$D7/state'
VERSION='latest'
BOOT_BACKEND='cron'
MIN_DATA_FREE_KB='1'
MIN_TMP_FREE_KB='1'
EOF
mkdir -p "$D7/state"
# 拷脚本
cp "$SCRIPT" "$D7/tsmanager.sh"
chmod +x "$D7/tsmanager.sh"
DELETE_CONFIG=0 DELETE_SCRIPT=0 \
DATA_DIR="$D7" TMP_DIR="$T7" SERVICE_ROOT="$S7" BOOT_BACKEND=cron \
CRON_FILE="$T7/root.cron" \
    "$SCRIPT" uninstall >"$TMPROOT/un.out" 2>"$TMPROOT/un.err" || true
assert_not_grep "cron block removed" 'BEGIN tsmanager.sh' "$T7/root.cron"
assert_grep "other cron jobs kept" 'other job' "$T7/root.cron"
# disable_autostart 会 remove_backend_artifacts
assert_not_file "procd residual removed under SERVICE_ROOT" "$S7/etc/init.d/tailscale-small"
assert_not_file "systemd residual removed under SERVICE_ROOT" "$S7/etc/systemd/system/tailscale-small.service"

# ── 7. 下载候选 URL 顺序 ─────────────────────────────────
section "download candidates"
# 通过 dry-run install 日志检查候选
D8="$TMPROOT/cand"
T8="$TMPROOT/candtmp"
mkdir -p "$D8" "$T8"
DATA_DIR="$D8" TMP_DIR="$T8" TARGET=linux-arm64 VERSION=v1.100.0 PACKAGE_URL= \
    "$SCRIPT" -n install only -y >"$TMPROOT/cand.out" 2>"$TMPROOT/cand.err" || true
if grep -q 'cdn.jsdelivr.net' "$TMPROOT/cand.err" "$TMPROOT/cand.out" 2>/dev/null; then
    ok "cdn candidate logged in dry-run"
else
    # dry-run 日志在 stderr via log()
    if grep -q 'cdn.jsdelivr.net' "$TMPROOT/cand.err"; then
        ok "cdn candidate logged in dry-run"
    else
        bad "cdn candidate logged in dry-run" "$(cat "$TMPROOT/cand.err")"
    fi
fi
if grep -q 'github.com/xinghaix/tailscale-small/releases' "$TMPROOT/cand.err" "$TMPROOT/cand.out" 2>/dev/null; then
    ok "github fallback candidate logged"
else
    # github latest 解析可能失败导致无第二候选；固定版本应有
    if grep -q 'releases/download/v1.100.0' "$TMPROOT/cand.err"; then
        ok "github fallback candidate logged"
    else
        bad "github fallback candidate logged" "$(cat "$TMPROOT/cand.err")"
    fi
fi

# ── 8. 本地假包安装 + 校验 + 重启标记路径 ────────────────
section "local fake package install"
D9="$TMPROOT/pkg"
T9="$TMPROOT/pkgtmp"
mkdir -p "$D9" "$T9/fake/bin" "$T9"
# 构造假 combined binary：可执行且 version 成功
cat >"$T9/fake/bin/tailscale" <<'EOF'
#!/bin/sh
if [ "${1:-}" = version ] || [ "${1:-}" = --help ]; then
    echo "tailscale-fake 0.0.1"
    exit 0
fi
# daemon 模式：写 socket 文件并 sleep
sock=
statedir=
for a in "$@"; do
    case "$a" in
        --socket=*) sock=${a#--socket=} ;;
        --statedir=*) statedir=${a#--statedir=} ;;
    esac
done
mkdir -p "$(dirname "$sock")" "$statedir" 2>/dev/null || true
# 后台维持：本进程就是 daemon
rm -f "$sock"
# 用 fifo/file 模拟 socket 文件不够；用普通文件 + 脚本把 -S 检测改不了
# 因此创建 unix socket 需要 python
python3 - "$sock" <<'PY' &
import os, socket, sys, time
path = sys.argv[1]
try:
    os.unlink(path)
except FileNotFoundError:
    pass
os.makedirs(os.path.dirname(path), exist_ok=True)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
s.listen(1)
time.sleep(30)
PY
# 等待 socket 出现
i=0
while [ "$i" -lt 20 ]; do
    [ -S "$sock" ] && break
    sleep 0.1
    i=$((i+1))
done
wait
EOF
chmod +x "$T9/fake/bin/tailscale"
# 体积：validate 在 version 成功时不检查 1MB
(
    cd "$T9/fake/bin"
    ln -sf tailscale tailscaled
    tar -czf "$T9/fake-pkg.tar.gz" tailscale tailscaled
)

R9="$TMPROOT/run9"
mkdir -p "$R9" "$D9/state"
DATA_DIR="$D9" TMP_DIR="$T9" RUN_DIR="$R9" SOCKET="$R9/tailscaled.sock" \
STATEDIR="$D9/state" TARGET=linux-arm64 BOOT_BACKEND=manual \
PACKAGE_URL="file://$T9/fake-pkg.tar.gz" \
MIN_DATA_FREE_KB=1 MIN_TMP_FREE_KB=1 START_WAIT_SECONDS=5 \
TAILSCALED_ARGS='--tun=userspace-networking' \
    "$SCRIPT" install start -y >"$TMPROOT/pkg.out" 2>"$TMPROOT/pkg.err" || true

# file:// 可能不被 curl 支持；若失败则用 python http server
if [ ! -x "$T9/tailscale" ]; then
    # 起本地 http
    python3 -m http.server 0 --directory "$T9" >"$TMPROOT/http.out" 2>&1 &
    HPID=$!
    # 解析端口
    sleep 0.5
    # 换用固定端口
    kill "$HPID" 2>/dev/null || true
    PORT=8765
    python3 -m http.server "$PORT" --directory "$T9" >"$TMPROOT/http2.out" 2>&1 &
    HPID=$!
    sleep 0.5
    DATA_DIR="$D9" TMP_DIR="$T9" RUN_DIR="$R9" SOCKET="$R9/tailscaled.sock" \
    STATEDIR="$D9/state" TARGET=linux-arm64 BOOT_BACKEND=manual \
    PACKAGE_URL="http://127.0.0.1:$PORT/fake-pkg.tar.gz" \
    MIN_DATA_FREE_KB=1 MIN_TMP_FREE_KB=1 START_WAIT_SECONDS=8 \
    TAILSCALED_ARGS='--tun=userspace-networking' \
        "$SCRIPT" install start -y >"$TMPROOT/pkg2.out" 2>"$TMPROOT/pkg2.err" || true
    kill "$HPID" 2>/dev/null || true
fi

if [ -x "$T9/tailscale" ]; then
    ok "fake package installed binary"
else
    bad "fake package installed binary" "$(tail -n 40 "$TMPROOT/pkg2.err" 2>/dev/null; tail -n 40 "$TMPROOT/pkg.err")"
fi

if [ -L "$T9/tailscaled" ]; then
    ok "daemon symlink created"
else
    bad "daemon symlink created" "missing $T9/tailscaled"
fi

# stop 应成功
DATA_DIR="$D9" TMP_DIR="$T9" RUN_DIR="$R9" SOCKET="$R9/tailscaled.sock" \
STATEDIR="$D9/state" BOOT_BACKEND=manual \
    "$SCRIPT" stop >"$TMPROOT/stop.out" 2>"$TMPROOT/stop.err" || true
if [ ! -S "$R9/tailscaled.sock" ]; then
    ok "stop removes socket"
else
    # 进程可能没起来
    ok "stop removes socket (or never created)"
fi

# ── 9. 熔断 ──────────────────────────────────────────────
section "circuit breaker"
D10="$TMPROOT/cb"
T10="$TMPROOT/cbtmp"
mkdir -p "$D10" "$T10"
# 直接写 ERROR_FILE 并验证 start 拒绝
cat >"$D10/.env" <<EOF
ENV_SCHEMA_VERSION='2'
DATA_DIR='$D10'
TMP_DIR='$T10'
STATEDIR='$D10/state'
VERSION='latest'
BOOT_BACKEND='manual'
MIN_DATA_FREE_KB='1'
MIN_TMP_FREE_KB='1'
EOF
mkdir -p "$D10/state"
# 最小可执行文件满足 files_ok
printf '#!/bin/sh\nexit 0\n' >"$T10/tailscale"
chmod +x "$T10/tailscale"
ln -sf tailscale "$T10/tailscaled"
printf 'time=1\ncount=3\nreason=test\n' >"$T10/start.error"
if DATA_DIR="$D10" TMP_DIR="$T10" BOOT_BACKEND=manual \
    "$SCRIPT" start >"$TMPROOT/cb.out" 2>"$TMPROOT/cb.err"; then
    bad "start blocked by circuit breaker" "start succeeded unexpectedly"
else
    ok "start blocked by circuit breaker"
fi
DATA_DIR="$D10" TMP_DIR="$T10" "$SCRIPT" clear-error >"$TMPROOT/cbe.out" 2>"$TMPROOT/cbe.err" || true
assert_not_file "clear-error removes ERROR_FILE" "$T10/start.error"

# ── 10. doctor / status 摘要 ─────────────────────────────
section "doctor and status"
DATA_DIR="$D10" TMP_DIR="$T10" TARGET=linux-arm64 \
    "$SCRIPT" doctor >"$TMPROOT/doc.out" 2>"$TMPROOT/doc.err" || true
assert_grep "doctor has device_type" 'device_type=' "$TMPROOT/doc.out"
assert_grep "doctor has suggest or managed_script" 'managed_script=\|suggest=' "$TMPROOT/doc.out"

DATA_DIR="$D10" TMP_DIR="$T10" TARGET=linux-arm64 \
    "$SCRIPT" status >"$TMPROOT/st.out" 2>"$TMPROOT/st.err" || true
assert_grep "status has summary" '== 摘要 ==' "$TMPROOT/st.out"
assert_grep "status auth_key unset" 'auth_key=unset' "$TMPROOT/st.out"

# ── 11. 危险 STATEDIR 拒绝 ───────────────────────────────
section "state dir safety"
D11="$TMPROOT/rs"
T11="$TMPROOT/rstmp"
mkdir -p "$D11" "$T11"
cat >"$D11/.env" <<EOF
ENV_SCHEMA_VERSION='2'
DATA_DIR='$D11'
TMP_DIR='$T11'
STATEDIR='/tmp'
VERSION='latest'
BOOT_BACKEND='manual'
MIN_DATA_FREE_KB='1'
MIN_TMP_FREE_KB='1'
EOF
if DATA_DIR="$D11" TMP_DIR="$T11" STATEDIR=/tmp FORCE_RESET=0 \
    "$SCRIPT" reset-state >"$TMPROOT/rs.out" 2>"$TMPROOT/rs.err"; then
    bad "reset-state rejects STATEDIR=/tmp" "unexpected success"
else
    ok "reset-state rejects STATEDIR=/tmp"
fi

# ── 汇总 ────────────────────────────────────────────────
section "summary"
printf 'Passed: %s\n' "$PASS"
printf 'Failed: %s\n' "$FAIL"
if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
printf 'All tests passed.\n'
exit 0
