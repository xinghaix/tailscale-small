# tailscale-small

[English](README.en.md) | 中文

给微小系统、嵌入式 Linux、路由器和只读/小容量存储设备使用的 Tailscale 极简发行包。

本项目不 fork Tailscale 源码。GitHub Actions 会定时从官方仓库 `tailscale/tailscale` 拉取最新 release tag，使用官方构建脚本打包最小化二进制；设备侧用单文件 `tsmanager.sh` 完成安装、自启、自愈、诊断和卸载。

## 特性

- 使用官方 Tailscale 源码和官方 `build_dist.sh --extra-small --box`
- `CGO_ENABLED=0`；单文件 combined binary：`tailscale`；`tailscaled -> tailscale`
- 尝试 UPX 压缩；不支持的架构保留 Go strip 后的极简二进制
- 每个压缩包只含 `tailscale` 与 `tailscaled`
- BusyBox/POSIX sh 兼容的 `tsmanager.sh` 运行时管理器
- 自动检测 Linux CPU 架构；**`VERSION` 主控下载**，自定义 `PACKAGE_URL` 为显式 opt-in
- 版本可选 `latest` 或固定版本（如 `v1.100.0`）；固定版本默认**不会**静默回退 latest（需 `VERSION_FALLBACK=1`）
- 下载优先 jsDelivr CDN，失败回退 GitHub Releases；不依赖路由器侧 sha/checksum；安装前轻量二进制校验
- 多自启 backend：procd / systemd / OpenRC，不可用时回退 cron `ensure`

## 为什么做这个

官方 Tailscale 很强，但完整发行包对小路由器、嵌入式和临时救援系统往往太大。本仓库提供可复现、自动更新的最小包，让用户在 `/tmp` 或小容量可写分区上运行 Tailscale。

## 架构总览

两条链路独立，靠发布产物衔接：

| 链路 | 产物 | 消费者 |
| --- | --- | --- |
| 构建 / 发布 | `tailscale-small_<ver>_<target>.tar.gz` + `tsmanager.sh` | GitHub Release、`cdn` 分支 / jsDelivr |
| 运行时管理 | 设备上的 `.env`、二进制、service/cron、state | 路由器 / 嵌入式设备 |

```text
upstream tailscale/tailscale (tag vX.Y.Z)
        │
        ▼
GitHub Actions（每月 1 日 UTC 03:17 / 手动）
  build_dist.sh --extra-small --box · CGO_ENABLED=0 · 可选 UPX
        │
        ├─► GitHub Release tag = vX.Y.Z（无 -small 后缀）
        │     · 10 架构 .tar.gz
        │     · tsmanager.sh
        │
        └─► branch `cdn`
              · cdn/vX.Y.Z/…  ·  cdn/latest/…
              · jsDelivr purge + HTTP 校验
```

仓库组成：

```text
tailscale-small/
├── tsmanager.sh                 # 路由器运行时管理器（单文件，POSIX sh）
├── tests/run.sh                 # 开发机回归测试
├── README.md / README.en.md     # 用户文档（含架构）
└── .github/workflows/
    ├── build.yml                # 构建 + Release + CDN 同步
    └── build-package.sh         # 单架构打包
```

**明确不做**

- 不 fork Tailscale 源码
- 不在路由器侧强制 `sha256sum` / 校验和文件
- 不拆成多脚本分发
- `ensure` 默认不自动升级版本（`UPDATE_ON_ENSURE=0`）
- 不把自动推导的下载 URL 固化进 `.env`（空 `PACKAGE_URL` 不落盘）

## 支持架构

当前工作流构建 10 个 Linux target：

| 包 target | Go 构建参数 | 常见设备 |
| --- | --- | --- |
| `linux-amd64` | `GOOS=linux GOARCH=amd64` | x86_64 / amd64 |
| `linux-386` | `GOOS=linux GOARCH=386` | 32 位 x86 |
| `linux-arm64` | `GOOS=linux GOARCH=arm64` | aarch64 / arm64 |
| `linux-arm-v7` | `GOOS=linux GOARCH=arm GOARM=7` | armv7l / armv8l 32 位系统 |
| `linux-arm-v6` | `GOOS=linux GOARCH=arm GOARM=6` | armv6l |
| `linux-arm-v5` | `GOOS=linux GOARCH=arm GOARM=5` | armv5l / armel |
| `linux-mipsle-softfloat` | `GOOS=linux GOARCH=mipsle GOMIPS=softfloat` | 小端 32 位 MIPS 路由器 |
| `linux-mips-softfloat` | `GOOS=linux GOARCH=mips GOMIPS=softfloat` | 大端 32 位 MIPS 路由器 |
| `linux-mips64le-softfloat` | `GOOS=linux GOARCH=mips64le GOMIPS64=softfloat` | 小端 64 位 MIPS |
| `linux-riscv64` | `GOOS=linux GOARCH=riscv64` | riscv64 |

`tsmanager.sh` 根据 `uname -m` 和必要时的 `/proc/cpuinfo` 映射 target。失败时手动设 `TARGET`。

## 包内容

```text
tailscale-small_<tailscale-version>_<target>.tar.gz
```

解压后只有：

```text
tailscale
tailscaled -> tailscale
```

`tailscale` 是真实二进制；`tailscaled` 是软链。combined binary 按 argv 名称选择 CLI 或 daemon。

## 下载方式

### GitHub Releases

Release tag 跟随官方 Tailscale tag，不加 `-small`。示例（`v1.100.0`）：

```text
https://github.com/xinghaix/tailscale-small/releases/download/v1.100.0/tailscale-small_v1.100.0_linux-arm64.tar.gz
https://github.com/xinghaix/tailscale-small/releases/download/v1.100.0/tsmanager.sh
```

### jsDelivr CDN

workflow 在发布后把文件同步到 `cdn` 分支供 jsDelivr 加速。

```text
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/tsmanager.sh
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/tailscale-small_latest_linux-arm64.tar.gz
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/v1.100.0/tailscale-small_v1.100.0_linux-arm64.tar.gz
```

也可从 `main` 取最新脚本源码：

```text
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@main/tsmanager.sh
```

jsDelivr 有缓存：版本化 URL 最稳；`latest` 可能有短延迟。设备侧下载顺序：**用户 `PACKAGE_URL` → CDN → GitHub Releases**。

发布产物只有各架构 `.tar.gz` 与 `tsmanager.sh`（无 `.sha256` / `SHA256SUMS` / 说明 txt）。

## 运行时目录

面向「`/data` 小、`/tmp` 相对大」：

```text
持久（小）                         易失（大）
/data/tailscale/                   /tmp/tailscale/
  tsmanager.sh   ← 自安装目标        tailscale
  .env           ← 用户显式配置       tailscaled -> tailscale
  state/         ← Tailscale 身份     pid / log / 下载 / 锁 / 熔断

socket（固定）
  /var/run/tailscale/tailscaled.sock
```

| 路径 | 默认 | 职责 |
| --- | --- | --- |
| `DATA_DIR` | `/data/tailscale` | 脚本、`.env`、`state/` |
| `TMP_DIR` | `/tmp/tailscale` | 二进制、下载、日志、锁、熔断 |
| `SOCKET` | `/var/run/tailscale/tailscaled.sock` | CLI ↔ daemon |
| managed script | `$DATA_DIR/tsmanager.sh` | `install`/`enable`/`cron` 会把脚本拷到此处 |

重启后 `/tmp` 清空是预期行为：`ensure` / `start` 发现二进制缺失会按配置重装。

## 配置模型

优先级：

```text
进程环境变量（加载 .env 前已设置的会回填覆盖）
        >  .env 持久项
        >  脚本内建默认值
```

### VERSION 与 PACKAGE_URL

| 场景 | 行为 |
| --- | --- |
| `PACKAGE_URL` 为空 | 用 `VERSION + TARGET` 生成 URL（CDN 主源，GitHub 备用） |
| `PACKAGE_URL` 非空 | **优先**自定义 URL；`VERSION` 只作记录 |
| 交互安装选「否」自定义 | 强制 `PACKAGE_URL=''`，不固化自动 URL |
| 写 `.env` | **仅非空** `PACKAGE_URL` 落盘 |

### 版本解析

| `VERSION` | 行为 |
| --- | --- |
| `latest` | CDN `latest` 路径；GitHub 备用会解析线上最新 tag |
| 固定版本如 `v1.100.0` | 默认信任本地配置，不因列表缺失静默改写 |
| `VERSION_FALLBACK=1` | 固定版本且线上列表可取但不含该版本时，才允许回退 `latest` |

### `.env`

- `ENV_SCHEMA_VERSION` 当前为 `2`
- 启动时规范化：旧 `TS_PACKAGE_URL`、重复 `latest/latest` URL、VERSION 与 latest URL 冲突等
- `.env` 等同 root 配置；可疑命令替换会告警
- `AUTH_KEY` 默认不持久；`status` 只显示 `auth_key=set/unset`

## 下载与安装流水线

```text
URL 候选：PACKAGE_URL → CDN → GitHub Release
        │
        ▼
download（curl / wget / busybox wget，失败换源）
        │
        ▼
解压 → 校验（可执行、version/help、拒 HTML 错误页/过小文件）
        │
        ▼
原子替换 BIN（保留 tailscale.old）+ ln -sf tailscale DAEMON
若进程仍在跑且二进制已变 → 自动重启
```

安装前检查磁盘空间；临时包/解压目录带 EXIT 清理。启动失败且存在 `.old` 时尝试回滚。

## 进程与安全

| 机制 | 作用 |
| --- | --- |
| 目录锁 `LOCKDIR` | 防并发 install/ensure/cron；回收 stale |
| `find_pid` | 优先 pidfile + **本项目路径**，避免误杀系统 tailscaled |
| 启动健康等待 | 等 pid 与 socket（`START_WAIT_SECONDS`） |
| 启动熔断 | 连续失败写 `ERROR_FILE`；需 `clear-error` |
| 日志轮转 | `LOG_MAX_KB` 超限截断 |
| `reset-state` | 拒绝危险 STATEDIR；非 `DATA_DIR` 下需确认或 `FORCE_RESET` |

## 自启动 backend

`BOOT_BACKEND=auto`：`procd → systemd → OpenRC → cron → manual`

| backend | 产物 | 保活 |
| --- | --- | --- |
| procd | `/etc/init.d/tailscale-small` | procd respawn |
| systemd | `tailscale-small.service` | `Restart=on-failure` |
| OpenRC | `/etc/init.d/tailscale-small` | supervise-daemon |
| cron | `BEGIN/END tsmanager.sh` 块 | 每 5 分钟 `ensure` |
| manual | 无 | 无 |

- service/cron 统一调用 `$DATA_DIR/tsmanager.sh`
- native enable 失败：移除半吊子 service 再写 cron，避免双保活
- 切换 backend / `disable` / `uninstall` 会清理残留

`ensure`：读配置 → 缺二进制则装（`UPDATE_ON_ENSURE=1` 强制重装）→ 未运行则启动 → 二进制刚更新则重启。

## 路由器安装

适合 `/data` 很小、`/tmp` 空间较大的系统。

1. 获取脚本：

```sh
mkdir -p /data/tailscale
cd /data/tailscale
wget -O tsmanager.sh https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/tsmanager.sh
chmod +x tsmanager.sh
```

不能访问 jsDelivr 时用 GitHub Releases 或局域网 HTTP。

2. 首次安装：

```sh
/data/tailscale/tsmanager.sh install
```

裸 `install` ≡ `install enable`：

- 交互写入 `/data/tailscale/.env`（只存用户显式配置）
- 下载并安装二进制到 `/tmp/tailscale`
- 开启自启动/保活（native 优先，否则 cron）
- 启动 `tailscaled`
- 把脚本自安装到 `$DATA_DIR/tsmanager.sh`

```sh
/data/tailscale/tsmanager.sh install only      # 只装文件
/data/tailscale/tsmanager.sh install start     # 装并启动，不自启
/data/tailscale/tsmanager.sh install enable    # 装 + 自启 + 启动（默认）
/data/tailscale/tsmanager.sh install keepalive # 同 enable
```

交互只问 5 项：`statedir`、`config`、`VERSION`、是否自定义 URL、自定义 `PACKAGE_URL`（空则重问或取消）。

3. 启动 / 登录：

```sh
/data/tailscale/tsmanager.sh start
/data/tailscale/tsmanager.sh up
# 或
/tmp/tailscale/tailscale --socket=/var/run/tailscale/tailscaled.sock up --auth-key=tskey-... --hostname=router
```

自定义源：

```sh
PACKAGE_URL='https://example.com/tailscale-small_v1.100.0_linux-arm64.tar.gz' \
/data/tailscale/tsmanager.sh install
```

## 命令

全部幂等，可重复执行。

```text
install / install only|start|enable|keepalive
update          重装并刷新自启/保活后启动
start|stop|restart
clear-error     清启动熔断
service-install|service-remove
enable|disable  开/关自启（disable 清全部 backend 残留）
boot-status
doctor [tailscale]
up|login-status|reset-state
config          重配向导 / 批量写 .env（别名 reconfigure）
uninstall
status|ensure|cron|selftest|help
```

全局选项：`-y` / `--yes` 非交互；`-n` / `--dry-run` 只打印关键动作。

```text
配置面          安装面              运行面              自启面              诊断面
config          install only        start/stop/restart  enable/disable      status
                install start       ensure              service-install     doctor
                install enable*     update              service-remove      doctor tailscale
                update              up / login-status    boot-status         selftest
                uninstall           reset-state          cron                clear-error
```

\* 裸 `install` ≡ `install enable`。

状态机：

```text
[未安装] --install only--> [已落盘]
[未安装] --install start--> [运行中]
[未安装] --install enable--> [运行中 + 自启]
[已落盘] --start/ensure--> [运行中]
[运行中] --stop--> [已落盘]
[运行中] --二进制更新--> [运行中]（自动 restart）
[运行中] --连续启动失败--> [熔断] --clear-error--> [可再启动]
任意 --uninstall--> [未安装]（可选保留 .env/state/脚本）
```

常用：

```sh
/data/tailscale/tsmanager.sh doctor
/data/tailscale/tsmanager.sh enable
/data/tailscale/tsmanager.sh boot-status
TS_HOSTNAME=router ADVERTISE_ROUTES=192.168.1.0/24 \
  /data/tailscale/tsmanager.sh up --accept-routes=true
```

### 卸载

```sh
/data/tailscale/tsmanager.sh uninstall
# 非交互强制删配置/脚本：
DELETE_CONFIG=1 DELETE_SCRIPT=1 /data/tailscale/tsmanager.sh uninstall
```

- 停进程；卸全部 backend（procd/systemd/OpenRC/cron）
- 清 `/tmp/tailscale` 运行时文件
- 默认保留 `.env`、state、脚本；交互再问是否删除

### 定时自愈

```sh
/data/tailscale/tsmanager.sh cron
```

每 5 分钟 `ensure`：缺文件补装、缺进程拉起、日志超限轮转。默认不重复下载；强制重装设 `UPDATE_ON_ENSURE=1`。

## 测试与构建

```sh
sh tests/run.sh
DATA_DIR=/tmp/ts-data TMP_DIR=/tmp/ts-tmp TARGET=linux-arm64 ./tsmanager.sh selftest
```

本地打包：

```sh
.github/workflows/build-package.sh \
  --ref v1.100.0 \
  --goos linux \
  --goarch arm64 \
  --out dist
```

手动触发发布：

```sh
gh workflow run "Build minimal Tailscale packages" \
  --repo xinghaix/tailscale-small \
  -f tailscale_ref=v1.100.0 \
  -f force=true
```

已有同名 release 时默认跳过；`force=true` 强制重建。

## 维护约定

- 改运行时：先 `tsmanager.sh`，再 `tests/run.sh`，最后同步中英 README
- 改发布产物：同步 `.github/workflows` 与本文「架构 / 下载 / 自动构建」
- 文档只写当前事实，不写临时排期

## 许可证

本仓库脚本和工作流使用 GNU General Public License v3.0（GPL-3.0）。

Tailscale 本身来自官方 `tailscale/tailscale`，遵循其上游许可证。生成的二进制从官方源码构建；本项目不拥有 Tailscale 商标或上游源码版权。
