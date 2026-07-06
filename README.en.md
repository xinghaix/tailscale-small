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
- `tsmanager.sh` automatically detects the current Linux CPU architecture by default and downloads the matching archive plus `.sha256` checksum file from jsDelivr CDN
- The archive must pass SHA256 integrity verification before extraction and installation
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

`tsmanager.sh` maps `uname -m` and, when needed, `/proc/cpuinfo` to the target names above. If auto-detection fails, set `TARGET` manually.

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

Release tags follow official Tailscale tags directly and do not add a `-small` suffix.

Versioned download example:

```text
https://github.com/xinghaix/tailscale-small/releases/download/v1.88.0/tailscale-small_v1.88.0_linux-arm64.tar.gz
https://github.com/xinghaix/tailscale-small/releases/download/v1.88.0/tailscale-small_v1.88.0_linux-arm64.tar.gz.sha256
https://github.com/xinghaix/tailscale-small/releases/download/v1.88.0/tsmanager.sh
```

### jsDelivr CDN

jsDelivr cannot directly accelerate GitHub Release assets. Therefore, after publishing a release, the workflow mirrors the files to the `cdn` branch for jsDelivr.

Latest-version downloads:

```text
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/tsmanager.sh
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/tailscale-small_latest_linux-arm64.tar.gz
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/tailscale-small_latest_linux-arm64.tar.gz.sha256
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/SHA256SUMS
```

Versioned downloads:

```text
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/v1.88.0/tsmanager.sh
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/v1.88.0/tailscale-small_v1.88.0_linux-arm64.tar.gz
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/v1.88.0/tailscale-small_v1.88.0_linux-arm64.tar.gz.sha256
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/v1.88.0/SHA256SUMS
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

- Prompts for settings and writes `/data/tailscale/.env` (only user-specified values are saved; .env stays minimal)
- Downloads the archive, verifies `.sha256`, then installs the binary into `/tmp/tailscale`
- Automatically installs the cron self-healing task

The script asks just 3 questions:

- `statedir`, default `/data/tailscale/state`
- `config`, optional and can be empty
- download URL; leave empty to auto-detect the current Linux CPU architecture and use jsDelivr CDN

The default download URLs are generated from the detected target, for example arm64:

```text
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/tailscale-small_latest_linux-arm64.tar.gz
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/tailscale-small_latest_linux-arm64.tar.gz.sha256
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

## Custom download source

Only one URL is needed; the checksum file must be at `<url>.sha256`. You can write it to `.env` or pass it as an environment variable.

```sh
PACKAGE_URL='https://example.com/tailscale-small_v1.88.0_linux-arm64.tar.gz' \
/data/tailscale/tsmanager.sh install
```

## Manager commands

All commands are designed to be idempotent and safe to run repeatedly.

```text
install    first-run config + download + checksum verification + binary install + automatic cron setup
update     download/verify/install again, refresh cron, then start tailscaled
start      start tailscaled; download/verify/install first if runtime files are missing
stop       stop tailscaled; succeeds even if it is not running
restart    restart tailscaled
uninstall  full uninstall: stop process, remove cron, delete runtime files; interactively choose whether to delete config and script
status     show config, files, process, storage, cron, and download URLs
ensure     cron action: read .env/defaults, install if needed, start if needed; idempotent
cron       automatically write or update the cron job without duplicating it
help       show help
```

## Uninstall

Run:

```sh
/data/tailscale/tsmanager.sh uninstall
```

Uninstall performs structured cleanup:

- Stops `tailscaled`
- Removes the cron block written by `tsmanager.sh`
- Deletes runtime files under `/tmp/tailscale`, including binaries, pid/log files, temporary downloads, and unpack directories
- Keeps `/data/tailscale/.env`, the state directory, and the script itself by default
- Interactively asks whether to delete config/state
- Interactively asks whether to delete the script itself

For non-interactive environments, force optional deletion with environment variables:

```sh
DELETE_CONFIG=1 DELETE_SCRIPT=1 /data/tailscale/tsmanager.sh uninstall
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

Cron runs `ensure` every 5 minutes. It performs the full install + start self-healing flow:

- Reads download source, target, state directory, and other settings from `.env` plus defaults
- If the binary in `/tmp` is missing, downloads the archive and `.sha256`, verifies, and installs it
- If the `tailscaled` process is missing, starts it
- If already installed and running, skips work and remains idempotent

By default `UPDATE_ON_ENSURE=0`, so cron does not download every 5 minutes. To force verification/update every cron run, set this in `.env`:

```sh
UPDATE_ON_ENSURE=1
```

## Local build

The build script lives at `.github/workflows/build-package.sh` because it is primarily used by GitHub Actions; it can also be run locally:

```sh
.github/workflows/build-package.sh \
  --ref v1.88.0 \
  --goos linux \
  --goarch arm64 \
  --out dist
```

## Automated build and release

GitHub Actions checks the latest stable tag from official `tailscale/tailscale` every day. If the corresponding `vX.Y.Z` release does not exist, it builds all targets and publishes a release. Release tags follow official Tailscale tags directly and do not add a `-small` suffix.

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
