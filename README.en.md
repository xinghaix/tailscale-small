# tailscale-small

English | [中文](README.md)

Minimal Tailscale release packages for tiny systems, embedded Linux, routers, and read-only or low-storage devices.

This project does not fork the Tailscale source code. GitHub Actions periodically fetches the latest release tag from the official `tailscale/tailscale` repository and builds minimal binaries with the official build script.

## Features

- Uses official Tailscale source code and official `build_dist.sh`
- Build flags: `build_dist.sh --extra-small --box`
- `CGO_ENABLED=0`
- Single combined binary: `tailscale`
- Daemon entry symlink: `tailscaled -> tailscale`
- Tries UPX compression; architectures unsupported by UPX keep the Go-stripped minimal binary
- Each archive contains only `tailscale` and `tailscaled`
- Includes a BusyBox/POSIX sh compatible `tsmanager.sh`
- Supports downloads from GitHub Releases and jsDelivr CDN

## Why this exists

Official Tailscale is powerful, but the full distribution can be too large for small routers, embedded systems, and temporary rescue systems. This repository provides an open, reproducible, automatically updated minimal package so users can run Tailscale from `/tmp` or another small writable area.

## Supported architectures

The workflow currently attempts to build these Linux CPU architectures:

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

## Archive contents

Each release archive is named like:

```text
tailscale-small_<tailscale-version>_<target>.tar.gz
```

After extraction it contains only:

```text
tailscale
tailscaled -> tailscale
```

`tailscale` is the real binary, and `tailscaled` is a symlink. The combined binary chooses CLI or daemon mode based on argv name.

## Download options

### GitHub Releases

Versioned download example:

```text
https://github.com/xinghaix/tailscale-small/releases/download/v1.88.0-small/tailscale-small_v1.88.0_linux-arm64.tar.gz
https://github.com/xinghaix/tailscale-small/releases/download/v1.88.0-small/tsmanager.sh
```

### jsDelivr CDN

jsDelivr cannot directly accelerate GitHub Release assets. Therefore, after publishing a release, the workflow mirrors the files to the `cdn` branch for jsDelivr.

Latest-version downloads:

```text
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/tsmanager.sh
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/tailscale-small_latest_linux-arm64.tar.gz
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/SHA256SUMS
```

Versioned downloads:

```text
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/v1.88.0-small/tsmanager.sh
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/v1.88.0-small/tailscale-small_v1.88.0_linux-arm64.tar.gz
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/v1.88.0-small/SHA256SUMS
```

The manager script can also be downloaded directly from the `main` branch source:

```text
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@main/tsmanager.sh
```

Note: jsDelivr caches files. Versioned URLs are the most stable. `latest` is convenient for automatic updates but may have short CDN propagation delays.

## Router installation

This layout is intended for systems where `/data` is tiny and `/tmp` has more room.

1. Fetch the manager script:

```sh
mkdir -p /data/tailscale
cd /data/tailscale
wget -O tsmanager.sh https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/tsmanager.sh
chmod +x tsmanager.sh
```

If the device cannot access jsDelivr, use GitHub Releases or a LAN HTTP URL instead.

2. First install:

```sh
/data/tailscale/tsmanager.sh install
```

`install` performs three actions:

- Prompts for settings and writes `/data/tailscale/.env`
- Downloads and installs the binary into `/tmp/tailscale`
- Automatically installs the cron self-healing task

The script asks for:

- `statedir`, default `/data/tailscale/state`
- `config`, optional and can be empty
- download URL, for example jsDelivr, GitHub Release URL, or a LAN HTTP URL

Download URL example:

```text
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/tailscale-small_latest_linux-arm64.tar.gz
```

3. Start the daemon:

```sh
/data/tailscale/tsmanager.sh start
```

4. Log in:

```sh
/tmp/tailscale/tailscale --socket=/var/run/tailscale/tailscaled.sock up
```

Or use an auth key:

```sh
/tmp/tailscale/tailscale --socket=/var/run/tailscale/tailscaled.sock up --auth-key=tskey-... --hostname=router
```

## Manager commands

All commands are designed to be idempotent and safe to run repeatedly.

```text
install    first-run config + binary install + automatic cron setup
init       compatibility alias for install
config     compatibility alias for install
configure  compatibility alias for install
update     download/install again and refresh cron
start      start tailscaled; install first if runtime files are missing
stop       stop tailscaled; succeeds even if it is not running
restart    restart tailscaled
status     show config, files, process, storage, and cron status
ensure     cron action: install if files are missing, start if process is missing
cron       automatically write or update the cron job without duplicating it
help       show help
```

## Manager storage layout

`/data/tailscale` stores only small persistent files:

- `tsmanager.sh`
- `.env`
- `state/`

`/tmp/tailscale` stores large and runtime files:

- `tailscale`
- `tailscaled -> tailscale`
- downloaded packages and unpack directories
- pid/log files

The socket is fixed at:

```text
/var/run/tailscale/tailscaled.sock
```

## Self-healing cron

`install` writes cron automatically. You can also refresh it manually:

```sh
/data/tailscale/tsmanager.sh cron
```

Cron runs `ensure` every 5 minutes:

- If the binary in `/tmp` is missing, it downloads and installs it again
- If the `tailscaled` process is missing, it starts it again

## Local build

```sh
scripts/build-package.sh \
  --ref v1.88.0 \
  --goos linux \
  --goarch arm64 \
  --out dist
```

## Automated build and release

GitHub Actions checks the latest stable tag from official `tailscale/tailscale` every day. If the corresponding `vX.Y.Z-small` release does not exist, it builds all targets and publishes a release.

Manual trigger:

```sh
gh workflow run "Build minimal Tailscale packages" \
  --repo xinghaix/tailscale-small \
  -f tailscale_ref=v1.88.0 \
  -f force=true
```

On release, the workflow:

1. Builds all architecture archives
2. Uploads them to GitHub Releases
3. Mirrors them to the `cdn` branch
4. Generates `latest/` for jsDelivr usage

## License

Repository scripts and workflows are MIT licensed.

Tailscale itself comes from the official `tailscale/tailscale` repository and follows its upstream licenses. Generated binaries are built from official source code. This project does not own the Tailscale trademark or upstream source copyright.
