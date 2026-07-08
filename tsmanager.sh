#!/bin/sh
# 路由器用 Tailscale 极简管理脚本。
# 兼容 POSIX sh / BusyBox sh。
#
# 目录策略：
#   /data/tailscale/tsmanager.sh           持久脚本
#   /data/tailscale/.env                   持久配置（仅保存用户显式配置，自动推导项不写入）
#   /data/tailscale/state/                 持久状态目录
#   /tmp/tailscale/tailscale               大体积二进制
#   /tmp/tailscale/tailscaled -> tailscale daemon 入口软链
#   /tmp/tailscale/tailscaled.pid          进程号
#   /tmp/tailscale/tailscaled.log          守护进程日志
#   /tmp/tailscale/manager.log             定时任务日志
#   /var/run/tailscale/tailscaled.sock     本地控制 socket
#
# 交互模式（默认）：
#   终端下运行 sh tsmanager.sh install，脚本会逐项询问，按回车取默认值。
#   POSIX sh 不支持方向键/光标移动，输入错误时用 Backspace 删除后重新输入即可。
#
# 非交互模式（适用于脚本/自动化）：
#   提前设置好环境变量，再加 -y 跳过所有提示：
#     DATA_DIR=/data/tailscale TMP_DIR=/tmp/tailscale \
#       VERSION=v1.100.0 sh tsmanager.sh install -y
#
# 默认下载：自动检测当前 Linux CPU 架构，从 jsDelivr CDN 下载匹配的
# tailscale-small_<version>_<target>.tar.gz。路由器环境不要求 sha/checksum 工具。
# 支持固定版本（如 v1.100.0），默认使用 latest。

set -eu

DEFAULT_CDN_BASE=https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn
CDN_BASE=$DEFAULT_CDN_BASE
GITHUB_API=https://api.github.com/repos/xinghaix/tailscale-small/releases
CONFIG_NORMALIZED=0
SCRIPT_ENV_SCHEMA_VERSION=2
LOCK_HELD=0

SCRIPT_NAME=tsmanager.sh
USER_BOOT_BACKEND_SET=${BOOT_BACKEND+x}
USER_BOOT_BACKEND_VALUE=${BOOT_BACKEND:-}
USER_SERVICE_ROOT_SET=${SERVICE_ROOT+x}
USER_SERVICE_ROOT_VALUE=${SERVICE_ROOT:-}
USER_CRON_FILE_SET=${CRON_FILE+x}
USER_CRON_FILE_VALUE=${CRON_FILE:-}
USER_PACKAGE_URL_SET=${PACKAGE_URL+x}
USER_PACKAGE_URL_VALUE=${PACKAGE_URL:-}
USER_TS_HOSTNAME_SET=${TS_HOSTNAME+x}
USER_TS_HOSTNAME_VALUE=${TS_HOSTNAME:-}

DATA_DIR=${DATA_DIR:-/data/tailscale}
ENV_FILE=${ENV_FILE:-$DATA_DIR/.env}
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
fi

DATA_DIR=${DATA_DIR:-/data/tailscale}
ENV_FILE=${ENV_FILE:-$DATA_DIR/.env}
CDN_BASE=$DEFAULT_CDN_BASE
TMP_DIR=${TMP_DIR:-/tmp/tailscale}
RUN_DIR=${RUN_DIR:-}
SOCKET=${SOCKET:-}
if [ -z "$RUN_DIR" ] && [ -n "$SOCKET" ]; then
    RUN_DIR=$(dirname "$SOCKET")
fi
RUN_DIR=${RUN_DIR:-/var/run/tailscale}
SOCKET=${SOCKET:-$RUN_DIR/tailscaled.sock}
BIN=${BIN:-$TMP_DIR/tailscale}
CLI=${CLI:-$BIN}
DAEMON=${DAEMON:-$TMP_DIR/tailscaled}
STATEDIR=${STATEDIR:-$DATA_DIR/state}
CONFIG=${CONFIG:-}
PIDFILE=${PIDFILE:-$TMP_DIR/tailscaled.pid}
LOGFILE=${LOGFILE:-$TMP_DIR/tailscaled.log}
TARGET=${TARGET:-}
PACKAGE_URL=${PACKAGE_URL:-}
VERSION=${VERSION:-latest}
ENV_SCHEMA_VERSION=${ENV_SCHEMA_VERSION:-$SCRIPT_ENV_SCHEMA_VERSION}
MIN_DATA_FREE_KB=${MIN_DATA_FREE_KB:-64}
MIN_TMP_FREE_KB=${MIN_TMP_FREE_KB:-8192}
TAILSCALED_ARGS=${TAILSCALED_ARGS:---tun=tailscale0}
UPDATE_ON_ENSURE=${UPDATE_ON_ENSURE:-0}
START_FAIL_LIMIT=${START_FAIL_LIMIT:-3}
START_FAIL_WINDOW=${START_FAIL_WINDOW:-600}
MANAGER_LOG=${MANAGER_LOG:-$TMP_DIR/manager.log}
LOCKDIR=${LOCKDIR:-$TMP_DIR/tsmanager.lock}
LOCKPIDFILE=${LOCKPIDFILE:-$LOCKDIR/pid}
FAILLOG=${FAILLOG:-$TMP_DIR/start.fail}
ERROR_FILE=${ERROR_FILE:-$TMP_DIR/start.error}
BOOT_BACKEND=${BOOT_BACKEND:-auto}
SERVICE_NAME=${SERVICE_NAME:-tailscale-small}
SERVICE_ROOT=${SERVICE_ROOT:-}
TS_HOSTNAME=${TS_HOSTNAME:-}
ADVERTISE_ROUTES=${ADVERTISE_ROUTES:-}
ACCEPT_DNS=${ACCEPT_DNS:-}
ACCEPT_ROUTES=${ACCEPT_ROUTES:-}
EXIT_NODE=${EXIT_NODE:-}
PERSIST_AUTH_KEY=${PERSIST_AUTH_KEY:-0}
AUTH_KEY=${AUTH_KEY:-}
if [ "${USER_BOOT_BACKEND_SET:-}" = x ]; then BOOT_BACKEND=$USER_BOOT_BACKEND_VALUE; fi
if [ "${USER_SERVICE_ROOT_SET:-}" = x ]; then SERVICE_ROOT=$USER_SERVICE_ROOT_VALUE; fi
if [ "${USER_CRON_FILE_SET:-}" = x ]; then CRON_FILE=$USER_CRON_FILE_VALUE; fi
if [ "${USER_PACKAGE_URL_SET:-}" = x ]; then PACKAGE_URL=$USER_PACKAGE_URL_VALUE; fi
if [ "${USER_TS_HOSTNAME_SET:-}" = x ]; then TS_HOSTNAME=$USER_TS_HOSTNAME_VALUE; fi

CRON_BEGIN='# BEGIN tsmanager.sh'
CRON_END='# END tsmanager.sh'

# ────────────────────────────── 工具函数 ──────────────────────────────

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
    log "错误：$*" >&2
    exit 1
}

have() {
    command -v "$1" >/dev/null 2>&1
}

normalize_legacy_config() {
    # 旧版 .env 可能保存过 CDN_BASE=...@cdn/latest，或保存了由它生成的
    # PACKAGE_URL=...@cdn/latest/latest/...。CDN_BASE 现在是脚本内部常量，
    # 这里强制恢复并修正旧 URL，避免重复 latest 导致 404。
    CDN_BASE=$DEFAULT_CDN_BASE
    if [ "$ENV_SCHEMA_VERSION" != "$SCRIPT_ENV_SCHEMA_VERSION" ]; then
        ENV_SCHEMA_VERSION=$SCRIPT_ENV_SCHEMA_VERSION
        CONFIG_NORMALIZED=1
    fi
    if [ -z "$PACKAGE_URL" ] && [ -n "${TS_PACKAGE_URL:-}" ]; then
        PACKAGE_URL=$TS_PACKAGE_URL
        CONFIG_NORMALIZED=1
        log "迁移旧版配置：TS_PACKAGE_URL -> PACKAGE_URL"
    fi
    if [ -n "${TS_CHECKSUM_URL:-}" ]; then
        CONFIG_NORMALIZED=1
        log "忽略旧版校验配置：TS_CHECKSUM_URL"
    fi
    case "${CDN_BASE:-}" in
        *'@cdn/latest')
            CONFIG_NORMALIZED=1
            ;;
    esac
    case "$PACKAGE_URL" in
        *'cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/latest/tailscale-small_latest_'*.tar.gz)
            old_package_url=$PACKAGE_URL
            PACKAGE_URL=$(printf '%s\n' "$PACKAGE_URL" | sed 's#@cdn/latest/latest/#@cdn/latest/#g')
            CONFIG_NORMALIZED=1
            log "修正旧版下载地址：$old_package_url -> $PACKAGE_URL"
            ;;
    esac
}

normalize_legacy_config

make_base_dirs() {
    mkdir -p "$DATA_DIR" "$TMP_DIR" "$STATEDIR"
}

make_run_dir() {
    mkdir -p "$RUN_DIR"
}

free_kb() {
    df -k "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}

check_space() {
    dir=$1
    min_kb=$2
    kb=$(free_kb "$dir" || printf '0')
    case "$kb" in
        ''|*[!0-9]*) kb=0 ;;
    esac
    if [ "$kb" -lt "$min_kb" ]; then
        fail "$dir 剩余空间 ${kb}KB，不足 ${min_kb}KB"
    fi
}

now_epoch() {
    date '+%s' 2>/dev/null || printf '0\n'
}

prune_start_failures() {
    [ -f "$FAILLOG" ] || return 0
    now=$(now_epoch)
    cutoff=$((now - START_FAIL_WINDOW))
    awk -F '\t' -v cutoff="$cutoff" '$1 ~ /^[0-9]+$/ && $1 >= cutoff {print}' "$FAILLOG" >"$FAILLOG.new" 2>/dev/null || :
    mv "$FAILLOG.new" "$FAILLOG"
}

record_start_failure() {
    reason=$1
    mkdir -p "$TMP_DIR"
    ts=$(now_epoch)
    {
        [ -f "$FAILLOG" ] && cat "$FAILLOG"
        printf '%s\t%s\n' "$ts" "$reason"
    } >"$FAILLOG.new"
    mv "$FAILLOG.new" "$FAILLOG"
    prune_start_failures
    count=$(wc -l <"$FAILLOG" | tr -d ' ')
    if [ "$count" -ge "$START_FAIL_LIMIT" ]; then
        {
            printf 'time=%s\n' "$ts"
            printf 'count=%s\n' "$count"
            printf 'window=%s\n' "$START_FAIL_WINDOW"
            printf 'reason=%s\n' "$reason"
        } >"$ERROR_FILE"
        log "tailscaled 启动连续失败 ${count} 次，已进入熔断；请修复后执行 clear-error"
    fi
}

clear_start_state() {
    rm -f "$FAILLOG" "$ERROR_FILE"
}

start_error_active() {
    [ -f "$ERROR_FILE" ]
}

pid_matches_daemon() {
    pid=$1
    [ -n "$pid" ] || return 1
    ps 2>/dev/null | awk -v pid="$pid" '$1 == pid && $0 ~ /tailscale|tailscaled/ {found=1} END {exit !found}'
}

acquire_lock() {
    make_base_dirs
    if mkdir "$LOCKDIR" 2>/dev/null; then
        printf '%s\n' "$$" >"$LOCKPIDFILE"
        LOCK_HELD=1
        return 0
    fi

    stale_pid=''
    if [ -f "$LOCKPIDFILE" ]; then
        stale_pid=$(cat "$LOCKPIDFILE" 2>/dev/null || true)
    fi
    if [ -n "$stale_pid" ] && ! pid_alive "$stale_pid"; then
        rm -f "$LOCKPIDFILE"
        rmdir "$LOCKDIR" 2>/dev/null || true
    elif [ -z "$stale_pid" ]; then
        rmdir "$LOCKDIR" 2>/dev/null || true
    fi

    if mkdir "$LOCKDIR" 2>/dev/null; then
        printf '%s\n' "$$" >"$LOCKPIDFILE"
        LOCK_HELD=1
        return 0
    fi

    fail "已有另一个 tsmanager.sh 实例在运行；如确认异常中断，请删除锁目录：$LOCKDIR"
}

release_lock() {
    if [ "$LOCK_HELD" = 1 ]; then
        rm -f "$LOCKPIDFILE"
        rmdir "$LOCKDIR" 2>/dev/null || true
        LOCK_HELD=0
    fi
}

run_locked() {
    acquire_lock
    trap 'release_lock' EXIT INT TERM
    "$@"
    rc=$?
    trap - EXIT INT TERM
    release_lock
    return "$rc"
}

# ──────────────────────────── .env 持久化 ──────────────────────────────

quote_env() {
    case "$1" in
        '') printf "''" ;;
        *) printf "%s" "$1" | sed "s/'/'\\''/g; 1s/^/'/; \$s/\$/'/" ;;
    esac
}

save_env() {
    make_base_dirs
    tmp="$ENV_FILE.$$"
    {
        echo "# tsmanager.sh 自动生成的配置文件"
        printf 'ENV_SCHEMA_VERSION=%s\n' "$(quote_env "$SCRIPT_ENV_SCHEMA_VERSION")"
        printf 'DATA_DIR=%s\n' "$(quote_env "$DATA_DIR")"
        printf 'TMP_DIR=%s\n' "$(quote_env "$TMP_DIR")"
        printf 'STATEDIR=%s\n' "$(quote_env "$STATEDIR")"
        printf 'CONFIG=%s\n' "$(quote_env "$CONFIG")"
        printf 'PACKAGE_URL=%s\n' "$(quote_env "$PACKAGE_URL")"
        printf 'VERSION=%s\n' "$(quote_env "$VERSION")"
        printf 'MIN_DATA_FREE_KB=%s\n' "$(quote_env "$MIN_DATA_FREE_KB")"
        printf 'MIN_TMP_FREE_KB=%s\n' "$(quote_env "$MIN_TMP_FREE_KB")"
        printf 'TAILSCALED_ARGS=%s\n' "$(quote_env "$TAILSCALED_ARGS")"
        printf 'UPDATE_ON_ENSURE=%s\n' "$(quote_env "$UPDATE_ON_ENSURE")"
        printf 'BOOT_BACKEND=%s\n' "$(quote_env "$BOOT_BACKEND")"
        printf 'TS_HOSTNAME=%s\n' "$(quote_env "$TS_HOSTNAME")"
        printf 'ADVERTISE_ROUTES=%s\n' "$(quote_env "$ADVERTISE_ROUTES")"
        printf 'ACCEPT_DNS=%s\n' "$(quote_env "$ACCEPT_DNS")"
        printf 'ACCEPT_ROUTES=%s\n' "$(quote_env "$ACCEPT_ROUTES")"
        printf 'EXIT_NODE=%s\n' "$(quote_env "$EXIT_NODE")"
        if [ "$PERSIST_AUTH_KEY" = 1 ] && [ -n "$AUTH_KEY" ]; then
            printf 'AUTH_KEY=%s\n' "$(quote_env "$AUTH_KEY")"
            printf 'PERSIST_AUTH_KEY=%s\n' "$(quote_env "$PERSIST_AUTH_KEY")"
        fi
    } >"$tmp"
    chmod 0600 "$tmp" 2>/dev/null || true

    if [ -f "$ENV_FILE" ] && cmp -s "$tmp" "$ENV_FILE" >/dev/null 2>&1; then
        rm -f "$tmp"
        log "配置文件已是最新：$ENV_FILE"
        return 0
    fi

    mv "$tmp" "$ENV_FILE"
    log "配置已写入 $ENV_FILE"
}

# ──────────────────────────── 架构检测 ─────────────────────────────────

cpu_arch() {
    uname -m 2>/dev/null || printf unknown
}

arm_version_from_cpuinfo() {
    if [ -r /proc/cpuinfo ]; then
        awk -F: '
            /CPU architecture/ {
                gsub(/^[ \t]+|[ \t]+$/, "", $2)
                gsub(/[^0-9]/, "", $2)
                if ($2 != "") { print $2; exit }
            }
        ' /proc/cpuinfo 2>/dev/null
    fi
}

detect_target() {
    if [ -n "$TARGET" ]; then
        printf '%s\n' "$TARGET"
        return 0
    fi

    os=$(uname -s 2>/dev/null || printf unknown)
    case "$os" in
        Linux|linux) ;;
        *) fail "当前系统不是 Linux，无法自动选择 tailscale-small 包；请设置 TARGET 或 PACKAGE_URL" ;;
    esac

    arch=$(cpu_arch)
    case "$arch" in
        x86_64|amd64) printf 'linux-amd64\n' ;;
        i386|i486|i586|i686) printf 'linux-386\n' ;;
        aarch64|arm64) printf 'linux-arm64\n' ;;
        armv7l|armv7*|armv8l) printf 'linux-arm-v7\n' ;;
        armv6l|armv6*) printf 'linux-arm-v6\n' ;;
        armv5l|armv5*|armel) printf 'linux-arm-v5\n' ;;
        arm*)
            v=$(arm_version_from_cpuinfo || true)
            case "$v" in
                8|7) printf 'linux-arm-v7\n' ;;
                6) printf 'linux-arm-v6\n' ;;
                5) printf 'linux-arm-v5\n' ;;
                *) fail "无法识别 ARM 版本：uname -m=$arch；请设置 TARGET=linux-arm-v7/linux-arm-v6/linux-arm-v5" ;;
            esac
            ;;
        mipsel|mipsle) printf 'linux-mipsle-softfloat\n' ;;
        mips) printf 'linux-mips-softfloat\n' ;;
        mips64el|mips64le) printf 'linux-mips64le-softfloat\n' ;;
        riscv64) printf 'linux-riscv64\n' ;;
        *) fail "不支持或无法识别的 CPU 架构：$arch；请设置 TARGET 或 PACKAGE_URL" ;;
    esac
}

# ──────────────────────────── 版本/URL 解析 ────────────────────────────

fetch_release_tags() {
    if have curl; then
        curl -fsSL --connect-timeout 5 --max-time 10 "$GITHUB_API" 2>/dev/null | \
            sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p'
    elif have wget; then
        wget -qO- --timeout=10 "$GITHUB_API" 2>/dev/null | \
            sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p'
    else
        return 1
    fi
}

resolve_version() {
    if [ "$VERSION" = latest ]; then
        printf '%s\n' latest
        return 0
    fi

    tags=$(fetch_release_tags 2>/dev/null || true)
    if [ -z "$tags" ]; then
        log "无法获取线上版本列表，按本地配置版本 $VERSION 继续"
        printf '%s\n' "$VERSION"
        return 0
    fi

    if printf '%s\n' "$tags" | grep -Fxq "$VERSION"; then
        printf '%s\n' "$VERSION"
        return 0
    fi

    log "指定版本 $VERSION 不存在线上列表，回退到 latest"
    printf '%s\n' latest
}

effective_package_url() {
    if [ -n "$PACKAGE_URL" ]; then
        printf '%s\n' "$PACKAGE_URL"
        return 0
    fi
    target=$(detect_target)
    version=$(resolve_version)
    printf '%s/%s/tailscale-small_%s_%s.tar.gz\n' "$CDN_BASE" "$version" "$version" "$target"
}

# ──────────────────────── 交互式 / 非交互式配置 ─────────────────────────

ask_value() {
    name=$1
    text=$2
    def=$3
    hint=${4:-}

    if [ -n "$hint" ]; then
        printf '  %s\n' "$hint" >&2
    fi
    printf '  %s [%s]: ' "$text" "$def" >&2
    if read ans; then
        if [ -z "$ans" ]; then
            ans=$def
        fi
    else
        ans=$def
    fi
    case "$name" in
        STATEDIR) STATEDIR=$ans ;;
        CONFIG) CONFIG=$ans ;;
        PACKAGE_URL) PACKAGE_URL=$ans ;;
        VERSION) VERSION=$ans ;;
        *) fail "内部错误：不支持的配置项 $name" ;;
    esac
}

configure_interactive() {
    make_base_dirs
    # 用 cpu_arch 展示架构（永不失败），避免非 Linux 上 detect_target 退出
    displayed_arch=$(cpu_arch)
    default_package=${PACKAGE_URL:-}
    if [ -z "$default_package" ]; then
        default_target=$(detect_target)
        default_package=$CDN_BASE/latest/tailscale-small_latest_${default_target}.tar.gz
    fi

    cat >&2 <<INTRO

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Tailscale 极简版 (tailscale-small) 路由器安装向导
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  检测到 CPU 架构：$displayed_arch

  说明：
  · 每项都会显示 [默认值]，直接按回车即可使用默认。
  · POSIX sh 不支持方向键/光标移动 — 输入错误请用
    Backspace 删掉后重新输入。
INTRO

    ask_value STATEDIR \
        "状态目录（持久保存 Tailscale 身份和密钥）" \
        "$STATEDIR"

    ask_value CONFIG \
        "Tailscale 配置文件路径（可留空）" \
        "$CONFIG" \
        "  非空时会传给 tailscaled --config，一般不需要。"

    cat >&2 <<'PKGINTRO'

  ── 下载设置 ──
  支持两种方式：
    1. 留空 = 自动从 jsDelivr CDN 下载，架构已检测为上面的值
    2. 填入完整 URL = 使用自定义下载源（只需 tar.gz 压缩包地址）
PKGINTRO

    ask_value PACKAGE_URL \
        "下载地址" \
        "$default_package" \
        "  默认：$default_package"

    cat >&2 <<'VERINTRO'

  ── 版本选择 ──
    latest    始终跟随最新发布（默认，推荐）
    固定版本  例如 v1.100.0 — 如果该版本不存在，自动回退到 latest
VERINTRO

    ask_value VERSION \
        "Tailscale 版本" \
        "$VERSION"

    # 确认摘要
    echo >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo "  配置摘要：" >&2
    echo "  · 状态目录：$STATEDIR" >&2
    echo "  · 配置文件：${CONFIG:-(空)}" >&2
    echo "  · 下载地址：$PACKAGE_URL" >&2
    echo "  · 版　　本：$VERSION" >&2
    echo "  · 二进制安装到：$TMP_DIR/tailscale" >&2
    echo "  · socket：$SOCKET" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    printf '  确认以上配置？[Y/n] ' >&2
    if read confirm && [ -n "$confirm" ]; then
        case "$confirm" in
            y|Y|yes|YES|Yes) ;;
            *) echo "  已取消安装" >&2; exit 0 ;;
        esac
    fi

    save_env
}

configure_batch() {
    # 非交互模式：从环境变量取值，不询问
    log "非交互模式：从环境变量读取配置"
    STATEDIR=${STATEDIR:-/data/tailscale/state}
    CONFIG=${CONFIG:-}
    VERSION=${VERSION:-latest}
    if [ -z "$PACKAGE_URL" ]; then
        target=$(detect_target)
        PACKAGE_URL=$CDN_BASE/$VERSION/tailscale-small_${VERSION}_${target}.tar.gz
    fi
    make_base_dirs
    save_env
}

# ──────────────────────────── 下载 & 解压 ──────────────────────────────

download_file() {
    url=$1
    out=$2
    if have curl; then
        curl -fL --connect-timeout 10 --retry 2 -o "$out" "$url"
    elif have wget; then
        wget -O "$out" "$url"
    elif have busybox && busybox wget --help >/dev/null 2>&1; then
        busybox wget -O "$out" "$url"
    else
        fail "需要 curl、wget 或 busybox wget 才能下载：$url"
    fi
}

extract_package() {
    pkg=$1
    dst=$2
    rm -rf "$dst"
    mkdir -p "$dst"
    if tar -xzf "$pkg" -C "$dst" 2>/dev/null; then
        return 0
    fi
    if have busybox && busybox tar -xzf "$pkg" -C "$dst" 2>/dev/null; then
        return 0
    fi
    fail "解压失败：$pkg；压缩包必须是 .tar.gz，且包含 tailscale"
}

install_package() {
    ensure_config auto
    make_base_dirs
    check_space "$DATA_DIR" "$MIN_DATA_FREE_KB"
    check_space "$TMP_DIR" "$MIN_TMP_FREE_KB"

    pkg="$TMP_DIR/tailscale-package.$$.tar.gz"
    unpack="$TMP_DIR/unpack.$$"
    rm -rf "$pkg" "$unpack"

    pkg_url=$(effective_package_url)
    log "下载压缩包：$pkg_url"
    download_file "$pkg_url" "$pkg"
    extract_package "$pkg" "$unpack"

    src=""
    if [ -f "$unpack/tailscale" ]; then
        src="$unpack/tailscale"
    elif [ -f "$unpack/tailscale.combined" ]; then
        src="$unpack/tailscale.combined"
    else
        fail "压缩包里没有 tailscale"
    fi

    if [ -f "$BIN" ] && cmp -s "$src" "$BIN" >/dev/null 2>&1; then
        log "二进制已是最新，跳过覆盖：$BIN"
    else
        if [ -f "$BIN" ]; then
            cp "$BIN" "$TMP_DIR/tailscale.old" 2>/dev/null || true
        fi
        cp "$src" "$BIN.new"
        chmod 0755 "$BIN.new"
        mv "$BIN.new" "$BIN"
        log "已安装 $BIN"
    fi

    ln -sf tailscale "$DAEMON"
    rm -rf "$pkg" "$unpack"
}

# ──────────────────────────── 进程管理 ─────────────────────────────────

files_ok() {
    [ -x "$BIN" ] && [ ! -L "$BIN" ] && [ -L "$DAEMON" ] && [ -x "$DAEMON" ]
}

pid_alive() {
    pid=$1
    [ -n "$pid" ] || return 1
    kill -0 "$pid" >/dev/null 2>&1
}

find_pid() {
    if [ -f "$PIDFILE" ]; then
        pid=$(cat "$PIDFILE" 2>/dev/null || true)
        if pid_alive "$pid"; then
            printf '%s\n' "$pid"
            return 0
        fi
    fi

    if have pidof; then
        pidof tailscaled 2>/dev/null | awk '{print $1}' && return 0
    fi

    ps 2>/dev/null | awk '/[t]ailscaled/ {print $1; exit}'
}

is_running() {
    pid=$(find_pid || true)
    [ -n "$pid" ] && pid_alive "$pid"
}

start_tailscaled() {
    ensure_config auto
    make_base_dirs
    make_run_dir
    files_ok || install_package

    if start_error_active; then
        tail -n 20 "$ERROR_FILE" 2>/dev/null || true
        fail "检测到启动熔断；请修复问题后执行 clear-error"
    fi

    if is_running; then
        log "tailscaled 已运行，pid $(find_pid)"
        return 0
    fi

    rm -f "$SOCKET"
    log "启动 tailscaled"
    set -- "$DAEMON" "--statedir=$STATEDIR" "--socket=$SOCKET"
    if [ -n "$CONFIG" ]; then
        set -- "$@" "--config=$CONFIG"
    fi
    # shellcheck disable=SC2086
    set -- "$@" $TAILSCALED_ARGS

    if have setsid; then
        setsid "$@" >>"$LOGFILE" 2>&1 </dev/null &
    elif have nohup; then
        nohup "$@" >>"$LOGFILE" 2>&1 </dev/null &
    else
        "$@" >>"$LOGFILE" 2>&1 </dev/null &
    fi
    pid=$!
    printf '%s\n' "$pid" >"$PIDFILE"
    sleep 2

    if pid_alive "$pid"; then
        pid_matches_daemon "$pid" || log "警告：进程已存活，但 ps 未识别为 tailscaled；继续视为启动成功"
        clear_start_state
        log "tailscaled 已启动，pid $pid"
    else
        tail -n 40 "$LOGFILE" 2>/dev/null || true
        record_start_failure "tailscaled 启动失败"
        fail "tailscaled 启动失败"
    fi
}

stop_tailscaled() {
    pid=$(find_pid || true)
    if [ -z "$pid" ]; then
        log "tailscaled 未运行"
        rm -f "$PIDFILE"
        return 0
    fi

    log "停止 tailscaled，pid $pid"
    kill "$pid" >/dev/null 2>&1 || true
    i=0
    while [ "$i" -lt 10 ]; do
        if ! pid_alive "$pid"; then
            rm -f "$PIDFILE"
            log "tailscaled 已停止"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done

    kill -9 "$pid" >/dev/null 2>&1 || true
    rm -f "$PIDFILE"
    log "tailscaled 已强制结束"
}


# ──────────────────────────── service / 自启动后端 ───────────────────────

read_init_name() {
    if [ -n "${FORCE_INIT:-}" ]; then
        printf '%s\n' "$FORCE_INIT"
    elif [ -r /proc/1/comm ]; then
        cat /proc/1/comm 2>/dev/null
    else
        printf 'unknown\n'
    fi
}

service_real_path() {
    backend=$1
    case "$backend" in
        procd|openrc) path=/etc/init.d/$SERVICE_NAME ;;
        systemd) path=/etc/systemd/system/$SERVICE_NAME.service ;;
        *) path='' ;;
    esac
    if [ -n "$path" ] && [ -n "$SERVICE_ROOT" ]; then
        printf '%s%s\n' "$SERVICE_ROOT" "$path"
    else
        printf '%s\n' "$path"
    fi
}

detect_boot_backend() {
    case "$BOOT_BACKEND" in
        procd|systemd|openrc|cron|manual)
            printf '%s\n' "$BOOT_BACKEND"
            return 0
            ;;
    esac

    init=$(read_init_name)
    if [ -f /etc/rc.common ] && [ "$init" = procd ]; then
        printf 'procd\n'
    elif have systemctl && [ "$init" = systemd ]; then
        printf 'systemd\n'
    elif have rc-status && rc-status -r >/dev/null 2>&1; then
        printf 'openrc\n'
    else
        printf 'cron\n'
    fi
}

script_abs_path() {
    case "$0" in
        /*) printf '%s\n' "$0" ;;
        */*) oldpwd=$(pwd 2>/dev/null || printf '.'); printf '%s/%s\n' "$oldpwd" "$0" ;;
        *) printf '%s/%s\n' "$DATA_DIR" "$SCRIPT_NAME" ;;
    esac
}

daemon_start_foreground() {
    ensure_config auto
    make_base_dirs
    make_run_dir
    files_ok || install_package
    rm -f "$SOCKET"
    set -- "$DAEMON" "--statedir=$STATEDIR" "--socket=$SOCKET"
    if [ -n "$CONFIG" ]; then
        set -- "$@" "--config=$CONFIG"
    fi
    # shellcheck disable=SC2086
    set -- "$@" $TAILSCALED_ARGS
    exec "$@"
}

write_procd_service() {
    path=$(service_real_path procd)
    [ -n "$path" ] || fail "无法确定 procd service 路径"
    mkdir -p "$(dirname "$path")"
    script=$(script_abs_path)
    cat >"$path" <<EOF
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command "$script" daemon-start
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() {
    "$script" stop >/dev/null 2>&1 || true
}
EOF
    chmod 0755 "$path" 2>/dev/null || true
    log "procd service 已写入：$path"
}

write_systemd_service() {
    path=$(service_real_path systemd)
    [ -n "$path" ] || fail "无法确定 systemd service 路径"
    mkdir -p "$(dirname "$path")"
    script=$(script_abs_path)
    cat >"$path" <<EOF
[Unit]
Description=tailscale-small runtime manager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$script daemon-start
ExecStop=$script stop
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$path" 2>/dev/null || true
    log "systemd service 已写入：$path"
}

write_openrc_service() {
    path=$(service_real_path openrc)
    [ -n "$path" ] || fail "无法确定 OpenRC service 路径"
    mkdir -p "$(dirname "$path")"
    script=$(script_abs_path)
    cat >"$path" <<EOF
#!/sbin/openrc-run
name="$SERVICE_NAME"
description="tailscale-small runtime manager"
command="$script"
command_args="daemon-start"
command_background=false
pidfile="$PIDFILE"

supervisor=supervise-daemon
respawn_delay=3
respawn_max=0

depend() {
    after net
}

stop() {
    ebegin "Stopping tailscale-small"
    "$script" stop >/dev/null 2>&1 || true
    eend $?
}
EOF
    chmod 0755 "$path" 2>/dev/null || true
    log "OpenRC service 已写入：$path"
}

service_install() {
    ensure_config auto
    backend=$(detect_boot_backend)
    case "$backend" in
        procd) write_procd_service ;;
        systemd) write_systemd_service ;;
        openrc) write_openrc_service ;;
        cron) write_cron ;;
        manual) log "BOOT_BACKEND=manual，跳过自启动安装" ;;
        *) fail "不支持的 BOOT_BACKEND：$backend" ;;
    esac
}

service_remove() {
    backend=$(detect_boot_backend)
    case "$backend" in
        procd|systemd|openrc)
            path=$(service_real_path "$backend")
            rm -f "$path"
            log "service 已移除：$path"
            ;;
        cron) remove_cron ;;
        manual) log "BOOT_BACKEND=manual，无需移除 service" ;;
    esac
}

enable_autostart() {
    service_install
    backend=$(detect_boot_backend)
    if [ -n "$SERVICE_ROOT" ]; then
        log "SERVICE_ROOT=$SERVICE_ROOT，仅写入 service 文件，跳过系统 enable 命令"
        return 0
    fi
    case "$backend" in
        procd) /etc/init.d/$SERVICE_NAME enable 2>/dev/null || write_cron ;;
        systemd) systemctl daemon-reload 2>/dev/null || true; systemctl enable "$SERVICE_NAME.service" 2>/dev/null || write_cron ;;
        openrc) rc-update add "$SERVICE_NAME" default 2>/dev/null || write_cron ;;
        cron) write_cron ;;
        manual) log "BOOT_BACKEND=manual，跳过 enable" ;;
    esac
}

disable_autostart() {
    backend=$(detect_boot_backend)
    if [ -n "$SERVICE_ROOT" ]; then
        service_remove
        return 0
    fi
    case "$backend" in
        procd) /etc/init.d/$SERVICE_NAME disable 2>/dev/null || true; service_remove ;;
        systemd) systemctl disable "$SERVICE_NAME.service" 2>/dev/null || true; systemctl daemon-reload 2>/dev/null || true; service_remove ;;
        openrc) rc-update del "$SERVICE_NAME" default 2>/dev/null || true; service_remove ;;
        cron) remove_cron ;;
        manual) log "BOOT_BACKEND=manual，跳过 disable" ;;
    esac
}

boot_status() {
    backend=$(detect_boot_backend)
    printf 'boot_backend=%s\n' "$backend"
    case "$backend" in
        procd|systemd|openrc)
            path=$(service_real_path "$backend")
            printf 'service_file=%s\n' "$path"
            [ -f "$path" ] && printf 'service_file_state=present\n' || printf 'service_file_state=missing\n'
            ;;
        cron)
            cron_is_written && printf 'cron_state=present\n' || printf 'cron_state=missing\n'
            ;;
        manual)
            printf 'autostart=manual\n'
            ;;
    esac
}

# ──────────────────────────── cron 管理 ────────────────────────────────

cron_target() {
    if [ -n "${CRON_FILE:-}" ]; then
        printf '%s\n' "$CRON_FILE"
        return 0
    fi
    if have crontab; then
        printf '%s\n' crontab
        return 0
    fi
    if [ -d /etc/crontabs ] || [ -f /etc/crontabs/root ]; then
        printf '%s\n' /etc/crontabs/root
        return 0
    fi
    if [ -d /var/spool/cron/crontabs ] || [ -f /var/spool/cron/crontabs/root ]; then
        printf '%s\n' /var/spool/cron/crontabs/root
        return 0
    fi
    fail "找不到可写的定时任务位置（crontab /etc/crontabs/root /var/spool/cron/crontabs/root 都不可用）"
}

cron_block() {
    cat <<EOF
$CRON_BEGIN
# 每 5 分钟执行完整自愈流程：必要时安装 tailscale，然后启动 tailscaled。日志写到 /tmp，避免占用 /data。
*/5 * * * * mkdir -p "$TMP_DIR" && DATA_DIR="$DATA_DIR" TMP_DIR="$TMP_DIR" "$DATA_DIR/$SCRIPT_NAME" ensure >>"$MANAGER_LOG" 2>&1
$CRON_END
EOF
}

cron_present_in_text() {
    printf '%s\n' "$1" | grep -Fq "$CRON_BEGIN"
}

write_cron() {
    make_base_dirs
    target=$(cron_target)
    old="$TMP_DIR/cron.old.$$"
    new="$TMP_DIR/cron.new.$$"

    if [ "$target" = crontab ]; then
        crontab -l 2>/dev/null >"$old" || :
    else
        if [ -f "$target" ]; then
            cat "$target" >"$old"
        else
            : >"$old"
        fi
    fi

    awk -v begin="$CRON_BEGIN" -v end="$CRON_END" '
        $0 == begin {skip = 1; next}
        $0 == end {skip = 0; next}
        skip {next}
        {print}
    ' "$old" >"$new"

    cron_block >>"$new"
    chmod 0644 "$new" 2>/dev/null || true

    if [ -f "$old" ] && cmp -s "$old" "$new" >/dev/null 2>&1; then
        rm -f "$old" "$new"
        log "定时任务已是最新"
        return 0
    fi

    if [ "$target" = crontab ]; then
        crontab "$new"
        rm -f "$new"
    else
        mv "$new" "$target"
    fi
    rm -f "$old"
    log "定时任务已写入"
}

remove_cron() {
    target=$(cron_target 2>/dev/null || true)
    if [ -z "$target" ]; then
        log "未找到定时任务位置，跳过 cron 清理"
        return 0
    fi

    old="$TMP_DIR/cron.old.$$"
    new="$TMP_DIR/cron.new.$$"
    mkdir -p "$TMP_DIR"

    if [ "$target" = crontab ]; then
        crontab -l 2>/dev/null >"$old" || :
    else
        if [ -f "$target" ]; then
            cat "$target" >"$old"
        else
            log "定时任务不存在，跳过 cron 清理"
            rm -f "$old" "$new"
            return 0
        fi
    fi

    awk -v begin="$CRON_BEGIN" -v end="$CRON_END" '
        $0 == begin {skip = 1; next}
        $0 == end {skip = 0; next}
        skip {next}
        {print}
    ' "$old" >"$new"

    if cmp -s "$old" "$new" >/dev/null 2>&1; then
        rm -f "$old" "$new"
        log "定时任务未安装或已清理"
        return 0
    fi

    if [ "$target" = crontab ]; then
        if [ -s "$new" ]; then
            crontab "$new"
        else
            crontab -r 2>/dev/null || crontab "$new"
        fi
        rm -f "$new"
    else
        mv "$new" "$target"
    fi
    rm -f "$old"
    log "定时任务已移除"
}

cron_is_written() {
    target=$(cron_target 2>/dev/null || true)
    if [ -z "$target" ]; then
        return 1
    fi
    if [ "$target" = crontab ]; then
        crontab -l 2>/dev/null | grep -Fq "$CRON_BEGIN"
    else
        [ -f "$target" ] && grep -Fq "$CRON_BEGIN" "$target"
    fi
}

# ──────────────────────────── 状态 / 命令入口 ──────────────────────────

status() {
    make_base_dirs
    printf '持久目录 DATA_DIR=%s\n' "$DATA_DIR"
    printf '临时目录 TMP_DIR=%s\n' "$TMP_DIR"
    printf '环境文件 ENV_FILE=%s\n' "$ENV_FILE"
    printf 'ENV_SCHEMA_VERSION=%s\n' "$ENV_SCHEMA_VERSION"
    printf '二进制 BIN=%s\n' "$BIN"
    printf 'daemon 入口 DAEMON=%s\n' "$DAEMON"
    printf '状态目录 STATEDIR=%s\n' "$STATEDIR"
    printf '配置文件 CONFIG=%s\n' "$CONFIG"
    printf 'socket=%s\n' "$SOCKET"
    printf '配置版本 VERSION=%s\n' "$VERSION"
    if target=$(detect_target 2>/dev/null); then
        printf '目标架构=%s\n' "$target"
    else
        printf '目标架构=unknown\n'
    fi
    printf '压缩包 URL=%s\n' "$(effective_package_url 2>/dev/null || printf 'unknown')"

    if files_ok; then
        printf '文件状态=正常\n'
        ls -l "$BIN" "$DAEMON" 2>/dev/null || true
    else
        printf '文件状态=缺失\n'
    fi

    if is_running; then
        printf '进程状态=运行中 pid=%s\n' "$(find_pid)"
    else
        printf '进程状态=未运行\n'
    fi

    printf 'boot_backend=%s\n' "$(detect_boot_backend)"
    if cron_is_written; then
        printf '定时任务=已写入\n'
    else
        printf '定时任务=未写入\n'
    fi

    if [ -d "$LOCKDIR" ]; then
        printf 'lock_state=locked\n'
    else
        printf 'lock_state=unlocked\n'
    fi

    if start_error_active; then
        printf 'error_state=tripped\n'
        tail -n 20 "$ERROR_FILE" 2>/dev/null || true
    else
        printf 'error_state=clear\n'
    fi

    printf 'logfile=%s\n' "$LOGFILE"
    printf 'manager_log=%s\n' "$MANAGER_LOG"

    data_kb=$(free_kb "$DATA_DIR" || printf 'unknown')
    tmp_kb=$(free_kb "$TMP_DIR" || printf 'unknown')
    printf 'data_free_kb=%s\n' "$data_kb"
    printf 'tmp_free_kb=%s\n' "$tmp_kb"

    if [ -s "$LOGFILE" ]; then
        printf '--- tailscaled.log (last 10) ---\n'
        tail -n 10 "$LOGFILE" 2>/dev/null || true
    fi
    if [ -s "$MANAGER_LOG" ]; then
        printf '--- manager.log (last 10) ---\n'
        tail -n 10 "$MANAGER_LOG" 2>/dev/null || true
    fi

    if [ -x "$CLI" ] && [ -S "$SOCKET" ]; then
        "$CLI" --socket="$SOCKET" status 2>/dev/null || true
    fi

    return 0
}

ensure_config() {
    cfg_mode=${1:-auto}
    if [ -f "$ENV_FILE" ]; then
        if [ "$CONFIG_NORMALIZED" = 1 ]; then
            save_env
            CONFIG_NORMALIZED=0
        fi
        return 0
    fi
    if [ "$cfg_mode" = interactive ] && [ -t 0 ]; then
        configure_interactive
        return 0
    fi
    if [ "$cfg_mode" = batch ]; then
        configure_batch
        return 0
    fi
    # stdin 非终端时也走默认配置，避免 pipe 场景下卡在交互分支
    log "未找到配置文件，使用默认配置生成；如需自定义，请先运行：$0 install"
    save_env
    return 0
}

ensure_all() {
    ensure_config auto
    make_base_dirs
    if [ "$UPDATE_ON_ENSURE" = 1 ] || ! files_ok; then
        log "执行安装流程"
        install_package
    else
        log "tailscale 文件已存在，跳过下载安装"
    fi
    if ! is_running; then
        log "执行启动流程"
        start_tailscaled
    else
        log "tailscaled 已运行"
    fi
}

install_with_mode() {
    install_semantics=$1
    install_batch_flag=${2:-0}
    case "$install_semantics" in
        only|start|enable|keepalive|autostart) ;;
        *) fail "不支持的 install 语义：$install_semantics" ;;
    esac

    if [ "$install_batch_flag" = 1 ]; then
        ensure_config batch
    else
        ensure_config interactive
    fi

    install_package
    case "$install_semantics" in
        only)
            log "安装完成：未启动 tailscaled，也未开启自启动/保活"
            ;;
        start)
            log "安装完成：按 install start 语义启动 tailscaled，不开启自启动/保活"
            start_tailscaled
            ;;
        enable|keepalive|autostart)
            log "安装完成：按 install enable 语义开启自启动/保活并启动 tailscaled"
            enable_autostart
            start_tailscaled
            ;;
    esac
}

install_all() {
    install_with_mode enable 0
}

install_batch() {
    install_with_mode enable 1
}

update_all() {
    ensure_config auto
    stop_tailscaled
    install_package
    enable_autostart
    start_tailscaled
}

restart_all() {
    stop_tailscaled
    start_tailscaled
}

cron_all() {
    ensure_config auto
    write_cron
}

clear_error_cmd() {
    clear_start_state
    log "已清理启动失败标记"
}


# ──────────────────────────── doctor / Tailscale 运维 ───────────────────

detect_device_type() {
    if [ -f /etc/openwrt_release ] || [ -f /etc/rc.common ]; then printf 'OpenWrt-like\n'
    elif [ -f /etc/storage/started_script.sh ]; then printf 'Padavan\n'
    elif [ -d /jffs ]; then printf 'ASUS/Merlin-like\n'
    elif [ -f /data/etc/crontabs/root ]; then printf 'Xiaomi-like\n'
    elif [ -w /var/mnt/cfg/firewall ] 2>/dev/null; then printf 'Netgear-like\n'
    elif have systemctl && [ "$(read_init_name)" = systemd ]; then printf 'Linux/systemd\n'
    elif have rc-status && rc-status -r >/dev/null 2>&1; then printf 'Linux/OpenRC\n'
    else printf 'Generic Linux/BusyBox\n'
    fi
}

check_writable_dir() {
    d=$1
    if [ -d "$d" ] && [ -w "$d" ]; then
        printf '%s writable=yes free_kb=%s\n' "$d" "$(free_kb "$d" || printf unknown)"
    else
        parent=$(dirname "$d")
        if [ -d "$parent" ] && [ -w "$parent" ]; then
            printf '%s writable=parent parent=%s parent_free_kb=%s\n' "$d" "$parent" "$(free_kb "$parent" || printf unknown)"
        else
            printf '%s writable=no\n' "$d"
        fi
    fi
}

doctor_all() {
    printf 'device_type=%s\n' "$(detect_device_type)"
    printf 'init=%s\n' "$(read_init_name)"
    printf 'recommended_backend=%s\n' "$(detect_boot_backend)"
    printf 'cpu_arch=%s\n' "$(cpu_arch)"
    if target=$(detect_target 2>/dev/null); then printf 'target=%s\n' "$target"; else printf 'target=unknown\n'; fi
    printf 'DATA_DIR=%s\n' "$DATA_DIR"
    printf 'TMP_DIR=%s\n' "$TMP_DIR"
    printf 'RUN_DIR=%s\n' "$RUN_DIR"
    printf 'tools_curl=%s\n' "$(have curl && printf yes || printf no)"
    printf 'tools_wget=%s\n' "$(have wget && printf yes || printf no)"
    printf 'tools_busybox=%s\n' "$(have busybox && printf yes || printf no)"
    printf 'tools_tar=%s\n' "$(have tar && printf yes || printf no)"
    printf 'tools_crontab=%s\n' "$(have crontab && printf yes || printf no)"
    printf 'tools_setsid=%s\n' "$(have setsid && printf yes || printf no)"
    printf 'tools_nohup=%s\n' "$(have nohup && printf yes || printf no)"
    printf 'tun_device=%s\n' "$([ -e /dev/net/tun ] && printf present || printf missing)"
    printf '%s\n' 'persistent_dir_candidates:'
    check_writable_dir "$DATA_DIR"
    [ "$DATA_DIR" != /data/tailscale ] && check_writable_dir /data/tailscale
    check_writable_dir /jffs/tailscale
    check_writable_dir /etc/storage/tailscale
    check_writable_dir /opt/tailscale
    boot_status
}

tailscale_up() {
    ensure_config auto
    make_base_dirs
    files_ok || install_package
    is_running || start_tailscaled
    set -- "$CLI" "--socket=$SOCKET" up "$@"
    [ -n "$AUTH_KEY" ] && set -- "$@" "--auth-key=$AUTH_KEY"
    [ -n "$TS_HOSTNAME" ] && set -- "$@" "--hostname=$TS_HOSTNAME"
    [ -n "$ADVERTISE_ROUTES" ] && set -- "$@" "--advertise-routes=$ADVERTISE_ROUTES"
    [ -n "$ACCEPT_DNS" ] && set -- "$@" "--accept-dns=$ACCEPT_DNS"
    [ -n "$ACCEPT_ROUTES" ] && set -- "$@" "--accept-routes=$ACCEPT_ROUTES"
    [ -n "$EXIT_NODE" ] && set -- "$@" "--exit-node=$EXIT_NODE"
    "$@"
}

login_status() {
    ensure_config auto
    if ! is_running; then
        printf 'tailscaled=stopped\n'
        return 1
    fi
    if [ -x "$CLI" ]; then
        "$CLI" --socket="$SOCKET" status 2>/dev/null || true
    else
        printf 'tailscale_cli=missing\n'
    fi
}

reset_state() {
    stop_tailscaled
    case "$STATEDIR" in
        ''|/) fail "拒绝删除危险状态目录：$STATEDIR" ;;
        *) rm -rf "$STATEDIR" ;;
    esac
    mkdir -p "$STATEDIR"
    clear_start_state
    start_tailscaled
}

doctor_tailscale() {
    printf 'files_ok=%s\n' "$(files_ok && printf yes || printf no)"
    printf 'running=%s\n' "$(is_running && printf yes || printf no)"
    printf 'socket=%s\n' "$SOCKET"
    printf 'socket_state=%s\n' "$([ -S "$SOCKET" ] && printf present || printf missing)"
    printf 'state_dir=%s\n' "$STATEDIR"
    printf 'state_dir_state=%s\n' "$([ -d "$STATEDIR" ] && printf present || printf missing)"
    printf 'tun_device=%s\n' "$([ -e /dev/net/tun ] && printf present || printf missing)"
    printf 'system_tailscale=%s\n' "$(command -v tailscale 2>/dev/null || printf missing)"
    printf 'system_tailscaled=%s\n' "$(command -v tailscaled 2>/dev/null || printf missing)"
    if have ping; then
        ping -c 1 -W 2 controlplane.tailscale.com >/dev/null 2>&1 && printf 'controlplane_ping=ok\n' || printf 'controlplane_ping=failed\n'
    else
        printf 'controlplane_ping=skipped_no_ping\n'
    fi
}

# ──────────────────────────── 卸载 ─────────────────────────────────────

yes_value() {
    case "$1" in
        1|y|Y|yes|YES|Yes|true|TRUE|True|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

ask_yes_no_default_no() {
    text=$1
    if [ -t 0 ]; then
        printf '%s [y/N]: ' "$text" >&2
        if read ans; then
            yes_value "$ans"
            return $?
        fi
    fi
    return 1
}

remove_runtime_files() {
    rm -f "$BIN" "$DAEMON" "$PIDFILE" "$LOGFILE" "$SOCKET" \
        "$TMP_DIR/tailscale.old" \
        "$TMP_DIR/manager.log"
    rm -f "$TMP_DIR"/tailscale-package.*.tar.gz 2>/dev/null || true
    rm -rf "$TMP_DIR"/unpack.* 2>/dev/null || true
    rmdir "$RUN_DIR" 2>/dev/null || true
    rmdir "$TMP_DIR" 2>/dev/null || true
    log "运行时文件已清理"
}

remove_config_files() {
    rm -f "$ENV_FILE"
    case "$STATEDIR" in
        ''|/) fail "拒绝删除危险状态目录：$STATEDIR" ;;
        *) rm -rf "$STATEDIR" ;;
    esac
    rmdir "$DATA_DIR" 2>/dev/null || true
    log "配置和状态目录已清理"
}

remove_script_file() {
    script_path=$0
    case "$script_path" in
        */*) ;;
        *) script_path="$DATA_DIR/$SCRIPT_NAME" ;;
    esac
    rm -f "$script_path" "$DATA_DIR/$SCRIPT_NAME"
    rmdir "$DATA_DIR" 2>/dev/null || true
    log "脚本文件已清理"
}

uninstall_all() {
    log "开始卸载 tailscale-small"
    stop_tailscaled
    remove_cron
    remove_runtime_files

    if yes_value "${DELETE_CONFIG:-0}" || ask_yes_no_default_no "是否删除配置文件 .env 和状态目录 ${STATEDIR}？默认保留"; then
        remove_config_files
    else
        log "保留配置文件和状态目录"
    fi

    if yes_value "${DELETE_SCRIPT:-0}" || ask_yes_no_default_no "是否删除脚本 ${DATA_DIR}/${SCRIPT_NAME}？默认保留"; then
        remove_script_file
    else
        log "保留脚本文件"
    fi

    log "卸载完成"
}

# ──────────────────────────── 帮助 / 入口 ──────────────────────────────

usage() {
    cat <<'EOF'
用法：tsmanager.sh 命令 [选项]

命令：
  install     等价 install enable：配置 + 安装 + 开启自启动/保活 + 启动。
  install only    只配置 + 下载安装；不启动，不开启自启动/保活。
  install start   配置 + 下载安装 + 启动；不开启自启动/保活。
  install enable  配置 + 下载安装 + 开启自启动/保活 + 启动。
  install keepalive 等价 install enable。
  install -y / install start -y  非交互安装：从环境变量读取配置。
  update      重新下载安装并刷新 cron，然后启动 tailscaled。
  start       启动 tailscaled；如果二进制缺失会先下载安装。
  stop        停止 tailscaled；未运行也返回成功。
  restart     重启 tailscaled。
  clear-error 清理启动失败熔断标记，允许再次自动拉起。
  service-install 安装当前系统推荐的自启动 service。
  service-remove  移除当前 backend 的自启动 service。
  enable      开启自启动/保活；原生 init 不可用时回退 cron。
  disable     关闭自启动/保活。
  boot-status 查看自启动 backend 状态。
  doctor      环境诊断；doctor tailscale 检查 Tailscale 运行态。
  up          封装 tailscale up，自动带 socket。
  login-status 查看 Tailscale 登录/连接状态。
  reset-state 停止并删除 state 后重新启动。
  uninstall   完整卸载：停止进程、移除 cron、删除运行时文件；
              交互选择是否删除配置和脚本。
  status      查看配置、文件、进程、空间、cron 和下载 URL。
  ensure      cron 使用：从 .env 读取配置，必要时安装并启动，幂等。
  cron        自动把定时任务写入系统 crontab，重复执行幂等。
  help        显示此帮助。

两种安装模式：

  交互式（终端下默认）：
    sh tsmanager.sh install
    -> 逐项提示，每项显示 [默认值]，回车接受。最后显示摘要并确认。

  非交互式（脚本/自动化）：
    DATA_DIR=/data/tailscale TMP_DIR=/tmp/tailscale \
      VERSION=v1.100.0 sh tsmanager.sh install -y
    -> 所有配置从环境变量读取，不询问，不等待确认。

环境变量（install -y 模式下这些变量控制全部行为）：
  DATA_DIR=/data/tailscale      持久文件目录
  TMP_DIR=/tmp/tailscale        运行时文件目录
  STATEDIR=/data/tailscale/state 状态目录
  CONFIG=                       配置文件（可留空）
  PACKAGE_URL=                  下载地址（留空则自动从 CDN 取最新版）
  VERSION=latest                版本号（latest 或 v1.100.0）
  MIN_DATA_FREE_KB=64           最小磁盘空间限制
  MIN_TMP_FREE_KB=8192
  TAILSCALED_ARGS='--tun=tailscale0'  tailscaled 额外参数
  UPDATE_ON_ENSURE=0            设为 1 时 cron 每次重新下载安装
  BOOT_BACKEND=auto             auto/procd/systemd/openrc/cron/manual
  START_FAIL_LIMIT=3            连续启动失败达到阈值后熔断
  START_FAIL_WINDOW=600         统计失败次数的时间窗口（秒）

下载方式：
  留空 = 自动检测本机 Linux CPU 架构，从 jsDelivr CDN 下载：
    tailscale-small_<版本>_<目标>.tar.gz
  版本默认 latest（跟随最新发布）。可设固定版本（如 v1.100.0）：
    如果指定版本存在 -> 用该版本
    如果拉不到线上列表 -> 按给定版本继续
    如果指定版本不存在 -> 自动回退到 latest
  自定义 = 设置一个 tar.gz 下载地址即可：
    PACKAGE_URL=https://example.com/tailscale-small_v1.100.0_linux-arm64.tar.gz

目录策略：
  /data/tailscale -> 小文件：tsmanager.sh、.env、state/
  /tmp/tailscale  -> 二进制、下载包、解压目录、pid、日志
  socket -> /var/run/tailscale/tailscaled.sock

首次认证示例：
  /tmp/tailscale/tailscale --socket=/var/run/tailscale/tailscaled.sock up \
    --auth-key=tskey-... --hostname=router
EOF
}

# 解析命令行
cmd=${1:-status}
global_yes=0
case "$cmd" in
    -y|--yes)
        global_yes=1
        shift || true
        cmd=${1:-install}
        ;;
esac
[ $# -gt 0 ] && shift || true

case "$cmd" in
    install)
        install_mode=enable
        install_batch_mode=$global_yes
        while [ $# -gt 0 ]; do
            case "$1" in
                -y|--yes)
                    install_batch_mode=1
                    ;;
                only|download|files)
                    install_mode=only
                    ;;
                start|run)
                    install_mode=start
                    ;;
                enable|keepalive|autostart)
                    install_mode=enable
                    ;;
                *)
                    fail "不支持的 install 参数：$1；可用：only/start/enable/keepalive/-y"
                    ;;
            esac
            shift
        done
        run_locked install_with_mode "$install_mode" "$install_batch_mode"
        ;;
    update)
        run_locked update_all
        ;;
    start)
        run_locked start_tailscaled
        ;;
    stop)
        run_locked stop_tailscaled
        ;;
    restart)
        run_locked restart_all
        ;;
    clear-error)
        run_locked clear_error_cmd
        ;;
    service-install)
        run_locked service_install
        ;;
    service-remove)
        run_locked service_remove
        ;;
    enable)
        run_locked enable_autostart
        ;;
    disable)
        run_locked disable_autostart
        ;;
    boot-status)
        boot_status
        ;;
    doctor)
        if [ "${1:-}" = tailscale ]; then doctor_tailscale; else doctor_all; fi
        ;;
    up)
        shift || true
        run_locked tailscale_up "$@"
        ;;
    daemon-start)
        daemon_start_foreground
        ;;
    login-status)
        login_status
        ;;
    reset-state)
        run_locked reset_state
        ;;
    uninstall)
        run_locked uninstall_all
        ;;
    status)
        status
        ;;
    ensure)
        run_locked ensure_all
        ;;
    cron)
        run_locked cron_all
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
