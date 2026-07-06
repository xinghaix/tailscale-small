#!/bin/sh
# 路由器用 Tailscale 极简管理脚本。
# 兼容 POSIX sh / BusyBox sh。
#
# 目录策略：
#   /data/tailscale/tailscale-manager.sh   持久脚本
#   /data/tailscale/.env                   持久配置
#   /data/tailscale/state/                 持久状态目录
#   /tmp/tailscale/tailscale               大体积二进制
#   /tmp/tailscale/tailscaled -> tailscale daemon 入口软链
#   /tmp/tailscale/tailscaled.pid          进程号
#   /tmp/tailscale/tailscaled.log          守护进程日志
#   /tmp/tailscale/manager.log             定时任务日志
#   /var/run/tailscale/tailscaled.sock     本地控制 socket
#
# 首次使用建议：
#   mkdir -p /data/tailscale
#   vi /data/tailscale/tailscale-manager.sh
#   chmod +x /data/tailscale/tailscale-manager.sh
#   /data/tailscale/tailscale-manager.sh install
#

set -eu

DATA_DIR=${DATA_DIR:-/data/tailscale}
ENV_FILE=${ENV_FILE:-$DATA_DIR/.env}
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
fi

DATA_DIR=${DATA_DIR:-/data/tailscale}
ENV_FILE=${ENV_FILE:-$DATA_DIR/.env}
TMP_DIR=${TMP_DIR:-/tmp/tailscale}
RUN_DIR=/var/run/tailscale
SOCKET=${SOCKET:-$RUN_DIR/tailscaled.sock}
BIN=${BIN:-$TMP_DIR/tailscale}
CLI=${CLI:-$BIN}
DAEMON=${DAEMON:-$TMP_DIR/tailscaled}
STATEDIR=${STATEDIR:-$DATA_DIR/state}
CONFIG=${CONFIG:-}
PIDFILE=${PIDFILE:-$TMP_DIR/tailscaled.pid}
LOGFILE=${LOGFILE:-$TMP_DIR/tailscaled.log}
PACKAGE_URL=${TS_PACKAGE_URL:-${PACKAGE_URL:-http://192.168.2.101:8000/tailscale-small-linux-arm64.tar.gz}}
MIN_DATA_FREE_KB=${MIN_DATA_FREE_KB:-${MIN_FREE_KB:-64}}
MIN_TMP_FREE_KB=${MIN_TMP_FREE_KB:-8192}
TAILSCALED_ARGS=${TAILSCALED_ARGS:---tun=tailscale0}

CRON_BEGIN='# BEGIN tailscale-manager.sh'
CRON_END='# END tailscale-manager.sh'

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

quote_env() {
    case "$1" in
        '') printf "''" ;;
        *)
            printf "%s" "$1" | sed "s/'/'\\''/g; 1s/^/'/; \$s/\$/'/"
            ;;
    esac
}

save_env() {
    make_base_dirs
    tmp="$ENV_FILE.$$"
    {
        echo "# tailscale-manager.sh 自动生成的配置文件"
        printf 'DATA_DIR=%s\n' "$(quote_env "$DATA_DIR")"
        printf 'TMP_DIR=%s\n' "$(quote_env "$TMP_DIR")"
        printf 'STATEDIR=%s\n' "$(quote_env "$STATEDIR")"
        printf 'CONFIG=%s\n' "$(quote_env "$CONFIG")"
        printf 'TS_PACKAGE_URL=%s\n' "$(quote_env "$PACKAGE_URL")"
        printf 'MIN_DATA_FREE_KB=%s\n' "$(quote_env "$MIN_DATA_FREE_KB")"
        printf 'MIN_TMP_FREE_KB=%s\n' "$(quote_env "$MIN_TMP_FREE_KB")"
        printf 'TAILSCALED_ARGS=%s\n' "$(quote_env "$TAILSCALED_ARGS")"
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

ask_value() {
    name=$1
    text=$2
    def=$3
    printf '%s [%s]: ' "$text" "$def" >&2
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
        *) fail "内部错误：不支持的配置项 $name" ;;
    esac
}

configure_interactive() {
    make_base_dirs
    echo "首次配置 Tailscale，直接回车使用默认值。" >&2
    ask_value STATEDIR "状态目录 statedir（小文件，建议放 /data）" "$STATEDIR"
    ask_value CONFIG "配置文件 config（可留空；非空时会传给 tailscaled --config）" "$CONFIG"
    ask_value PACKAGE_URL "局域网下载地址" "$PACKAGE_URL"
    save_env
}

ensure_config() {
    if [ -f "$ENV_FILE" ]; then
        return 0
    fi
    if [ "${AUTO_CONFIG:-}" = "1" ]; then
        save_env
        return 0
    fi
    configure_interactive
}

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
    ensure_config
    make_base_dirs
    check_space "$DATA_DIR" "$MIN_DATA_FREE_KB"
    check_space "$TMP_DIR" "$MIN_TMP_FREE_KB"

    pkg="$TMP_DIR/tailscale-package.$$.tar.gz"
    unpack="$TMP_DIR/unpack.$$"
    rm -rf "$pkg" "$unpack"

    log "下载 $PACKAGE_URL"
    download_file "$PACKAGE_URL" "$pkg"
    extract_package "$pkg" "$unpack"

    src=""
    if [ -f "$unpack/tailscale" ]; then
        src="$unpack/tailscale"
    elif [ -f "$unpack/tailscale.combined" ]; then
        # 兼容旧包；新包应直接包含 tailscale。
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

    # 清理早期版本可能放到 /data 的大文件，避免占用小分区。
    rm -f "$DATA_DIR/tailscale" "$DATA_DIR/tailscaled" \
        "$DATA_DIR/tailscale.combined" "$DATA_DIR/tailscale.combined.old" \
        "$TMP_DIR/tailscale.combined" "$TMP_DIR/tailscale.combined.old"

    rm -rf "$pkg" "$unpack"
}

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
    ensure_config
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
# 每 5 分钟检查一次，日志写到 /tmp，避免占用 /data。
*/5 * * * * mkdir -p "$TMP_DIR" && DATA_DIR="$DATA_DIR" TMP_DIR="$TMP_DIR" "$DATA_DIR/tailscale-manager.sh" ensure >>"$TMP_DIR/manager.log" 2>&1
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

    if [ -f "$old" ] && cron_present_in_text "$(cat "$old" 2>/dev/null || true)"; then
        awk -v begin="$CRON_BEGIN" -v end="$CRON_END" '
            $0 == begin {skip = 1; next}
            $0 == end {skip = 0; next}
            skip {next}
            {print}
        ' "$old" >"$new"
    else
        cat "$old" >"$new"
    fi

    cron_block >>"$new"
    chmod 0644 "$new" 2>/dev/null || true

    if [ -f "$old" ] && cmp -s "$old" "$new" >/dev/null 2>&1; then
        rm -f "$old" "$new"
        log "定时任务已是最新"
        return 0
    fi

    if [ "$target" = crontab ]; then
        crontab "$new"
    else
        mv "$new" "$target"
    fi
    rm -f "$old"
    log "定时任务已写入"
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
    printf '下载地址 PACKAGE_URL=%s\n' "$PACKAGE_URL"

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

ensure_all() {
    ensure_config
    make_base_dirs
    if ! files_ok; then
        log "tailscale 文件缺失，开始安装"
        install_package
    fi
    if ! is_running; then
        log "tailscaled 进程不存在，开始启动"
        start_tailscaled
    fi
}

install_all() {
    ensure_config
    install_package
    write_cron
}

usage() {
    cat <<EOF
用法：$0 命令

命令：
  install    首次配置 + 安装二进制 + 自动写入 cron，重复执行幂等
  init       兼容旧命令，等同于 install
  config     兼容旧命令，等同于 install
  configure  兼容旧命令，等同于 install
  update     重新下载/安装并刷新 cron
  start     启动 tailscaled；如果二进制缺失会先安装
  stop      停止 tailscaled
  restart   重启 tailscaled
  status    查看配置、文件、进程、空间和 cron 状态
  ensure    cron 使用：文件缺失则安装，进程缺失则启动
  cron      自动把定时任务写入系统 crontab，重复执行幂等
  help      显示此帮助

目录策略：
  /data/tailscale 只放小文件：tailscale-manager.sh、.env、state/
  /tmp/tailscale 放二进制、下载包、解压目录、pid、日志
  socket 固定为：/var/run/tailscale/tailscaled.sock

.env 配置项：
  DATA_DIR=/data/tailscale
  TMP_DIR=/tmp/tailscale
  STATEDIR=/data/tailscale/state
  CONFIG=                 # 可留空；非空时传给 tailscaled --config
  TS_PACKAGE_URL=http://192.168.2.101:8000/tailscale-small-linux-arm64.tar.gz
  MIN_DATA_FREE_KB=64
  MIN_TMP_FREE_KB=8192
  TAILSCALED_ARGS='--tun=tailscale0'

压缩包格式：
  tailscale
  tailscaled -> tailscale

首次认证示例：
  /tmp/tailscale/tailscale --socket=/var/run/tailscale/tailscaled.sock up --auth-key=tskey-... --hostname=router
  /tmp/tailscale/tailscale --socket=/var/run/tailscale/tailscaled.sock up
EOF
}

cmd=${1:-status}
case "$cmd" in
    install)
        install_all
        ;;
    init|config|configure)
        install_all
        ;;
    update)
        ensure_config
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
    status)
        status
        ;;
    ensure)
        ensure_all
        ;;
    cron)
        ensure_config
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
