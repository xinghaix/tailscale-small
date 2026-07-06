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
- `tsmanager.sh` 默认自动检测当前 Linux CPU 架构，从 jsDelivr CDN 下载匹配的压缩包和 `.sha256` 校验文件
- 下载后必须通过 SHA256 完整性校验才会解压安装
- 支持 GitHub Releases 和 jsDelivr CDN 下载

## 为什么做这个

官方 Tailscale 很强，但完整发行包对某些小路由器、嵌入式系统、临时救援系统来说太大。本仓库的目标是提供一个开源、可复现、自动更新的最小包，让用户能在 `/tmp` 或小容量可写分区中运行 Tailscale。

## 支持架构

当前工作流会尝试构建这些 Linux CPU 架构：

- `linux/amd64`
- `linux/386`
- `linux/arm64`
- `linux/arm/v7`
- `linux/arm/v6`
- `linux/arm/v5`
- `linux/mipsle` softfloat
- `linux/mips` softfloat
- `linux/mips64le` softfloat
- `linux/riscv64`

`tsmanager.sh` 会根据 `uname -m` 和必要时的 `/proc/cpuinfo` 自动映射到上面的 target。自动识别失败时，可以手动设置 `TARGET`。

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

版本化下载示例：

```text
https://github.com/xinghaix/tailscale-small/releases/download/v1.88.0/tailscale-small_v1.88.0_linux-arm64.tar.gz
https://github.com/xinghaix/tailscale-small/releases/download/v1.88.0/tailscale-small_v1.88.0_linux-arm64.tar.gz.sha256
https://github.com/xinghaix/tailscale-small/releases/download/v1.88.0/tsmanager.sh
```

### jsDelivr CDN

jsDelivr 不能直接加速 GitHub Release assets，所以本项目的 workflow 会在发布 release 后同步一份文件到 `cdn` 分支，供 jsDelivr 加速。

最新版本下载：

```text
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/tsmanager.sh
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/tailscale-small_latest_linux-arm64.tar.gz
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/tailscale-small_latest_linux-arm64.tar.gz.sha256
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/SHA256SUMS
```

指定版本下载：

```text
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/v1.88.0/tsmanager.sh
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/v1.88.0/tailscale-small_v1.88.0_linux-arm64.tar.gz
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/v1.88.0/tailscale-small_v1.88.0_linux-arm64.tar.gz.sha256
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/v1.88.0/SHA256SUMS
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

`install` 会完成三件事：

- 交互询问并写入 `/data/tailscale/.env`
- 下载压缩包和对应 `.sha256` 文件，校验通过后安装二进制到 `/tmp/tailscale`
- 自动写入 cron 定时自愈任务

脚本会询问：

- 状态目录 `statedir`，默认 `/data/tailscale/state`
- 配置文件 `config`，可留空
- 包架构 `target`，默认自动检测
- 压缩包下载地址
- SHA256 校验文件下载地址

默认下载地址会自动按架构生成，例如 arm64：

```text
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/tailscale-small_latest_linux-arm64.tar.gz
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/tailscale-small_latest_linux-arm64.tar.gz.sha256
```

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

如果不用默认 CDN，需要同时提供两个 URL：压缩包和 checksum。可以写入 `.env`，也可以临时通过环境变量传入。

```sh
TS_PACKAGE_URL='https://example.com/tailscale-small_v1.88.0_linux-arm64.tar.gz' \
TS_CHECKSUM_URL='https://example.com/tailscale-small_v1.88.0_linux-arm64.tar.gz.sha256' \
/data/tailscale/tsmanager.sh install
```

只自定义压缩包而不提供 checksum 不推荐。脚本会默认把 checksum URL 推导为 `TS_PACKAGE_URL + .sha256`，因此你的自定义源也应该提供这个文件。

## 管理脚本命令

所有命令都按幂等方式设计，可以重复执行。

```text
install    首次配置 + 下载校验 + 安装二进制 + 自动写入 cron，重复执行幂等
update     重新下载/校验/安装并刷新 cron，然后启动 tailscaled
start      启动 tailscaled；如果二进制缺失会先下载校验并安装
stop       停止 tailscaled；未运行也返回成功
restart    重启 tailscaled
uninstall  完整卸载：停止进程、移除 cron、删除运行时文件；交互选择是否删除配置和脚本
status     查看配置、文件、进程、空间、cron 和下载 URL
ensure     cron 使用：从 .env/默认配置读取，必要时安装并启动，幂等
cron       自动写入或更新定时任务，重复执行不会重复追加
help       显示帮助
```

## 卸载

执行：

```sh
/data/tailscale/tsmanager.sh uninstall
```

卸载会执行工程化清理：

- 停止 `tailscaled`
- 移除 `tsmanager.sh` 写入的 cron block（兼容清理旧的 `tailscale-manager.sh` block）
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

`install` 会自动写入 cron；也可以手动刷新：

```sh
/data/tailscale/tsmanager.sh cron
```

cron 每 5 分钟执行一次 `ensure`，它会执行完整的 install + start 自愈流程：

- 从 `.env` 和默认配置读取下载源、架构、状态目录等配置
- `/tmp` 里的二进制缺失时，下载压缩包和 `.sha256` 并校验安装
- `tailscaled` 进程不存在时，启动它
- 已安装且已运行时直接跳过，保持幂等

默认 `UPDATE_ON_ENSURE=0`，所以 cron 不会每 5 分钟重复下载。若你希望 cron 每次都重新校验和更新，可以在 `.env` 中设置：

```sh
UPDATE_ON_ENSURE=1
```

## 本地构建

构建脚本放在 `.github/workflows/build-package.sh`，因为它主要服务于 GitHub Actions；也可以本地直接运行：

```sh
.github/workflows/build-package.sh \
  --ref v1.88.0 \
  --goos linux \
  --goarch arm64 \
  --out dist
```

## 自动构建和发布

GitHub Actions 每天检查官方 `tailscale/tailscale` 最新稳定 tag。如果对应的 `vX.Y.Z` release 不存在，就自动构建所有架构并发布。Release tag 命名直接跟随官方 Tailscale tag，不额外添加 `-small` 后缀。

也可以手动触发：

```sh
gh workflow run "Build minimal Tailscale packages" \
  --repo xinghaix/tailscale-small \
  -f tailscale_ref=v1.88.0 \
  -f force=true
```

发布时 workflow 会：

1. 构建所有架构压缩包
2. 上传到 GitHub Release
3. 同步到 `cdn` 分支
4. 生成 `latest/` 目录供 jsDelivr 使用

## 许可证

本仓库脚本和工作流使用 MIT License。

Tailscale 本身来自官方 `tailscale/tailscale` 仓库，遵循其上游许可证。生成的二进制是从官方源码构建出来的，本项目不拥有 Tailscale 商标或上游源码版权。
