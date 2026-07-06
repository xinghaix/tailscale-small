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

版本化下载示例：

```text
https://github.com/xinghaix/tailscale-small/releases/download/v1.88.0/tailscale-small_v1.88.0_linux-arm64.tar.gz
https://github.com/xinghaix/tailscale-small/releases/download/v1.88.0/tsmanager.sh
```

### jsDelivr CDN

jsDelivr 不能直接加速 GitHub Release assets，所以本项目的 workflow 会在发布 release 后同步一份文件到 `cdn` 分支，供 jsDelivr 加速。

最新版本下载：

```text
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/tsmanager.sh
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/tailscale-small_latest_linux-arm64.tar.gz
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/SHA256SUMS
```

指定版本下载：

```text
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/v1.88.0/tsmanager.sh
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/v1.88.0/tailscale-small_v1.88.0_linux-arm64.tar.gz
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
- 下载并安装二进制到 `/tmp/tailscale`
- 自动写入 cron 定时自愈任务

脚本会询问：

- 状态目录 `statedir`，默认 `/data/tailscale/state`
- 配置文件 `config`，可留空
- 下载地址，例如 jsDelivr、GitHub Release URL 或你的局域网 HTTP URL

下载地址示例：

```text
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/tailscale-small_latest_linux-arm64.tar.gz
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

## 管理脚本命令

所有命令都按幂等方式设计，可以重复执行。

```text
install    首次配置 + 安装二进制 + 自动写入 cron，重复执行幂等
init       兼容旧命令，等同于 install
config     兼容旧命令，等同于 install
configure  兼容旧命令，等同于 install
update     重新下载/安装并刷新 cron
start      启动 tailscaled；如果二进制缺失会先安装
stop       停止 tailscaled；未运行也返回成功
restart    重启 tailscaled
status     查看配置、文件、进程、空间和 cron 状态
ensure     cron 使用：文件缺失则安装，进程缺失则启动
cron       自动写入或更新定时任务，重复执行不会重复追加
help       显示帮助
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

cron 每 5 分钟执行一次 `ensure`：

- `/tmp` 里的二进制缺失时，重新下载并安装
- `tailscaled` 进程不存在时，重新启动

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
