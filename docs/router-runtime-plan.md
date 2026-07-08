# tailscale-small 路由器运行态优化计划

本文把 ShellCrash 的安装、自启、保活、多设备兼容经验，整理成 tailscale-small 的可执行优化路线。

目标不是复制 ShellCrash 的复杂菜单，而是把本项目从“下载并 cron 自愈的脚本”升级为“小而硬的 Tailscale 路由器运行态管理器”。

## 设计原则

- 保持单文件 `tsmanager.sh`，继续兼容 POSIX sh / BusyBox sh。
- 默认命令仍然简单：`./tsmanager.sh install`。
- 大文件只放 `/tmp/tailscale`，持久配置只放 `/data/tailscale`。
- 优先使用系统原生 init/service 保活；不可用时 fallback 到 cron。
- 所有命令幂等，可重复执行。
- 中文 operator UX 优先，文档中英文同步。
- 借鉴 ShellCrash 的架构思想，不直接复制 GPL 代码实现。

## 当前状态

已完成：

- tar.gz-only 安装，不依赖 checksum 工具。
- Release/CDN 只发布 10 个架构 tar.gz 和 `tsmanager.sh`。
- `install` 和 `ensure` 都带 start 语义。
- cron ensure 每 5 分钟执行自愈。
- CDN 发布后主动 purge jsDelivr。
- 旧配置中 `CDN_BASE=...@cdn/latest` 和 `@cdn/latest/latest` 有基础修正。

短板：

- 自启动/保活主要靠 cron，进程挂掉最多 5 分钟恢复。
- 没有 native service backend（OpenWrt procd / systemd / OpenRC）。
- `ensure`/`start` 缺少并发锁。
- 启动失败会被 cron 反复刷日志，没有熔断。
- status 不够运维化，缺少 schema、backend、错误标记、最近日志。
- 没有 doctor 环境诊断。
- `.env` schema 迁移还没有正式版本号和完整 legacy 映射。

## P0：当前脚本稳定性

优先级最高，先不引入 native service，只把 cron fallback 做扎实。

### P0.1 `.env` schema 迁移

新增：

- `ENV_SCHEMA_VERSION=2`
- `save_env` 写入 schema version。
- `normalize_legacy_config` 处理：
  - `TS_PACKAGE_URL -> PACKAGE_URL`
  - 忽略/删除 `TS_CHECKSUM_URL`
  - 强制重置内部 `CDN_BASE`
  - 修复 `@cdn/latest/latest/`
  - 迁移后回写 `.env`

验收：

- 旧 `.env` 可直接 install/status。
- `.env` 被重写为新字段。
- 不再出现 `@cdn/latest/latest/`。

### P0.2 防并发锁

新增：

- `LOCK_DIR=$TMP_DIR/tsmanager.lock`
- `with_lock <command>` 或在 `install/update/start/ensure` 入口加锁。
- 使用 `mkdir "$LOCK_DIR"` 原子加锁。
- stale lock 检查：如果 lock 中 pid 不存在，可清理。

验收：

- 两个 `ensure` 并发只允许一个执行安装/启动。
- 不会破坏 `status`、`help` 这类只读命令。

### P0.3 启动方式增强

增强 `start_tailscaled`：

- 优先 `setsid`。
- 其次 `nohup`。
- 最后普通后台 `&`。
- pidfile 写入后校验：
  - `kill -0 pid`
  - `ps` 中命令包含 `tailscale`/`tailscaled`（尽力而为）。

验收：

- fake daemon install/start 生成 pidfile。
- stop 能正确停止。
- 无 `setsid/nohup` 时仍可运行。

### P0.4 启动失败熔断

新增：

- `START_FAIL_LIMIT=3`
- `START_FAIL_WINDOW=600`
- `ERROR_FILE=$TMP_DIR/start.error`
- `clear-error` 命令。

行为：

- `start_tailscaled` 失败记录一次。
- 连续失败超过限制后，`ensure` 不再自动启动，避免每 5 分钟刷日志。
- 手动 `start` 可继续尝试，或提示先 `clear-error`。

验收：

- fake daemon 秒退 3 次后，ensure 熔断。
- `clear-error` 后可再次尝试。
- status 显示错误原因。

### P0.5 status 增强

status 输出新增：

- `script_version`
- `env_schema_version`
- `backend=cron/manual`
- `lock_state`
- `error_state`
- `logfile`
- `manager_log`
- 最近日志查看建议。

验收：

- status 不修改系统状态。
- 无日志时不报错。

## P1：service backend 和自启动升级

引入 `BOOT_BACKEND=auto|procd|systemd|openrc|cron|manual`。

新增命令：

- `service-install`
- `service-remove`
- `enable`
- `disable`
- `boot-status`

### P1.1 OpenWrt procd

条件：

- `/etc/rc.common` 存在。
- `/proc/1/comm` 为 `procd`。

生成：

- `/etc/init.d/tailscale-small`

特点：

- `USE_PROCD=1`
- `procd_set_param respawn`
- `start_service` 调用 `tsmanager.sh daemon-start` 或直接启动 `tailscaled`。

验收：

- OpenWrt 环境下 `enable` 会启用 `/etc/init.d/tailscale-small enable`。
- `status` 显示 backend=procd。

### P1.2 systemd

生成：

- `/etc/systemd/system/tailscale-small.service`

特点：

- `Restart=on-failure`
- `RestartSec=10s`
- `After=network-online.target`

### P1.3 OpenRC

生成：

- `/etc/init.d/tailscale-small`

特点：

- `supervise-daemon`
- `--respawn-delay 3`

### P1.4 cron fallback

如果 native backend 不可用，继续使用当前 cron ensure，但复用 P0 的锁和熔断。

## P2：doctor 与多设备兼容

新增 `doctor` 命令。

输出：

- 系统类型：OpenWrt / Xiaomi / Padavan / ASUS/Merlin / Netgear / Debian/systemd / Alpine/OpenRC / BusyBox generic。
- init 系统：procd / systemd / openrc / s6 / unknown。
- CPU 到 target 映射。
- 可写持久目录候选和剩余空间。
- `/tmp` 空间。
- 下载/解压工具。
- cron/native service 可用性。
- `/dev/net/tun` 与 `modprobe tun` 可用性。
- 推荐 `DATA_DIR`、`TMP_DIR`、`BOOT_BACKEND`。

## P3：Tailscale 专属运维体验

新增：

- `up`：封装 `tailscale up`。
- `login-status`：显示是否登录、Tailscale IP、hostname。
- `reset-state`：停止、删除 state、重启。
- `doctor tailscale`：检查 socket、state、tun、控制面网络、系统原生 tailscale 冲突。

可选 `.env`：

- `TS_HOSTNAME`
- `ADVERTISE_ROUTES`
- `ACCEPT_DNS`
- `ACCEPT_ROUTES`
- `EXIT_NODE`

Auth key 默认不持久化，除非显式开启。

## P4：发布链路固化

- purge 后对关键 CDN URL 做 HTTP 200 验证。
- README 说明：versioned URL 最稳定，latest 适合自动更新。
- Release notes 自动写产物清单。

## 当前执行顺序

1. 完成 GPL-3.0 切换。
2. 完成本文档。
3. 执行 P0：schema、锁、启动增强、熔断、status 增强。
4. 验证 P0。
5. 再进入 P1：OpenWrt procd backend。
