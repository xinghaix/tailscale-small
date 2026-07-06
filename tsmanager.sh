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
# tailscale-small_<version>_<target>.tar.gz，并自动校验同名 .sha256 文件。
# 支持固定版本（如 v1.100.0），默认使用 latest。

set -eu

CDN_BASE=https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn
GITHUB_API=https://api.github.com/repos/xinghaix/tailscale-small/releases

SCRIPT_NAME=tsmanager.sh
DATA_DIR=${DATA_DIR:-/data/tailscale}
ENV_FILE=${ENV_FILE:-$DATA_DIR/.env}
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
fi

DATA_DIR=${DATA_DIR:-/data/tailscale}
ENV_FILE=${ENV_FILE:-$DATA_DIR/.env}
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
MIN_DATA_FREE_KB=${MIN_DATA_FREE_KB:-64}
MIN_TMP_FREE_KB=${MIN_TMP_FREE_KB:-8192}
TAILSCALED_ARGS=${TAILSCALED_ARGS:---tun=tailscale0}
UPDATE_ON_ENSURE=${UPDATE_ON_ENSURE:-0}

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

effective_checksum_url() {
    printf '%s.sha256\n' "$(effective_package_url)"
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
    2. 填入完整 URL = 使用自定义下载源（checksum 自动从 URL + .sha256 推导）
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

# ──────────────────────────── 下载 & 校验 ──────────────────────────────

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

sha256_of_file() {
    file=$1
    if have sha256sum; then
        sha256sum "$file" | awk '{print $1}'
    elif have shasum; then
        shasum -a 256 "$file" | awk '{print $1}'
    elif have busybox && busybox sha256sum --help >/dev/null 2>&1; then
        busybox sha256sum "$file" | awk '{print $1}'
    else
        fail "需要 sha256sum、shasum 或 busybox sha256sum 才能校验完整性"
    fi
}

verify_checksum() {
    pkg=$1
    sumfile=$2
    expected=$(sed -n 's/^\([A-Fa-f0-9][A-Fa-f0-9]*\).*/\1/p' "$sumfile" | sed -n '1p')
    case "$expected" in
        ????????????????????????????????????????????????????????????????) ;;
        *) fail "校验文件格式不正确：$sumfile" ;;
    esac
    actual=$(sha256_of_file "$pkg")
    expected_lc=$(printf '%s' "$expected" | tr 'A-F' 'a-f')
    actual_lc=$(printf '%s' "$actual" | tr 'A-F' 'a-f')
    if [ "$expected_lc" != "$actual_lc" ]; then
        fail "SHA256 校验失败：期望 $expected_lc，实际 $actual_lc"
    fi
    log "SHA256 校验通过：$actual_lc"
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
    sumfile="$pkg.sha256"
    unpack="$TMP_DIR/unpack.$$"
    rm -rf "$pkg" "$sumfile" "$unpack"

    pkg_url=$(effective_package_url)
    sum_url=$(effective_checksum_url)
    log "下载压缩包：$pkg_url"
    download_file "$pkg_url" "$pkg"
    log "下载校验文件：$sum_url"
    download_file "$sum_url" "$sumfile"
    verify_checksum "$pkg" "$sumfile"
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
    rm -rf "$pkg" "$sumfile" "$unpack"
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

    if is_running; then
        log "tailscaled 已运行，pid $(find_pid)"
        return 0
    fi

    rm -f "$SOCKET"
    log "启动 tailscaled"
    if [ -n "$CONFIG" ]; then
        # shellcheck disable=SC2086
        "$DAEMON" --statedir="$STATEDIR" --socket="$SOCKET" --config="$CONFIG" $TAILSCALED_ARGS >>"$LOGFILE" 2>&1 &
    else
        # shellcheck disable=SC2086
        "$DAEMON" --statedir="$STATEDIR" --socket="$SOCKET" $TAILSCALED_ARGS >>"$LOGFILE" 2>&1 &
    fi
    pid=$!
    printf '%s\n' "$pid" >"$PIDFILE"
    sleep 2

    if pid_alive "$pid"; then
        log "tailscaled 已启动，pid $pid"
    else
        tail -n 40 "$LOGFILE" 2>/dev/null || true
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
# 每 5 分钟执行完整自愈流程：必要时安装/校验 tailscale，然后启动 tailscaled。日志写到 /tmp，避免占用 /data。
*/5 * * * * mkdir -p "$TMP_DIR" && DATA_DIR="$DATA_DIR" TMP_DIR="$TMP_DIR" "$DATA_DIR/$SCRIPT_NAME" ensure >>"$TMP_DIR/manager.log" 2>&1
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
    printf '校验文件 URL=%s\n' "$(effective_checksum_url 2>/dev/null || printf 'unknown')"

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

    if cron_is_written; then
        printf '定时任务=已写入\n'
    else
        printf '定时任务=未写入\n'
    fi

    data_kb=$(free_kb "$DATA_DIR" || printf 'unknown')
    tmp_kb=$(free_kb "$TMP_DIR" || printf 'unknown')
    printf 'data_free_kb=%s\n' "$data_kb"
    printf 'tmp_free_kb=%s\n' "$tmp_kb"

    if [ -x "$CLI" ] && [ -S "$SOCKET" ]; then
        "$CLI" --socket="$SOCKET" status 2>/dev/null || true
    fi

    return 0
}

ensure_config() {
    mode=${1:-auto}
    if [ -f "$ENV_FILE" ]; then
        return 0
    fi
    if [ "$mode" = interactive ] && [ -t 0 ]; then
        configure_interactive
        return 0
    fi
    if [ "$mode" = batch ]; then
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
        log "执行安装/校验流程"
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

install_all() {
    ensure_config interactive
    install_package
    write_cron
}

install_batch() {
    ensure_config batch
    install_package
    write_cron
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
    rm -f "$TMP_DIR"/tailscale-package.*.tar.gz "$TMP_DIR"/tailscale-package.*.tar.gz.sha256 2>/dev/null || true
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
  install     交互式配置 + 下载校验 + 安装 + 写入 cron。重复执行幂等。
  install -y  非交互安装：从环境变量读取所有配置，直接安装。
  update      重新下载/校验/安装并刷新 cron，然后启动 tailscaled。
  start       启动 tailscaled；如果二进制缺失会先下载校验并安装。
  stop        停止 tailscaled；未运行也返回成功。
  restart     重启 tailscaled。
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
  UPDATE_ON_ENSURE=0            设为 1 时 cron 每次重新下载校验

下载方式：
  留空 = 自动检测本机 Linux CPU 架构，从 jsDelivr CDN 下载：
    tailscale-small_<版本>_<目标>.tar.gz + .sha256
  版本默认 latest（跟随最新发布）。可设固定版本（如 v1.100.0）：
    如果指定版本存在 -> 用该版本
    如果拉不到线上列表 -> 按给定版本继续
    如果指定版本不存在 -> 自动回退到 latest
  自定义 = 设置一个下载地址即可，checksum 自动从地址 + .sha256 推导：
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
shift_args=false
case "$cmd" in
    -y|--yes)
        cmd=${2:-install}
        shift_args=true
        ;;
esac

if $shift_args; then
    subcmd_args="$*"
else
    subcmd_args="${2:-}"
fi

case "$cmd" in
    install)
        if [ "$subcmd_args" = "-y" ] || [ "$subcmd_args" = "--yes" ]; then
            install_batch
        else
            install_all
        fi
        ;;
    update)
        ensure_config auto
        stop_tailscaled
        install_package
        write_cron
        start_tailscaled
        ;;
    start)
        start_tailscaled
        ;;
    stop)
        stop_tailscaled
        ;;
    restart)
        stop_tailscaled
        start_tailscaled
        ;;
    uninstall)
        uninstall_all
        ;;
    status)
        status
        ;;
    ensure)
        ensure_all
        ;;
    cron)
        ensure_config auto
        write_cron
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
