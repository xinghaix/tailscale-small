# tailscale-small

[English](README.en.md) | 中文

给微小系统、嵌入式 Linux、路由器和只读/小容量存储设备使用的 Tailscale 极简发行包。

本项目不 fork Tailscale 源码。GitHub Actions 会定时从官方仓库 `tailscale/tailscale` 拉取最新 release tag，使用官方构建脚本打包最小化二进制。

## 特性

- 使用官方 Tailscale 源码和官方 `build_dist.sh`
- 构建参数：`build_dist.sh --extra-small --box`
- `CGO_ENABLED=0`
- 单文件 combined binary：`tailscale`
- daemon 入口软链：`tailscaled -> tailscale`
- 尝试使用 UPX 进一步压缩；UPX 不支持的架构会保留 Go 已 strip 的极简二进制
- 每个压缩包只包含：`tailscale` 和 `tailscaled`
- 提供 BusyBox/POSIX sh 兼容的 `tsmanager.sh`
- `tsmanager.sh` 默认自动检测当前 Linux CPU 架构，从 jsDelivr CDN 下载匹配的 `.tar.gz` 压缩包
- 支持选择版本：`latest`（默认）或固定版本（如 `v1.100.0`），版本不存在时自动回退至 latest
- 不依赖路由器上的 sha/checksum 工具，下载 `.tar.gz` 后直接解压安装
- 支持 GitHub Releases 和 jsDelivr CDN 下载

## 为什么做这个

官方 Tailscale 很强，但完整发行包对某些小路由器、嵌入式系统、临时救援系统来说太大。本仓库的目标是提供一个开源、可复现、自动更新的最小包，让用户能在 `/tmp` 或小容量可写分区中运行 Tailscale。

## 支持架构

当前工作流构建 10 个 Linux target，包名中的 `<target>` 使用下列名称：

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

`tsmanager.sh` 会根据 `uname -m` 和必要时的 `/proc/cpuinfo` 自动映射到这些 target。自动识别失败时，可以手动设置 `TARGET` 为表格中的包 target。

## 包内容

每个 release 包形如：

```text
tailscale-small_<tailscale-version>_<target>.tar.gz
```

解压后只有：

```text
tailscale
tailscaled -> tailscale
```

`tailscale` 是真实二进制；`tailscaled` 是软链。combined binary 会根据 argv 名称决定运行 CLI 还是 daemon。

## 下载方式

### GitHub Releases

Release tag 命名直接跟随官方 Tailscale tag，不额外添加 `-small` 后缀。

当前最新稳定版示例（`v1.100.0`）：

```text
https://github.com/xinghaix/tailscale-small/releases/download/v1.100.0/tailscale-small_v1.100.0_linux-arm64.tar.gz
https://github.com/xinghaix/tailscale-small/releases/download/v1.100.0/tsmanager.sh
```

### jsDelivr CDN

jsDelivr 不能直接加速 GitHub Release assets，所以本项目的 workflow 会在发布 release 后同步一份文件到 `cdn` 分支，供 jsDelivr 加速。

最新版本下载：

```text
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/tsmanager.sh
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/tailscale-small_latest_linux-arm64.tar.gz
```

指定版本下载：

```text
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/v1.100.0/tsmanager.sh
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/v1.100.0/tailscale-small_v1.100.0_linux-arm64.tar.gz
```

管理脚本也可以直接从 `main` 分支获取最新源码版：

```text
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@main/tsmanager.sh
```

注意：jsDelivr 会缓存文件。版本化 URL 最稳定；`latest` 适合自动更新，但可能有短时间 CDN 缓存延迟。

## 路由器安装方式

适合 `/data` 很小、`/tmp` 空间较大的系统。

1. 获取管理脚本：

```sh
mkdir -p /data/tailscale
cd /data/tailscale
wget -O tsmanager.sh https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/tsmanager.sh
chmod +x tsmanager.sh
```

如果设备不能访问 jsDelivr，也可以用 GitHub Releases 或局域网 HTTP 地址。

2. 首次安装：

```sh
/data/tailscale/tsmanager.sh install
```

裸 `install` 默认等价于 `install enable`，会完成四件事：

- 交互询问并写入 `/data/tailscale/.env`（只保存用户显式配置，.env 极为精简）
- 下载 `.tar.gz` 压缩包并安装二进制到 `/tmp/tailscale`
- 开启自启动/保活：优先 native backend（procd/systemd/OpenRC），不可用时回退 cron
- 自动启动 `tailscaled`

也可以显式选择安装语义：

```sh
/data/tailscale/tsmanager.sh install only      # 只安装，不启动，不开启自启/保活
/data/tailscale/tsmanager.sh install start     # 安装并启动，不开启自启/保活
/data/tailscale/tsmanager.sh install enable    # 安装 + 开启自启/保活 + 启动（默认）
/data/tailscale/tsmanager.sh install keepalive # 等价 install enable
```

脚本只问 5 个问题：

- 状态目录 `statedir`，默认 `/data/tailscale/state`
- 配置文件 `config`，可留空
- 版本号 `VERSION`，默认 `latest`（跟随最新发布），也可固定为 `v1.100.0` 等
- 是否使用自定义下载 URL，默认否
- 只有选择“是”时，才输入自定义 `PACKAGE_URL`

默认路径是：先选择 `VERSION`，脚本按 `VERSION + CPU 架构` 自动生成下载地址，例如 arm64 + `v1.100.0`：

```text
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/v1.100.0/tailscale-small_v1.100.0_linux-arm64.tar.gz
```

只有当你有私有镜像、内网 HTTP 或手写 tar.gz 地址时，才选择自定义 URL。`PACKAGE_URL` 非空时优先于 `VERSION`；这时 `VERSION` 只作为记录，不参与下载。

3. 启动：

```sh
/data/tailscale/tsmanager.sh start
```

4. 登录：

```sh
/tmp/tailscale/tailscale --socket=/var/run/tailscale/tailscaled.sock up
```

或用 auth key：

```sh
/tmp/tailscale/tailscale --socket=/var/run/tailscale/tailscaled.sock up --auth-key=tskey-... --hostname=router
```

## 自定义下载源

只需设置一个 `.tar.gz` 下载地址。可以写入 `.env`，也可以临时通过环境变量传入。

```sh
PACKAGE_URL='https://example.com/tailscale-small_v1.100.0_linux-arm64.tar.gz' \
/data/tailscale/tsmanager.sh install
```

## 管理脚本命令

所有命令都按幂等方式设计，可以重复执行。

```text
install    默认等价 install enable：首次配置 + 安装 + 自启动/保活 + 启动
install only    只配置 + 下载安装；不启动，不开启自启动/保活
install start   配置 + 下载安装 + 启动；不开启自启动/保活
install enable  配置 + 下载安装 + 开启自启动/保活 + 启动
install keepalive 等价 install enable
update     重新下载安装并刷新 cron，然后启动 tailscaled
start      启动 tailscaled；如果二进制缺失会先下载安装
stop       停止 tailscaled；未运行也返回成功
restart    重启 tailscaled
clear-error 清理启动失败熔断标记，允许再次自动拉起
service-install 安装当前系统推荐的自启动 service
service-remove  移除当前 backend 的自启动 service
enable     开启自启动/保活；原生 init 不可用时回退 cron
disable    关闭自启动/保活
boot-status 查看自启动 backend 状态
doctor     环境诊断；doctor tailscale 检查 Tailscale 运行态
up         封装 tailscale up，自动带 socket
login-status 查看 Tailscale 登录/连接状态
reset-state 停止并删除 state 后重新启动
uninstall  完整卸载：停止进程、移除 cron、删除运行时文件；交互选择是否删除配置和脚本
status     查看配置、文件、进程、空间、cron、锁状态、错误标记和下载 URL
ensure     cron 使用：从 .env/默认配置读取，必要时安装并启动，幂等
cron       自动写入或更新定时任务，重复执行不会重复追加
help       显示帮助
```

## 自启动和保活 backend

`BOOT_BACKEND=auto` 会自动选择当前系统最合适的方式：

- OpenWrt/procd：生成 `/etc/init.d/tailscale-small`，使用 procd respawn 保活。
- systemd：生成 `tailscale-small.service`，使用 `Restart=on-failure`。
- OpenRC：生成 `/etc/init.d/tailscale-small`，使用 supervise-daemon respawn。
- 其他 BusyBox/路由器环境：回退到 cron ensure。
- `manual`：只安装，不写自启动。

常用命令：

```sh
/data/tailscale/tsmanager.sh doctor
/data/tailscale/tsmanager.sh service-install
/data/tailscale/tsmanager.sh enable
/data/tailscale/tsmanager.sh boot-status
```

## Tailscale 登录和状态

可以用脚本封装 `tailscale up`，自动带上本项目固定 socket：

```sh
TS_HOSTNAME=router ADVERTISE_ROUTES=192.168.1.0/24 \
/data/tailscale/tsmanager.sh up --accept-routes=true
```

诊断运行态：

```sh
/data/tailscale/tsmanager.sh doctor tailscale
/data/tailscale/tsmanager.sh login-status
```

如需换账号或重置身份：

```sh
/data/tailscale/tsmanager.sh reset-state
```

## 卸载

执行：

```sh
/data/tailscale/tsmanager.sh uninstall
```

卸载会执行工程化清理：

- 停止 `tailscaled`
- 移除 `tsmanager.sh` 写入的 cron block
- 删除 `/tmp/tailscale` 里的运行时文件、二进制、pid、日志、临时下载包和解压目录
- 默认保留 `/data/tailscale/.env`、状态目录和脚本本身
- 交互询问是否删除配置/状态目录
- 交互询问是否删除脚本本身

非交互环境可以用环境变量强制删除可选项：

```sh
DELETE_CONFIG=1 DELETE_SCRIPT=1 /data/tailscale/tsmanager.sh uninstall
```

## 管理脚本目录策略

`/data/tailscale` 只存小文件：

- `tsmanager.sh`
- `.env`
- `state/`

`/tmp/tailscale` 存大文件和运行时文件：

- `tailscale`
- `tailscaled -> tailscale`
- 下载包和解压目录
- pid/log

socket 固定为：

```text
/var/run/tailscale/tailscaled.sock
```

## 定时自愈

`install enable` 会自动安装推荐的自启动/保活 backend；在 generic BusyBox/路由器环境会回退写入 cron。也可以手动刷新 cron：

```sh
/data/tailscale/tsmanager.sh cron
```

cron 每 5 分钟执行一次 `ensure`，它会执行完整的 install + start 自愈流程：

- 从 `.env` 和默认配置读取下载源、架构、状态目录等配置
- `/tmp` 里的二进制缺失时，下载 `.tar.gz` 压缩包并安装
- `tailscaled` 进程不存在时，启动它
- 已安装且已运行时直接跳过，保持幂等

也就是说，默认 `install` / `install enable` 和 `ensure` 都带有 `start` 语义：缺文件就补安装，没进程就拉起 `tailscaled`。如果只想落文件，用 `install only`；如果只想安装并启动但不自启，用 `install start`。

默认 `UPDATE_ON_ENSURE=0`，所以 cron 不会每 5 分钟重复下载。若你希望 cron 每次都重新下载并安装，可以在 `.env` 中设置：

```sh
UPDATE_ON_ENSURE=1
```

## 本地构建

构建脚本放在 `.github/workflows/build-package.sh`，因为它主要服务于 GitHub Actions；也可以本地直接运行：

```sh
.github/workflows/build-package.sh \
  --ref v1.100.0 \
  --goos linux \
  --goarch arm64 \
  --out dist
```

## 自动构建和发布

GitHub Actions 每月 1 日 UTC 03:17 检查官方 `tailscale/tailscale` 最新稳定 tag。如果对应的 `vX.Y.Z` release 不存在，就自动构建 10 个架构压缩包并发布。Release tag 命名直接跟随官方 Tailscale tag，不额外添加 `-small` 后缀。

也可以手动触发：

```sh
gh workflow run "Build minimal Tailscale packages" \
  --repo xinghaix/tailscale-small \
  -f tailscale_ref=v1.100.0 \
  -f force=true
```

发布时 workflow 会：

1. 构建 10 个架构的 `.tar.gz` 压缩包
2. 把 `.tar.gz` 和 `tsmanager.sh` 上传到 GitHub Release
3. 同步同一批文件到 `cdn` 分支的版本目录
4. 生成 `latest/` 目录供 jsDelivr 使用

Release 和 CDN 不再发布 `tailscale-small_*.txt`、`.sha256` 或 `SHA256SUMS` 文件；路由器侧只需要下载对应架构的 `.tar.gz`。发布 workflow 会在同步 `cdn` 分支后主动 purge jsDelivr，并验证 `latest` 和版本目录中的关键文件可 HTTP 访问。

## 许可证

本仓库脚本和工作流使用 GNU General Public License v3.0（GPL-3.0）。

Tailscale 本身来自官方 `tailscale/tailscale` 仓库，遵循其上游许可证。生成的二进制是从官方源码构建出来的，本项目不拥有 Tailscale 商标或上游源码版权。
