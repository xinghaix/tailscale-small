# tailscale-small

给微小系统、嵌入式 Linux、路由器和只读/小容量存储设备使用的 Tailscale 极简发行包。

本项目不 fork Tailscale 源码。GitHub Actions 会定时从官方仓库 `tailscale/tailscale` 拉取最新 release tag，使用官方构建脚本打包最小化二进制：

- `build_dist.sh --extra-small --box`
- `CGO_ENABLED=0`
- 单文件 combined binary：`tailscale`
- daemon 入口软链：`tailscaled -> tailscale`
- 尝试使用 UPX 进一步压缩
- 每个压缩包只包含：`tailscale` 和 `tailscaled`

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

某些架构是否能被 UPX 压缩取决于 UPX 支持情况；如果 UPX 不支持，工作流会保留 Go 已 strip 的极简二进制。

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

## 路由器安装方式

适合 `/data` 很小、`/tmp` 空间较大的系统：

1. 把 `scripts/tailscale-manager.sh` 放到设备：

```sh
mkdir -p /data/tailscale
vi /data/tailscale/tailscale-manager.sh
chmod +x /data/tailscale/tailscale-manager.sh
```

2. 首次安装：

```sh
/data/tailscale/tailscale-manager.sh install
```

脚本会交互询问：

- 状态目录 `statedir`，默认 `/data/tailscale/state`
- 配置文件 `config`，可留空
- 下载地址，例如 GitHub release URL 或你的局域网 HTTP URL

配置会保存到：

```text
/data/tailscale/.env
```

后续命令会自动 source 这个 `.env`。

3. 启动：

```sh
/data/tailscale/tailscale-manager.sh start
```

4. 登录：

```sh
/tmp/tailscale/tailscale --socket=/var/run/tailscale/tailscaled.sock up
```

或用 auth key：

```sh
/tmp/tailscale/tailscale --socket=/var/run/tailscale/tailscaled.sock up --auth-key=tskey-... --hostname=router
```

## 管理脚本目录策略

`/data/tailscale` 只存小文件：

- `tailscale-manager.sh`
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
/data/tailscale/tailscale-manager.sh cron
```

cron 每 5 分钟执行一次 `ensure`：

- `/tmp` 里的二进制缺失时，重新下载并安装
- `tailscaled` 进程不存在时，重新启动

## 本地构建

```sh
scripts/build-package.sh \
  --ref v1.88.0 \
  --goos linux \
  --goarch arm64 \
  --out dist
```

## 许可证

本仓库脚本和工作流使用 MIT License。

Tailscale 本身来自官方 `tailscale/tailscale` 仓库，遵循其上游许可证。生成的二进制是从官方源码构建出来的，本项目不拥有 Tailscale 商标或上游源码版权。
