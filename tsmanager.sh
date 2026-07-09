#!/bin/sh
# 路由器用 Tailscale 极简管理脚本。
# 兼容 POSIX sh / BusyBox sh。
#
# 目录策略：
#   /data/tailscale/tsmanager.sh           持久脚本（install/enable/cron 会自安装到此）
#   /data/tailscale/.env                   持久配置（仅保存用户显式配置，自动推导项尽量不写入）
#   /data/tailscale/state/                 持久状态目录
#   /tmp/tailscale/tailscale               大体积二进制
#   /tmp/tailscale/tailscaled -> tailscale daemon 入口软链
#   /tmp/tailscale/tailscaled.pid          进程号
#   /tmp/tailscale/tailscaled.log          守护进程日志
#   /tmp/tailscale/manager.log             定时任务日志
#   /var/run/tailscale/tailscaled.sock     本地控制 socket
#
# 安全提示：
#   .env 等同 root 级配置。被写入恶意内容可影响启动参数。
#   AUTH_KEY 默认不持久化；status/日志不会打印 key 明文。
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
# tailscale-small_<version>_<target>.tar.gz；失败时回退 GitHub Releases。
# 支持固定版本（如 v1.100.0），默认使用 latest。
# 钉死 VERSION 时不会静默回退 latest（除非 VERSION_FALLBACK=1）。

set -eu

DEFAULT_CDN_BASE=https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn
DEFAULT_GITHUB_RELEASE_BASE=https://github.com/xinghaix/tailscale-small/releases/download
CDN_BASE=$DEFAULT_CDN_BASE
GITHUB_API=https://api.github.com/repos/xinghaix/tailscale-small/releases
CONFIG_NORMALIZED=0
SCRIPT_ENV_SCHEMA_VERSION=2
LOCK_HELD=0
INSTALL_CLEANUP_PKG=
INSTALL_CLEANUP_UNPACK=
NEED_RESTART_AFTER_INSTALL=0
CACHED_RESOLVED_VERSION=
CACHED_RELEASE_TAGS=
CACHED_TARGET=
DRY_RUN=0
START_WAIT_SECONDS=${START_WAIT_SECONDS:-15}
LOG_MAX_KB=${LOG_MAX_KB:-512}
MIN_PKG_FREE_MULTIPLIER=${MIN_PKG_FREE_MULTIPLIER:-3}
VERSION_FALLBACK=${VERSION_FALLBACK:-0}

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
MIN_TMP_FREE_KB=${MIN_TMP_FREE_KB:-12288}
TAILSCALED_ARGS=${TAILSCALED_ARGS:---tun=tailscale0}
UPDATE_ON_ENSURE=${UPDATE_ON_ENSURE:-0}
START_FAIL_LIMIT=${START_FAIL_LIMIT:-3}
START_FAIL_WINDOW=${START_FAIL_WINDOW:-600}
MANAGER_LOG=${MANAGER_LOG:-$TMP_DIR/manager.log}
LOCKDIR=${LOCKDIR:-$TMP_DIR/tsmanager.lock}
LOCKPIDFILE=${LOCKPIDFILE:-$LOCKDIR/pid}
LOCKMETA=${LOCKMETA:-$LOCKDIR/meta}
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

fail_hint() {
    # fail_hint "错误" "建议命令"
    log "错误：$1" >&2
    if [ -n "${2:-}" ]; then
        log "建议：$2" >&2
    fi
    exit 1
}

have() {
    command -v "$1" >/dev/null 2>&1
}

yes_value() {
    case "$1" in
        1|y|Y|yes|YES|Yes|true|TRUE|True|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

is_dry_run() {
    [ "$DRY_RUN" = 1 ]
}

trim_log_if_needed() {
    f=$1
    [ -f "$f" ] || return 0
    # BusyBox 可能没有 stat；用 wc -c
    sz=$(wc -c <"$f" 2>/dev/null | tr -d ' ' || printf '0')
    case "$sz" in
        ''|*[!0-9]*) return 0 ;;
    esac
    max=$((LOG_MAX_KB * 1024))
    if [ "$sz" -gt "$max" ]; then
        mv "$f" "$f.old" 2>/dev/null || true
        : >"$f"
        log "日志超限已轮转：$f -> $f.old"
    fi
}

scan_env_suspicious() {
    [ -f "$ENV_FILE" ] || return 0
    if grep -E '\$\(|`|;\s*rm |;\s*wget |;\s*curl ' "$ENV_FILE" >/dev/null 2>&1; then
        log "警告：$ENV_FILE 含可疑命令替换/串联语法；.env 等同 root 配置，请人工检查"
    fi
}

normalize_legacy_config() {
    # 旧版 .env 可能保存过 CDN_BASE=...@cdn/latest，或保存了由它生成的
    # PACKAGE_URL=...@cdn/latest/latest/...。CDN_BASE 现在是脚本内部常量，
    # 这里强制恢复并修正旧 URL，避免重复 latest 导致 404。
    # schema v1->v2：清理重复 latest、迁移 TS_PACKAGE_URL、忽略校验 URL。
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
    case "$PACKAGE_URL" in
        *'cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/tailscale-small_latest_'*.tar.gz)
            if [ "${VERSION:-latest}" != latest ]; then
                old_package_url=$PACKAGE_URL
                PACKAGE_URL=''
                CONFIG_NORMALIZED=1
                log "检测到 PACKAGE_URL 固定为 latest，但 VERSION=${VERSION}；已清空 PACKAGE_URL，让版本选择生效：$old_package_url"
            fi
            ;;
    esac
}

normalize_legacy_config
scan_env_suspicious

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
        fail_hint "$dir 剩余空间 ${kb}KB，不足 ${min_kb}KB" "清理 $dir 后重试，或调低 MIN_TMP_FREE_KB/MIN_DATA_FREE_KB"
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

pid_alive() {
    pid=$1
    [ -n "$pid" ] || return 1
    kill -0 "$pid" >/dev/null 2>&1
}

# 优先用 /proc/PID/cmdline 匹配本项目路径，避免误杀系统 tailscaled
pid_is_ours() {
    pid=$1
    [ -n "$pid" ] || return 1
    pid_alive "$pid" || return 1

    if [ -r "/proc/$pid/cmdline" ]; then
        # cmdline 以 \0 分隔
        cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)
        case "$cmd" in
            *"$DAEMON"*|*"$BIN"*|*"$TMP_DIR/tailscaled"*|*"$TMP_DIR/tailscale"*) return 0 ;;
        esac
        # 若 cmdline 可读但不匹配，不当作本项目进程
        return 1
    fi

    # 无 /proc 时退回 ps 文本匹配，并尽量要求路径线索
    ps 2>/dev/null | awk -v pid="$pid" -v d="$DAEMON" -v b="$BIN" -v t="$TMP_DIR" '
        $1 == pid {
            line=$0
            if (index(line, d) || index(line, b) || index(line, t "/tailscale")) found=1
            else if (line ~ /tailscale|tailscaled/) soft=1
        }
        END {
            if (found) exit 0
            if (soft) exit 0
            exit 1
        }
    '
}

pid_matches_daemon() {
    pid_is_ours "$1"
}

acquire_lock() {
    make_base_dirs
    if mkdir "$LOCKDIR" 2>/dev/null; then
        printf '%s\n' "$$" >"$LOCKPIDFILE"
        printf 'pid=%s\nscript=%s\ncmd=%s\ntime=%s\n' "$$" "$0" "$*" "$(now_epoch)" >"$LOCKMETA" 2>/dev/null || true
        LOCK_HELD=1
        return 0
    fi

    stale_pid=''
    if [ -f "$LOCKPIDFILE" ]; then
        stale_pid=$(cat "$LOCKPIDFILE" 2>/dev/null || true)
    fi
    if [ -n "$stale_pid" ] && ! pid_alive "$stale_pid"; then
        rm -f "$LOCKPIDFILE" "$LOCKMETA"
        rmdir "$LOCKDIR" 2>/dev/null || true
    elif [ -z "$stale_pid" ]; then
        rmdir "$LOCKDIR" 2>/dev/null || true
    fi

    if mkdir "$LOCKDIR" 2>/dev/null; then
        printf '%s\n' "$$" >"$LOCKPIDFILE"
        printf 'pid=%s\nscript=%s\ncmd=%s\ntime=%s\n' "$$" "$0" "$*" "$(now_epoch)" >"$LOCKMETA" 2>/dev/null || true
        LOCK_HELD=1
        return 0
    fi

    meta=''
    [ -f "$LOCKMETA" ] && meta=$(cat "$LOCKMETA" 2>/dev/null || true)
    fail_hint "已有另一个 tsmanager.sh 实例在运行${meta:+；锁信息：$meta}" "确认无任务后删除锁目录：$LOCKDIR"
}

release_lock() {
    if [ "$LOCK_HELD" = 1 ]; then
        rm -f "$LOCKPIDFILE" "$LOCKMETA"
        rmdir "$LOCKDIR" 2>/dev/null || true
        LOCK_HELD=0
    fi
}

cleanup_install_temps() {
    [ -n "$INSTALL_CLEANUP_PKG" ] && rm -f "$INSTALL_CLEANUP_PKG" 2>/dev/null || true
    [ -n "$INSTALL_CLEANUP_UNPACK" ] && rm -rf "$INSTALL_CLEANUP_UNPACK" 2>/dev/null || true
    INSTALL_CLEANUP_PKG=
    INSTALL_CLEANUP_UNPACK=
}

on_exit_cleanup() {
    cleanup_install_temps
    release_lock
}

run_locked() {
    acquire_lock "$*"
    trap 'on_exit_cleanup' EXIT INT TERM
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
        *) printf "%s" "$1" | sed "s/'/'\\\\''/g; 1s/^/'/; \$s/\$/'/" ;;
    esac
}

save_env() {
    make_base_dirs
    tmp="$ENV_FILE.$$"
    {
        echo "# tsmanager.sh 自动生成的配置文件"
        echo "# .env 等同 root 配置；不要从不可信来源粘贴内容。"
        printf 'ENV_SCHEMA_VERSION=%s\n' "$(quote_env "$SCRIPT_ENV_SCHEMA_VERSION")"
        printf 'DATA_DIR=%s\n' "$(quote_env "$DATA_DIR")"
        printf 'TMP_DIR=%s\n' "$(quote_env "$TMP_DIR")"
        printf 'STATEDIR=%s\n' "$(quote_env "$STATEDIR")"
        printf 'CONFIG=%s\n' "$(quote_env "$CONFIG")"
        # 仅在用户显式自定义时持久化 PACKAGE_URL；空值表示运行时按 VERSION+TARGET 推导
        if [ -n "$PACKAGE_URL" ]; then
            printf 'PACKAGE_URL=%s\n' "$(quote_env "$PACKAGE_URL")"
        fi
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

# 将当前脚本安装到 DATA_DIR，供 cron/service 统一引用
managed_script_path() {
    printf '%s/%s\n' "$DATA_DIR" "$SCRIPT_NAME"
}

install_self_script() {
    dest=$(managed_script_path)
    src=$0
    case "$src" in
        /*) ;;
        */*) src=$(pwd)/$src ;;
        *)
            if [ -f "$dest" ]; then
                src=$dest
            elif have "$SCRIPT_NAME"; then
                src=$(command -v "$SCRIPT_NAME")
            else
                src=$dest
            fi
            ;;
    esac

    make_base_dirs
    if [ ! -f "$src" ]; then
        log "警告：找不到当前脚本源文件，跳过自安装（期望路径：$src）"
        return 0
    fi

    if [ -f "$dest" ] && cmp -s "$src" "$dest" >/dev/null 2>&1; then
        chmod 0755 "$dest" 2>/dev/null || true
        return 0
    fi

    # 避免把目标复制到自己
    if [ "$src" = "$dest" ]; then
        chmod 0755 "$dest" 2>/dev/null || true
        return 0
    fi

    cp "$src" "$dest.new"
    chmod 0755 "$dest.new"
    mv "$dest.new" "$dest"
    log "管理脚本已安装到 $dest"
}

script_abs_path() {
    # 优先使用已安装的持久脚本路径
    dest=$(managed_script_path)
    if [ -f "$dest" ]; then
        printf '%s\n' "$dest"
        return 0
    fi
    case "$0" in
        /*) printf '%s\n' "$0" ;;
        */*) oldpwd=$(pwd 2>/dev/null || printf '.'); printf '%s/%s\n' "$oldpwd" "$0" ;;
        *) printf '%s\n' "$dest" ;;
    esac
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
    if [ -n "$CACHED_TARGET" ]; then
        printf '%s\n' "$CACHED_TARGET"
        return 0
    fi
    if [ -n "$TARGET" ]; then
        CACHED_TARGET=$TARGET
        printf '%s\n' "$TARGET"
        return 0
    fi

    os=$(uname -s 2>/dev/null || printf unknown)
    case "$os" in
        Linux|linux) ;;
        *) fail_hint "当前系统不是 Linux，无法自动选择 tailscale-small 包" "设置 TARGET=linux-arm64 或 PACKAGE_URL=..." ;;
    esac

    arch=$(cpu_arch)
    result=
    case "$arch" in
        x86_64|amd64) result=linux-amd64 ;;
        i386|i486|i586|i686) result=linux-386 ;;
        aarch64|arm64) result=linux-arm64 ;;
        armv7l|armv7*|armv8l) result=linux-arm-v7 ;;
        armv6l|armv6*) result=linux-arm-v6 ;;
        armv5l|armv5*|armel) result=linux-arm-v5 ;;
        arm*)
            v=$(arm_version_from_cpuinfo || true)
            case "$v" in
                8|7) result=linux-arm-v7 ;;
                6) result=linux-arm-v6 ;;
                5) result=linux-arm-v5 ;;
                *) fail_hint "无法识别 ARM 版本：uname -m=$arch" "设置 TARGET=linux-arm-v7/linux-arm-v6/linux-arm-v5 后重试；或执行 doctor" ;;
            esac
            ;;
        mipsel|mipsle) result=linux-mipsle-softfloat ;;
        mips) result=linux-mips-softfloat ;;
        mips64el|mips64le) result=linux-mips64le-softfloat ;;
        riscv64) result=linux-riscv64 ;;
        *) fail_hint "不支持或无法识别的 CPU 架构：$arch" "设置 TARGET 或 PACKAGE_URL；执行 doctor 查看详情" ;;
    esac
    CACHED_TARGET=$result
    printf '%s\n' "$result"
}

# ──────────────────────────── 版本/URL 解析 ────────────────────────────

fetch_release_tags() {
    if [ -n "$CACHED_RELEASE_TAGS" ]; then
        printf '%s\n' "$CACHED_RELEASE_TAGS"
        return 0
    fi
    tags=
    if have curl; then
        tags=$(curl -fsSL --connect-timeout 5 --max-time 10 "$GITHUB_API" 2>/dev/null | \
            sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p') || true
    elif have wget; then
        tags=$(wget -qO- --timeout=10 "$GITHUB_API" 2>/dev/null | \
            sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p') || true
    else
        return 1
    fi
    CACHED_RELEASE_TAGS=$tags
    printf '%s\n' "$tags"
}

# 解析实际下载版本：
# - latest：直接 latest
# - 固定版本：默认信任本地配置，不因列表缺失静默改写
# - 仅当 VERSION_FALLBACK=1 且列表可取且不含该版本时，才回退 latest
resolve_version() {
    if [ -n "$CACHED_RESOLVED_VERSION" ]; then
        printf '%s\n' "$CACHED_RESOLVED_VERSION"
        return 0
    fi

    if [ "$VERSION" = latest ]; then
        CACHED_RESOLVED_VERSION=latest
        printf '%s\n' latest
        return 0
    fi

    if yes_value "$VERSION_FALLBACK"; then
        tags=$(fetch_release_tags 2>/dev/null || true)
        if [ -n "$tags" ]; then
            if printf '%s\n' "$tags" | grep -Fxq "$VERSION"; then
                CACHED_RESOLVED_VERSION=$VERSION
                printf '%s\n' "$VERSION"
                return 0
            fi
            log "VERSION_FALLBACK=1 且指定版本 $VERSION 不在线上列表，回退到 latest"
            CACHED_RESOLVED_VERSION=latest
            printf '%s\n' latest
            return 0
        fi
        log "VERSION_FALLBACK=1 但无法获取版本列表，按本地 VERSION=$VERSION 继续"
    fi

    CACHED_RESOLVED_VERSION=$VERSION
    printf '%s\n' "$VERSION"
}

cdn_package_url() {
    version=$1
    target=$2
    printf '%s/%s/tailscale-small_%s_%s.tar.gz\n' "$CDN_BASE" "$version" "$version" "$target"
}

github_package_url() {
    version=$1
    target=$2
    # latest 在 GitHub Releases 没有同名 tag 目录；需要解析真实 tag
    if [ "$version" = latest ]; then
        tags=$(fetch_release_tags 2>/dev/null || true)
        real=$(printf '%s\n' "$tags" | head -n 1)
        if [ -z "$real" ]; then
            return 1
        fi
        version=$real
    fi
    printf '%s/%s/tailscale-small_%s_%s.tar.gz\n' "$DEFAULT_GITHUB_RELEASE_BASE" "$version" "$version" "$target"
}

effective_package_url() {
    if [ -n "$PACKAGE_URL" ]; then
        printf '%s\n' "$PACKAGE_URL"
        return 0
    fi
    target=$(detect_target)
    version=$(resolve_version)
    cdn_package_url "$version" "$target"
}

package_url_candidates() {
    # 输出候选 URL 列表（主源 + 备用），供下载失败回退
    if [ -n "$PACKAGE_URL" ]; then
        printf '%s\n' "$PACKAGE_URL"
        # 自定义 URL 失败时仍尝试按 VERSION 推导官方源
        target=$(detect_target 2>/dev/null || true)
        version=$(resolve_version 2>/dev/null || true)
        if [ -n "$target" ] && [ -n "$version" ]; then
            u=$(cdn_package_url "$version" "$target")
            [ "$u" = "$PACKAGE_URL" ] || printf '%s\n' "$u"
            gu=$(github_package_url "$version" "$target" 2>/dev/null || true)
            if [ -n "$gu" ] && [ "$gu" != "$PACKAGE_URL" ] && [ "$gu" != "$u" ]; then
                printf '%s\n' "$gu"
            fi
        fi
        return 0
    fi
    target=$(detect_target)
    version=$(resolve_version)
    cdn_package_url "$version" "$target"
    gu=$(github_package_url "$version" "$target" 2>/dev/null || true)
    [ -n "$gu" ] && printf '%s\n' "$gu"
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

ask_yes_no_config_default_no() {
    text=$1
    printf '  %s [y/N]: ' "$text" >&2
    if read ans; then
        case "$ans" in
            y|Y|yes|YES|Yes) return 0 ;;
        esac
    fi
    return 1
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

ask_yes_no_default_yes() {
    text=$1
    if [ -t 0 ]; then
        printf '%s [Y/n]: ' "$text" >&2
        if read ans; then
            if [ -z "$ans" ]; then
                return 0
            fi
            yes_value "$ans"
            return $?
        fi
        return 0
    fi
    return 0
}

print_next_steps() {
    script=$(managed_script_path)
    cat >&2 <<EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  下一步：
  1) 查看状态：  $script status
  2) 登录组网：  $script up
     或：        $CLI --socket=$SOCKET up
  3) 自启状态：  $script boot-status
  4) 环境诊断：  $script doctor
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
}

configure_interactive() {
    make_base_dirs
    # 用 cpu_arch 展示架构（永不失败），避免非 Linux 上 detect_target 退出
    displayed_arch=$(cpu_arch)

    cat >&2 <<INTRO

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Tailscale 极简版 (tailscale-small) 路由器安装向导
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  检测到 CPU 架构：$displayed_arch

  说明：
  · 每项都会显示 [默认值]，直接按回车即可使用默认。
  · POSIX sh 不支持方向键/光标移动 — 输入错误请用
    Backspace 删掉后重新输入。
  · .env 等同 root 配置；AUTH_KEY 默认不写入磁盘。
INTRO

    ask_value STATEDIR \
        "状态目录（持久保存 Tailscale 身份和密钥）" \
        "$STATEDIR"

    ask_value CONFIG \
        "Tailscale 配置文件路径（可留空）" \
        "$CONFIG" \
        "  非空时会传给 tailscaled --config，一般不需要。"

    cat >&2 <<'VERINTRO'

  ── 版本选择 ──
    latest    始终跟随最新发布（默认，推荐）
    固定版本  例如 v1.100.0 — 下载 404 时不会静默升级
              （若需自动回退 latest，设置 VERSION_FALLBACK=1）
VERINTRO

    # 尝试展示最近版本，失败不阻塞
    tags=$(fetch_release_tags 2>/dev/null || true)
    if [ -n "$tags" ]; then
        printf '  线上最近版本：' >&2
        printf '%s\n' "$tags" | head -n 5 | tr '\n' ' ' >&2
        printf '\n' >&2
    else
        printf '  （无法拉取线上版本列表，可继续使用 latest 或手写版本号）\n' >&2
    fi

    ask_value VERSION \
        "Tailscale 版本" \
        "$VERSION"

    # 版本变更后清缓存
    CACHED_RESOLVED_VERSION=
    default_target=$(detect_target)
    derived_version=$(resolve_version)
    derived_package=$(cdn_package_url "$derived_version" "$default_target")

    cat >&2 <<PKGINTRO

  ── 下载设置 ──
  默认使用 VERSION + 架构自动生成下载地址：
    $derived_package

  只有在你有私有镜像、内网 HTTP 或手写 tar.gz 地址时，才需要自定义下载 URL。
  一旦启用自定义 URL，PACKAGE_URL 会优先于 VERSION。
PKGINTRO

    if ask_yes_no_config_default_no "是否使用自定义下载 URL？默认否，直接使用上面的自动地址"; then
        while :; do
            ask_value PACKAGE_URL \
                "自定义下载地址" \
                "$PACKAGE_URL" \
                "  请输入完整 .tar.gz URL；此模式下 VERSION 只记录，不参与下载。"
            if [ -n "$PACKAGE_URL" ]; then
                break
            fi
            printf '  自定义 URL 不能为空。可再输入，或选 n 取消自定义。\n' >&2
            if ! ask_yes_no_config_default_no "继续输入自定义 URL？"; then
                PACKAGE_URL=''
                break
            fi
        done
    else
        PACKAGE_URL=''
    fi

    if [ -z "$PACKAGE_URL" ]; then
        summary_package=$derived_package
    else
        summary_package=$PACKAGE_URL
    fi

    # 确认摘要
    echo >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo "  配置摘要：" >&2
    echo "  · 状态目录：$STATEDIR" >&2
    echo "  · 配置文件：${CONFIG:-(空)}" >&2
    echo "  · 版　　本：$VERSION -> 解析为 $derived_version" >&2
    echo "  · 下载地址：$summary_package" >&2
    if [ -z "$PACKAGE_URL" ]; then
        echo "  · 下载模式：自动（VERSION + 架构生成，不把 URL 固化进 .env）" >&2
    else
        echo "  · 下载模式：自定义 PACKAGE_URL（优先于 VERSION）" >&2
    fi
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
    # PACKAGE_URL 只表示用户显式自定义下载源；留空时运行时由 VERSION + TARGET 自动生成。
    make_base_dirs
    save_env
}

# ──────────────────────────── 下载 & 解压 ──────────────────────────────

looks_like_html_error() {
    f=$1
    [ -f "$f" ] || return 1
    head -c 200 "$f" 2>/dev/null | grep -qiE '<html|<!doctype'
}

download_file_once() {
    url=$1
    out=$2
    log "尝试下载：$url"
    rm -f "$out"
    if have curl; then
        errf="$TMP_DIR/curl.err.$$"
        mkdir -p "$TMP_DIR" 2>/dev/null || true
        http_code=$(curl -L --connect-timeout 10 --retry 2 -o "$out" -w '%{http_code}' "$url" 2>"$errf" || true)
        if [ "${http_code:-}" = 200 ] && [ -f "$out" ] && [ -s "$out" ] && ! looks_like_html_error "$out"; then
            rm -f "$errf"
            return 0
        fi
        err=$(cat "$errf" 2>/dev/null || true)
        rm -f "$errf" "$out"
        log "下载失败：$url http=${http_code:-?} ${err}"
        return 1
    elif have wget; then
        errf="$TMP_DIR/wget.err.$$"
        mkdir -p "$TMP_DIR" 2>/dev/null || true
        if wget -O "$out" "$url" 2>"$errf"; then
            if [ -f "$out" ] && [ -s "$out" ] && ! looks_like_html_error "$out"; then
                rm -f "$errf"
                return 0
            fi
            log "下载内容无效（空或 HTML 错误页）：$url"
            rm -f "$errf" "$out"
            return 1
        fi
        err=$(cat "$errf" 2>/dev/null || true)
        rm -f "$errf" "$out"
        log "下载失败：$url ${err}"
        return 1
    elif have busybox && busybox wget --help >/dev/null 2>&1; then
        if busybox wget -O "$out" "$url"; then
            if [ -f "$out" ] && [ -s "$out" ] && ! looks_like_html_error "$out"; then
                return 0
            fi
            log "下载内容无效（空或 HTML 错误页）：$url"
            rm -f "$out"
            return 1
        fi
        log "下载失败：$url (busybox wget)"
        rm -f "$out"
        return 1
    else
        fail_hint "需要 curl、wget 或 busybox wget 才能下载" "安装 curl/wget 后重试"
    fi
}

download_file() {
    out=$1
    shift
    # 剩余参数为候选 URL；若无参数则内部生成
    if [ "$#" -eq 0 ]; then
        # shellcheck disable=SC2046
        set -- $(package_url_candidates)
    fi
    last_err=
    for url in "$@"; do
        [ -n "$url" ] || continue
        if download_file_once "$url" "$out"; then
            log "下载成功：$url"
            return 0
        fi
        last_err=$url
        log "主/备源失败，尝试下一个：$url"
    done
    fail_hint "所有下载源均失败（最后尝试：$last_err）" "检查网络/DNS，或设置 PACKAGE_URL=...；执行 doctor"
}

extract_package() {
    pkg=$1
    dst=$2
    rm -rf "$dst"
    mkdir -p "$dst"
    errf="$TMP_DIR/tar.err.$$"
    if tar -xzf "$pkg" -C "$dst" 2>"$errf"; then
        rm -f "$errf"
        return 0
    fi
    if have busybox && busybox tar -xzf "$pkg" -C "$dst" 2>>"$errf"; then
        rm -f "$errf"
        return 0
    fi
    log "解压错误详情：$(cat "$errf" 2>/dev/null | tail -n 5)"
    rm -f "$errf"
    fail_hint "解压失败：$pkg" "确认是 tailscale-small 的 .tar.gz；清理 $TMP_DIR 后重试"
}

validate_binary_candidate() {
    src=$1
    [ -f "$src" ] || return 1
    chmod 0755 "$src" 2>/dev/null || true
    [ -x "$src" ] || return 1
    # 轻量探测：version/help；失败则拒绝
    if "$src" version >/dev/null 2>&1; then
        return 0
    fi
    if "$src" --help >/dev/null 2>&1; then
        return 0
    fi
    # 某些 combined binary 可能需要 argv0；仍至少要求是可执行非空文件
    sz=$(wc -c <"$src" 2>/dev/null | tr -d ' ' || printf '0')
    case "$sz" in
        ''|*[!0-9]*) return 1 ;;
    esac
    # 小于 1MB 基本不可能是 tailscale
    if [ "$sz" -lt 1000000 ]; then
        return 1
    fi
    # 有 exec 位且体积合理则放行，但打警告
    log "警告：无法执行 version/help，但文件体积合理，继续安装：$src ($sz bytes)"
    return 0
}

rollback_binary_if_possible() {
    if [ -f "$TMP_DIR/tailscale.old" ]; then
        cp "$TMP_DIR/tailscale.old" "$BIN.new" 2>/dev/null || return 1
        chmod 0755 "$BIN.new"
        mv "$BIN.new" "$BIN"
        ln -sf tailscale "$DAEMON"
        log "已从 tailscale.old 回滚二进制"
        return 0
    fi
    return 1
}

install_package() {
    ensure_config auto
    make_base_dirs
    install_self_script
    check_space "$DATA_DIR" "$MIN_DATA_FREE_KB"
    check_space "$TMP_DIR" "$MIN_TMP_FREE_KB"

    if is_dry_run; then
        log "[dry-run] 将下载并安装："
        package_url_candidates | while read -r u; do
            [ -n "$u" ] && log "[dry-run] 候选 URL: $u"
        done
        log "[dry-run] TARGET=$(detect_target 2>/dev/null || echo unknown) VERSION=$(resolve_version)"
        log "[dry-run] BIN=$BIN DAEMON=$DAEMON"
        return 0
    fi

    pkg="$TMP_DIR/tailscale-package.$$.tar.gz"
    unpack="$TMP_DIR/unpack.$$"
    INSTALL_CLEANUP_PKG=$pkg
    INSTALL_CLEANUP_UNPACK=$unpack
    rm -rf "$pkg" "$unpack"

    # 收集候选 URL
    cand_file="$TMP_DIR/urls.$$"
    package_url_candidates >"$cand_file"
    # shellcheck disable=SC2046
    set -- $(cat "$cand_file")
    rm -f "$cand_file"

    download_file "$pkg" "$@"

    # 下载后再检空间：包体积 * 倍数
    pkg_kb=$(( $(wc -c <"$pkg" | tr -d ' ') / 1024 + 1 ))
    need_kb=$((pkg_kb * MIN_PKG_FREE_MULTIPLIER))
    if [ "$need_kb" -lt "$MIN_TMP_FREE_KB" ]; then
        need_kb=$MIN_TMP_FREE_KB
    fi
    free_now=$(free_kb "$TMP_DIR" || printf '0')
    case "$free_now" in
        ''|*[!0-9]*) free_now=0 ;;
    esac
    # 已下载占用空间，粗略要求剩余仍够解压
    if [ "$free_now" -lt "$pkg_kb" ]; then
        fail_hint "$TMP_DIR 下载后剩余 ${free_now}KB，可能不够解压（包约 ${pkg_kb}KB）" "清理 $TMP_DIR 后重试"
    fi

    extract_package "$pkg" "$unpack"

    src=""
    if [ -f "$unpack/tailscale" ]; then
        src="$unpack/tailscale"
    elif [ -f "$unpack/tailscale.combined" ]; then
        src="$unpack/tailscale.combined"
    else
        fail_hint "压缩包里没有 tailscale" "检查 PACKAGE_URL/VERSION/TARGET；执行 doctor"
    fi

    if ! validate_binary_candidate "$src"; then
        fail_hint "压缩包内二进制校验失败（不可执行或体积异常）" "勿覆盖；检查下载源是否返回了错误页"
    fi

    binary_changed=0
    if [ -f "$BIN" ] && cmp -s "$src" "$BIN" >/dev/null 2>&1; then
        log "二进制已是最新，跳过覆盖：$BIN"
    else
        binary_changed=1
        if [ -f "$BIN" ]; then
            cp "$BIN" "$TMP_DIR/tailscale.old" 2>/dev/null || true
        fi
        cp "$src" "$BIN.new"
        chmod 0755 "$BIN.new"
        if ! validate_binary_candidate "$BIN.new"; then
            rm -f "$BIN.new"
            fail_hint "新二进制落盘后校验失败，已中止覆盖" "保留旧二进制；检查包完整性"
        fi
        mv "$BIN.new" "$BIN"
        log "已安装 $BIN"
    fi

    ln -sf tailscale "$DAEMON"
    cleanup_install_temps

    if [ "$binary_changed" = 1 ] && is_running; then
        NEED_RESTART_AFTER_INSTALL=1
        log "检测到二进制已更新且进程仍在运行，将在安装流程结束后重启"
    fi
}

# ──────────────────────────── 进程管理 ─────────────────────────────────

files_ok() {
    [ -x "$BIN" ] && [ ! -L "$BIN" ] && [ -L "$DAEMON" ] && [ -x "$DAEMON" ]
}

find_pid() {
    # 1) PID 文件且确认为本项目进程
    if [ -f "$PIDFILE" ]; then
        pid=$(cat "$PIDFILE" 2>/dev/null || true)
        if pid_is_ours "$pid"; then
            printf '%s\n' "$pid"
            return 0
        fi
        # 过期 pidfile
        if [ -n "$pid" ] && ! pid_alive "$pid"; then
            rm -f "$PIDFILE"
        fi
    fi

    # 2) 扫描进程表，要求路径命中本项目目录
    if [ -d /proc ]; then
        for cmdf in /proc/[0-9]*/cmdline; do
            [ -r "$cmdf" ] || continue
            pid=$(printf '%s' "$cmdf" | sed -n 's#/proc/\([0-9]*\)/cmdline#\1#p')
            [ -n "$pid" ] || continue
            cmd=$(tr '\0' ' ' <"$cmdf" 2>/dev/null || true)
            case "$cmd" in
                *"$DAEMON"*|*"$TMP_DIR/tailscaled"*|*"$TMP_DIR/tailscale "*)
                    if pid_alive "$pid"; then
                        printf '%s\n' "$pid"
                        return 0
                    fi
                    ;;
            esac
        done
    fi

    # 3) 无 /proc 时用 ps，尽量匹配 TMP_DIR
    pid=$(ps 2>/dev/null | awk -v t="$TMP_DIR" '
        $0 ~ t "/tailscaled" || $0 ~ t "/tailscale" {
            print $1
            exit
        }
    ' || true)
    if [ -n "$pid" ] && pid_alive "$pid"; then
        printf '%s\n' "$pid"
        return 0
    fi

    return 1
}

is_running() {
    pid=$(find_pid || true)
    [ -n "$pid" ] && pid_alive "$pid"
}

build_daemon_cmd() {
    # 输出到 stdout 不方便带空格参数；用全局拼接函数直接 exec/start
    :
}

start_daemon_process() {
    # 后台启动 tailscaled，写入 PIDFILE
    set -- "$DAEMON" "--statedir=$STATEDIR" "--socket=$SOCKET"
    if [ -n "$CONFIG" ]; then
        set -- "$@" "--config=$CONFIG"
    fi
    # shellcheck disable=SC2086
    set -- "$@" $TAILSCALED_ARGS

    trim_log_if_needed "$LOGFILE"
    if have setsid; then
        setsid "$@" >>"$LOGFILE" 2>&1 </dev/null &
    elif have nohup; then
        nohup "$@" >>"$LOGFILE" 2>&1 </dev/null &
    else
        "$@" >>"$LOGFILE" 2>&1 </dev/null &
    fi
    pid=$!
    printf '%s\n' "$pid" >"$PIDFILE"
    printf '%s\n' "$pid"
}

wait_daemon_ready() {
    pid=$1
    i=0
    while [ "$i" -lt "$START_WAIT_SECONDS" ]; do
        if ! pid_alive "$pid"; then
            return 1
        fi
        if [ -S "$SOCKET" ]; then
            return 0
        fi
        # 即使 socket 稍慢，pid 存活超过一半时间也先接受，继续等 socket
        sleep 1
        i=$((i + 1))
    done
    # 超时：进程还在则视为弱成功（某些系统 socket 路径权限慢）
    if pid_alive "$pid"; then
        if [ -S "$SOCKET" ]; then
            return 0
        fi
        log "警告：等待 ${START_WAIT_SECONDS}s 后进程仍在，但 socket 未出现：$SOCKET"
        return 0
    fi
    return 1
}

start_tailscaled() {
    ensure_config auto
    make_base_dirs
    make_run_dir
    install_self_script
    files_ok || install_package

    if is_dry_run; then
        log "[dry-run] 将启动 tailscaled：statedir=$STATEDIR socket=$SOCKET args=$TAILSCALED_ARGS"
        return 0
    fi

    if start_error_active; then
        tail -n 20 "$ERROR_FILE" 2>/dev/null || true
        fail_hint "检测到启动熔断" "修复问题后执行：$0 clear-error ，再 start"
    fi

    if is_running; then
        log "tailscaled 已运行，pid $(find_pid)"
        return 0
    fi

    rm -f "$SOCKET"
    log "启动 tailscaled"
    pid=$(start_daemon_process)

    if wait_daemon_ready "$pid"; then
        pid_is_ours "$pid" || log "警告：进程已存活，但未严格匹配项目路径；继续视为启动成功"
        clear_start_state
        log "tailscaled 已启动，pid $pid"
        if [ ! -S "$SOCKET" ]; then
            log "提示：socket 尚未就绪，可稍后执行 login-status / doctor tailscale"
        fi
    else
        tail -n 40 "$LOGFILE" 2>/dev/null || true
        # 尝试回滚旧二进制再启动一次
        if rollback_binary_if_possible; then
            log "使用回滚二进制重试启动"
            rm -f "$SOCKET"
            pid=$(start_daemon_process)
            if wait_daemon_ready "$pid"; then
                clear_start_state
                log "回滚后 tailscaled 已启动，pid $pid"
                return 0
            fi
            tail -n 40 "$LOGFILE" 2>/dev/null || true
        fi
        record_start_failure "tailscaled 启动失败"
        fail_hint "tailscaled 启动失败" "查看 $LOGFILE ；修复后 clear-error 再 start；检查 /dev/net/tun 与权限"
    fi
}

stop_tailscaled() {
    if is_dry_run; then
        log "[dry-run] 将停止 tailscaled"
        return 0
    fi
    pid=$(find_pid || true)
    if [ -z "$pid" ]; then
        log "tailscaled 未运行"
        rm -f "$PIDFILE" "$SOCKET"
        return 0
    fi

    log "停止 tailscaled，pid $pid"
    kill "$pid" >/dev/null 2>&1 || true
    i=0
    while [ "$i" -lt 10 ]; do
        if ! pid_alive "$pid"; then
            rm -f "$PIDFILE" "$SOCKET"
            log "tailscaled 已停止"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done

    kill -9 "$pid" >/dev/null 2>&1 || true
    rm -f "$PIDFILE" "$SOCKET"
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

remove_backend_artifacts() {
    # 清理各 backend 残留，避免切换 backend 后双保活
    for b in procd systemd openrc; do
        p=$(service_real_path "$b")
        if [ -n "$p" ] && [ -f "$p" ]; then
            # SERVICE_ROOT 下或真实路径
            rm -f "$p"
            log "已移除残留 service 文件：$p"
        fi
    done
    # 也尝试无 SERVICE_ROOT 的真实路径
    rm -f "/etc/init.d/$SERVICE_NAME" \
        "/etc/systemd/system/$SERVICE_NAME.service" 2>/dev/null || true
    remove_cron 2>/dev/null || true
}

daemon_start_foreground() {
    ensure_config auto
    make_base_dirs
    make_run_dir
    install_self_script
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
    eend \$?
}
EOF
    chmod 0755 "$path" 2>/dev/null || true
    log "OpenRC service 已写入：$path"
}

service_install() {
    ensure_config auto
    install_self_script
    backend=$(detect_boot_backend)
    # 安装前清理其他 backend，防止双保活
    if [ "$backend" != manual ]; then
        # 只清「非目标」产物
        case "$backend" in
            cron)
                for b in procd systemd openrc; do
                    p=$(service_real_path "$b")
                    [ -n "$p" ] && [ -f "$p" ] && rm -f "$p" && log "切换到 cron，移除 $p"
                done
                ;;
            procd|systemd|openrc)
                remove_cron 2>/dev/null || true
                for b in procd systemd openrc; do
                    [ "$b" = "$backend" ] && continue
                    p=$(service_real_path "$b")
                    [ -n "$p" ] && [ -f "$p" ] && rm -f "$p" && log "切换 backend，移除 $p"
                done
                ;;
        esac
    fi
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
        procd)
            if /etc/init.d/$SERVICE_NAME enable 2>/dev/null; then
                log "procd service 已 enable"
            else
                log "警告：procd enable 失败，回退为仅 cron 保活（避免双通道会先移除失败的依赖）"
                # enable 失败时不要保留「半吊子」service + cron 双开：移除 service 文件再写 cron
                rm -f "$(service_real_path procd)" 2>/dev/null || true
                write_cron
            fi
            ;;
        systemd)
            systemctl daemon-reload 2>/dev/null || true
            if systemctl enable "$SERVICE_NAME.service" 2>/dev/null; then
                log "systemd unit 已 enable"
            else
                log "警告：systemd enable 失败，回退 cron 保活"
                rm -f "$(service_real_path systemd)" 2>/dev/null || true
                write_cron
            fi
            ;;
        openrc)
            if rc-update add "$SERVICE_NAME" default 2>/dev/null; then
                log "OpenRC service 已加入 default"
            else
                log "警告：OpenRC enable 失败，回退 cron 保活"
                rm -f "$(service_real_path openrc)" 2>/dev/null || true
                write_cron
            fi
            ;;
        cron) write_cron ;;
        manual) log "BOOT_BACKEND=manual，跳过 enable" ;;
    esac
}

disable_autostart() {
    # 对称关闭：尽量清理所有 backend 产物
    backend=$(detect_boot_backend)
    if [ -n "$SERVICE_ROOT" ]; then
        remove_backend_artifacts
        return 0
    fi
    case "$backend" in
        procd) /etc/init.d/$SERVICE_NAME disable 2>/dev/null || true ;;
        systemd) systemctl disable "$SERVICE_NAME.service" 2>/dev/null || true; systemctl daemon-reload 2>/dev/null || true ;;
        openrc) rc-update del "$SERVICE_NAME" default 2>/dev/null || true ;;
    esac
    remove_backend_artifacts
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
    # 残留探测
    for b in procd systemd openrc; do
        p=$(service_real_path "$b")
        if [ -n "$p" ] && [ -f "$p" ] && [ "$b" != "$backend" ]; then
            printf 'residual_service_%s=%s\n' "$b" "$p"
        fi
    done
    if [ "$backend" != cron ] && cron_is_written 2>/dev/null; then
        printf 'residual_cron=present\n'
    fi
    script=$(managed_script_path)
    if [ -f "$script" ]; then
        printf 'managed_script=present path=%s\n' "$script"
    else
        printf 'managed_script=missing path=%s\n' "$script"
        printf 'hint=run install/enable to install script into DATA_DIR\n'
    fi
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
    fail_hint "找不到可写的定时任务位置" "设置 CRON_FILE=/path/to/cron 或安装 crontab"
}

cron_block() {
    script=$(managed_script_path)
    cat <<EOF
$CRON_BEGIN
# 每 5 分钟执行完整自愈流程：必要时安装 tailscale，然后启动 tailscaled。日志写到 /tmp，避免占用 /data。
*/5 * * * * mkdir -p "$TMP_DIR" && DATA_DIR="$DATA_DIR" TMP_DIR="$TMP_DIR" "$script" ensure >>"$MANAGER_LOG" 2>&1
$CRON_END
EOF
}

write_cron() {
    make_base_dirs
    install_self_script
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
    log "定时任务已写入（脚本路径：$(managed_script_path)）"
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

status_summary() {
    running=no
    is_running && running=yes
    files=missing
    files_ok && files=ok
    err=clear
    start_error_active && err=tripped
    backend=$(detect_boot_backend 2>/dev/null || printf unknown)
    auth=unset
    [ -n "$AUTH_KEY" ] && auth=set
    printf '== 摘要 ==\n'
    printf 'running=%s files=%s error=%s backend=%s auth_key=%s version=%s\n' \
        "$running" "$files" "$err" "$backend" "$auth" "$VERSION"
    if [ "$err" = tripped ]; then
        printf 'hint=执行 clear-error 后 start\n'
    fi
    if [ "$running" = no ]; then
        printf 'hint=执行 start 或 ensure\n'
    fi
    if [ "$files" = missing ]; then
        printf 'hint=执行 install 或 update\n'
    fi
    printf '== 详情 ==\n'
}

status() {
    make_base_dirs
    status_summary
    printf '持久目录 DATA_DIR=%s\n' "$DATA_DIR"
    printf '临时目录 TMP_DIR=%s\n' "$TMP_DIR"
    printf '环境文件 ENV_FILE=%s\n' "$ENV_FILE"
    printf 'ENV_SCHEMA_VERSION=%s\n' "$ENV_SCHEMA_VERSION"
    printf '二进制 BIN=%s\n' "$BIN"
    printf 'daemon 入口 DAEMON=%s\n' "$DAEMON"
    printf '状态目录 STATEDIR=%s\n' "$STATEDIR"
    printf '配置文件 CONFIG=%s\n' "$CONFIG"
    printf 'socket=%s\n' "$SOCKET"
    if [ -S "$SOCKET" ]; then
        printf 'socket_state=present\n'
    else
        printf 'socket_state=missing\n'
    fi
    printf '配置版本 VERSION=%s\n' "$VERSION"
    printf 'auth_key=%s\n' "$([ -n "$AUTH_KEY" ] && printf set || printf unset)"
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
        [ -f "$LOCKMETA" ] && sed 's/^/lock_/' "$LOCKMETA" 2>/dev/null || true
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
    if [ "$cfg_mode" = reconfigure ]; then
        if [ -t 0 ]; then
            configure_interactive
        else
            configure_batch
        fi
        return 0
    fi
    # stdin 非终端时也走默认配置，避免 pipe 场景下卡在交互分支
    log "未找到配置文件，使用默认配置生成；如需自定义，请先运行：$0 install 或 $0 config"
    save_env
    return 0
}

reconfigure_cmd() {
    if [ -f "$ENV_FILE" ] && [ -t 0 ]; then
        if ! ask_yes_no_default_yes "已存在 $ENV_FILE，是否重新配置？"; then
            log "保留现有配置"
            return 0
        fi
    fi
    # 强制走交互/批量重写
    if [ -t 0 ]; then
        configure_interactive
    else
        configure_batch
    fi
    install_self_script
    log "配置完成"
}

ensure_all() {
    ensure_config auto
    make_base_dirs
    install_self_script
    trim_log_if_needed "$MANAGER_LOG"
    trim_log_if_needed "$LOGFILE"
    if [ "$UPDATE_ON_ENSURE" = 1 ] || ! files_ok; then
        log "执行安装流程"
        install_package
    else
        log "tailscale 文件已存在，跳过下载安装"
    fi
    if [ "$NEED_RESTART_AFTER_INSTALL" = 1 ]; then
        log "二进制已更新，重启 tailscaled"
        stop_tailscaled
        start_tailscaled
        NEED_RESTART_AFTER_INSTALL=0
        return 0
    fi
    if ! is_running; then
        log "执行启动流程"
        start_tailscaled
    else
        log "tailscaled 已运行"
    fi
}

maybe_restart_after_install() {
    if [ "$NEED_RESTART_AFTER_INSTALL" = 1 ]; then
        log "安装更新了二进制，重启以加载新版本"
        stop_tailscaled
        start_tailscaled
        NEED_RESTART_AFTER_INSTALL=0
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
        if [ -f "$ENV_FILE" ] && [ -t 0 ] && [ "$install_batch_flag" != 1 ]; then
            printf '  检测到已有配置 %s\n' "$ENV_FILE" >&2
            if ask_yes_no_config_default_no "是否重新走安装向导？默认否，沿用现有配置"; then
                configure_interactive
            else
                ensure_config auto
            fi
        else
            ensure_config interactive
        fi
    fi

    install_self_script
    install_package
    case "$install_semantics" in
        only)
            log "安装完成：未启动 tailscaled，也未开启自启动/保活"
            maybe_restart_after_install
            ;;
        start)
            log "安装完成：按 install start 语义启动 tailscaled，不开启自启动/保活"
            if [ "$NEED_RESTART_AFTER_INSTALL" = 1 ]; then
                stop_tailscaled
                NEED_RESTART_AFTER_INSTALL=0
            fi
            start_tailscaled
            print_next_steps
            ;;
        enable|keepalive|autostart)
            log "安装完成：按 install enable 语义开启自启动/保活并启动 tailscaled"
            enable_autostart
            if [ "$NEED_RESTART_AFTER_INSTALL" = 1 ]; then
                stop_tailscaled
                NEED_RESTART_AFTER_INSTALL=0
            fi
            start_tailscaled
            print_next_steps
            ;;
    esac
}

update_all() {
    ensure_config auto
    install_self_script
    if is_dry_run; then
        log "[dry-run] update：将 stop -> install_package -> enable_autostart -> start"
        install_package
        return 0
    fi
    stop_tailscaled
    install_package
    enable_autostart
    start_tailscaled
    NEED_RESTART_AFTER_INSTALL=0
    print_next_steps
}

restart_all() {
    stop_tailscaled
    start_tailscaled
}

cron_all() {
    ensure_config auto
    install_self_script
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
    printf '== doctor 摘要 ==\n'
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
    script=$(managed_script_path)
    if [ -f "$script" ]; then
        printf 'managed_script=present\n'
    else
        printf 'managed_script=missing\n'
        printf 'suggest=%s install only -y\n' "$0"
    fi
    if [ -f "$ENV_FILE" ]; then
        printf 'env_file=present mode=%s\n' "$(ls -l "$ENV_FILE" 2>/dev/null | awk '{print $1}')"
    else
        printf 'env_file=missing\n'
        printf 'suggest=%s config\n' "$0"
    fi
    if start_error_active; then
        printf 'error_state=tripped\n'
        printf 'suggest=%s clear-error\n' "$0"
    else
        printf 'error_state=clear\n'
    fi
    if [ -d "$LOCKDIR" ]; then
        printf 'lock_state=locked\n'
        printf 'suggest=rm -rf %s  # 仅确认无其它实例时\n' "$LOCKDIR"
    else
        printf 'lock_state=unlocked\n'
    fi
    printf 'primary_url=%s\n' "$(effective_package_url 2>/dev/null || printf unknown)"
    printf 'url_candidates:\n'
    package_url_candidates 2>/dev/null | sed 's/^/  /' || true
    printf 'persistent_dir_candidates:\n'
    check_writable_dir "$DATA_DIR"
    [ "$DATA_DIR" != /data/tailscale ] && check_writable_dir /data/tailscale
    check_writable_dir /jffs/tailscale
    check_writable_dir /etc/storage/tailscale
    check_writable_dir /opt/tailscale
    boot_status
    if ! files_ok; then
        printf 'suggest=%s install\n' "$0"
    elif ! is_running; then
        printf 'suggest=%s start\n' "$0"
    fi
}

tailscale_up() {
    ensure_config auto
    make_base_dirs
    install_self_script
    files_ok || install_package
    is_running || start_tailscaled
    set -- "$CLI" "--socket=$SOCKET" up "$@"
    [ -n "$AUTH_KEY" ] && set -- "$@" "--auth-key=$AUTH_KEY"
    [ -n "$TS_HOSTNAME" ] && set -- "$@" "--hostname=$TS_HOSTNAME"
    [ -n "$ADVERTISE_ROUTES" ] && set -- "$@" "--advertise-routes=$ADVERTISE_ROUTES"
    [ -n "$ACCEPT_DNS" ] && set -- "$@" "--accept-dns=$ACCEPT_DNS"
    [ -n "$ACCEPT_ROUTES" ] && set -- "$@" "--accept-routes=$ACCEPT_ROUTES"
    [ -n "$EXIT_NODE" ] && set -- "$@" "--exit-node=$EXIT_NODE"
    if is_dry_run; then
        log "[dry-run] 将执行：$*"
        return 0
    fi
    "$@"
}

login_status() {
    ensure_config auto
    if ! is_running; then
        printf 'tailscaled=stopped\n'
        printf 'suggest=%s start\n' "$0"
        return 1
    fi
    if [ -x "$CLI" ]; then
        "$CLI" --socket="$SOCKET" status 2>/dev/null || true
    else
        printf 'tailscale_cli=missing\n'
        printf 'suggest=%s install\n' "$0"
    fi
}

state_dir_is_safe() {
    case "$STATEDIR" in
        ''|/|.|..|./|../) return 1 ;;
        /data|/tmp|/var|/etc|/usr|/bin|/sbin|/root|/home) return 1 ;;
        "$TMP_DIR"|"$TMP_DIR"/*) return 1 ;;
    esac
    # 鼓励落在 DATA_DIR 下
    case "$STATEDIR" in
        "$DATA_DIR"|"$DATA_DIR"/*) return 0 ;;
    esac
    if yes_value "${FORCE_RESET:-0}"; then
        return 0
    fi
    if [ -t 0 ]; then
        ask_yes_no_default_no "STATEDIR=$STATEDIR 不在 DATA_DIR 下，确认仍要删除？"
        return $?
    fi
    return 1
}

reset_state() {
    if ! state_dir_is_safe; then
        fail_hint "拒绝删除危险或不在 DATA_DIR 下的状态目录：$STATEDIR" "确认路径后设置 FORCE_RESET=1 再执行"
    fi
    stop_tailscaled
    rm -rf "$STATEDIR"
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
    printf 'auth_key=%s\n' "$([ -n "$AUTH_KEY" ] && printf set || printf unset)"
    if start_error_active; then
        printf 'error_state=tripped\n'
        printf 'suggest=%s clear-error\n' "$0"
    fi
    if have ping; then
        ping -c 1 -W 2 controlplane.tailscale.com >/dev/null 2>&1 && printf 'controlplane_ping=ok\n' || printf 'controlplane_ping=failed\n'
    else
        printf 'controlplane_ping=skipped_no_ping\n'
    fi
}

# ──────────────────────────── 卸载 ─────────────────────────────────────

remove_runtime_files() {
    rm -f "$BIN" "$DAEMON" "$PIDFILE" "$LOGFILE" "$SOCKET" \
        "$TMP_DIR/tailscale.old" \
        "$TMP_DIR/manager.log" \
        "$TMP_DIR/manager.log.old" \
        "$TMP_DIR/tailscaled.log.old" \
        "$FAILLOG" "$ERROR_FILE"
    rm -f "$TMP_DIR"/tailscale-package.*.tar.gz 2>/dev/null || true
    rm -rf "$TMP_DIR"/unpack.* 2>/dev/null || true
    rmdir "$RUN_DIR" 2>/dev/null || true
    rmdir "$TMP_DIR" 2>/dev/null || true
    log "运行时文件已清理"
}

remove_config_files() {
    rm -f "$ENV_FILE"
    if state_dir_is_safe; then
        rm -rf "$STATEDIR"
    else
        log "跳过危险 STATEDIR 删除：$STATEDIR"
    fi
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
    # 对称清理所有自启动 backend（不仅 cron）
    disable_autostart
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

# ──────────────────────────── selftest ─────────────────────────────────

selftest_cmd() {
    errors=0
    log "selftest: syntax/functions/paths"
    # 允许在非 Linux 开发机上跑 selftest
    TARGET=${TARGET:-linux-arm64}
    CACHED_TARGET=$TARGET

    for f in log fail have save_env detect_target resolve_version effective_package_url \
        install_package find_pid start_tailscaled stop_tailscaled enable_autostart \
        disable_autostart uninstall_all package_url_candidates install_self_script; do
        if ! type "$f" >/dev/null 2>&1; then
            log "missing function: $f"
            errors=$((errors + 1))
        fi
    done

    make_base_dirs || errors=$((errors + 1))
    if [ ! -d "$DATA_DIR" ] || [ ! -d "$TMP_DIR" ]; then
        log "base dirs missing"
        errors=$((errors + 1))
    fi

    q=$(quote_env "a'b")
    case "$q" in
        *"'"*) ;;
        *) log "quote_env unexpected: $q"; errors=$((errors + 1)) ;;
    esac

    VERSION=latest
    CACHED_RESOLVED_VERSION=
    v1=$(resolve_version)
    v2=$(resolve_version)
    [ "$v1" = latest ] && [ "$v2" = latest ] || { log "resolve_version latest failed"; errors=$((errors + 1)); }

    VERSION=v0.0.0-not-exist
    CACHED_RESOLVED_VERSION=
    VERSION_FALLBACK=0
    v3=$(resolve_version)
    [ "$v3" = "v0.0.0-not-exist" ] || { log "pinned version was rewritten to $v3"; errors=$((errors + 1)); }

    PACKAGE_URL=
    ENV_FILE="$TMP_DIR/selftest.env.$$"
    save_env
    if grep -q '^PACKAGE_URL=' "$ENV_FILE"; then
        log "empty PACKAGE_URL should not be persisted"
        errors=$((errors + 1))
    fi
    PACKAGE_URL='https://example.com/custom.tar.gz'
    save_env
    if ! grep -q '^PACKAGE_URL=' "$ENV_FILE"; then
        log "non-empty PACKAGE_URL should be persisted"
        errors=$((errors + 1))
    fi
    rm -f "$ENV_FILE"
    PACKAGE_URL=

    DRY_RUN=1
    if ! install_package; then
        log "dry-run install_package failed"
        errors=$((errors + 1))
    fi
    DRY_RUN=0

    if [ "$errors" -eq 0 ]; then
        log "selftest: PASS"
        return 0
    fi
    log "selftest: FAIL ($errors errors)"
    return 1
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
  update      重新下载安装并刷新自启动/保活，然后启动 tailscaled。
  start       启动 tailscaled；如果二进制缺失会先下载安装。
  stop        停止 tailscaled；未运行也返回成功。
  restart     重启 tailscaled。
  clear-error 清理启动失败熔断标记，允许再次自动拉起。
  service-install 安装当前系统推荐的自启动 service。
  service-remove  移除当前 backend 的自启动 service。
  enable      开启自启动/保活；原生 init 不可用时回退 cron。
  disable     关闭自启动/保活（清理全部 backend 残留）。
  boot-status 查看自启动 backend 状态与残留。
  doctor      环境诊断；doctor tailscale 检查 Tailscale 运行态。
  up          封装 tailscale up，自动带 socket。
  login-status 查看 Tailscale 登录/连接状态。
  reset-state 停止并删除 state 后重新启动。
  config|reconfigure  重新走配置向导/批量写 .env。
  uninstall   完整卸载：停止进程、移除全部自启动、删除运行时文件；
              交互选择是否删除配置和脚本。
  status      查看摘要 + 配置、文件、进程、空间、cron 和下载 URL。
  ensure      cron 使用：从 .env 读取配置，必要时安装并启动，幂等。
  cron        自动把定时任务写入系统 crontab，重复执行幂等。
  selftest    本地冒烟：关键函数、版本解析、.env 规则。
  help        显示此帮助。

全局选项：
  -y, --yes       非交互（install/config）
  -n, --dry-run   只打印将执行的关键动作，不下载/不改进程（部分命令）

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
  PACKAGE_URL=                  自定义下载地址（留空则 VERSION+架构自动生成）
  VERSION=latest                版本号（latest 或 v1.100.0）
  VERSION_FALLBACK=0            1=钉版本不存在时允许回退 latest
  MIN_DATA_FREE_KB=64           最小磁盘空间限制
  MIN_TMP_FREE_KB=12288
  TAILSCALED_ARGS='--tun=tailscale0'  tailscaled 额外参数
  UPDATE_ON_ENSURE=0            设为 1 时 cron 每次重新下载安装
  BOOT_BACKEND=auto             auto/procd/systemd/openrc/cron/manual
  START_FAIL_LIMIT=3            连续启动失败达到阈值后熔断
  START_FAIL_WINDOW=600         统计失败次数的时间窗口（秒）
  START_WAIT_SECONDS=15         启动后等待 socket 的秒数
  LOG_MAX_KB=512                日志轮转阈值

下载方式：
  留空 PACKAGE_URL = 自动检测架构，优先 jsDelivr CDN，失败回退 GitHub Releases：
    tailscale-small_<版本>_<目标>.tar.gz
  版本默认 latest。固定版本默认不会静默改写；404 时看日志并换源/版本。
  自定义 = 设置一个 tar.gz 下载地址即可。

目录策略：
  /data/tailscale -> 小文件：tsmanager.sh、.env、state/
  /tmp/tailscale  -> 二进制、下载包、解压目录、pid、日志
  socket -> /var/run/tailscale/tailscaled.sock

首次认证示例：
  /tmp/tailscale/tailscale --socket=/var/run/tailscale/tailscaled.sock up \
    --auth-key=tskey-... --hostname=router
  或：tsmanager.sh up
EOF
}

# 解析命令行
cmd=${1:-status}
global_yes=0
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)
            global_yes=1
            shift
            ;;
        -n|--dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            break
            ;;
    esac
done
cmd=${1:-status}
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
                -n|--dry-run)
                    DRY_RUN=1
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
                    fail "不支持的 install 参数：$1；可用：only/start/enable/keepalive/-y/-n"
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
        # 注意：全局已 shift 掉命令名，这里不要再 shift
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
    config|reconfigure|configure)
        if [ "$global_yes" = 1 ]; then
            run_locked configure_batch
        else
            run_locked reconfigure_cmd
        fi
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
    selftest)
        selftest_cmd
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
