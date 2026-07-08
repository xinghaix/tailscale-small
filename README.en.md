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
- `tsmanager.sh` automatically detects the current Linux CPU architecture by default and downloads the matching `.tar.gz` archive from jsDelivr CDN
- Supports version selection: `latest` (default) or pin to a specific version (e.g. `v1.100.0`); falls back to latest if the specified version is unavailable
- Does not require sha/checksum tools on routers; downloads the `.tar.gz` archive and extracts it directly
- Supports downloads from GitHub Releases and jsDelivr CDN

## Why this exists

Official Tailscale is powerful, but the full distribution can be too large for small routers, embedded systems, and temporary rescue systems. This repository provides an open, reproducible, automatically updated minimal package so users can run Tailscale from `/tmp` or another small writable area.

## Supported architectures

The workflow builds 10 Linux targets. Archive names use these `<target>` strings:

| Package target | Go build settings | Common devices |
| --- | --- | --- |
| `linux-amd64` | `GOOS=linux GOARCH=amd64` | x86_64 / amd64 |
| `linux-386` | `GOOS=linux GOARCH=386` | 32-bit x86 |
| `linux-arm64` | `GOOS=linux GOARCH=arm64` | aarch64 / arm64 |
| `linux-arm-v7` | `GOOS=linux GOARCH=arm GOARM=7` | armv7l / armv8l 32-bit systems |
| `linux-arm-v6` | `GOOS=linux GOARCH=arm GOARM=6` | armv6l |
| `linux-arm-v5` | `GOOS=linux GOARCH=arm GOARM=5` | armv5l / armel |
| `linux-mipsle-softfloat` | `GOOS=linux GOARCH=mipsle GOMIPS=softfloat` | little-endian 32-bit MIPS routers |
| `linux-mips-softfloat` | `GOOS=linux GOARCH=mips GOMIPS=softfloat` | big-endian 32-bit MIPS routers |
| `linux-mips64le-softfloat` | `GOOS=linux GOARCH=mips64le GOMIPS64=softfloat` | little-endian 64-bit MIPS |
| `linux-riscv64` | `GOOS=linux GOARCH=riscv64` | riscv64 |

`tsmanager.sh` maps `uname -m` and, when needed, `/proc/cpuinfo` to these target names. If auto-detection fails, set `TARGET` to one of the package targets in the table.

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

Current latest stable version example (`v1.100.0`):

```text
https://github.com/xinghaix/tailscale-small/releases/download/v1.100.0/tailscale-small_v1.100.0_linux-arm64.tar.gz
https://github.com/xinghaix/tailscale-small/releases/download/v1.100.0/tsmanager.sh
```

### jsDelivr CDN

jsDelivr cannot directly accelerate GitHub Release assets. Therefore, after publishing a release, the workflow mirrors the files to the `cdn` branch for jsDelivr.

Latest-version downloads:

```text
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/tsmanager.sh
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/tailscale-small_latest_linux-arm64.tar.gz
```

Versioned downloads:

```text
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/v1.100.0/tsmanager.sh
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/v1.100.0/tailscale-small_v1.100.0_linux-arm64.tar.gz
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

`install` performs four actions:

- Prompts for settings and writes `/data/tailscale/.env` (only user-specified values are saved; .env stays minimal)
- Downloads the `.tar.gz` archive and installs the binary into `/tmp/tailscale`
- Automatically installs the cron self-healing task
- Automatically starts `tailscaled`

The script asks just 4 questions:

- `statedir`, default `/data/tailscale/state`
- `config`, optional and can be empty
- download URL; leave empty to auto-detect the current Linux CPU architecture and use jsDelivr CDN
- version; default `latest` (follow the latest release), or pin to e.g. `v1.100.0`

The default download URLs are generated from the detected target, for example arm64:

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

## Custom download source

Only one `.tar.gz` URL is needed. You can write it to `.env` or pass it as an environment variable.

```sh
PACKAGE_URL='https://example.com/tailscale-small_v1.100.0_linux-arm64.tar.gz' \
/data/tailscale/tsmanager.sh install
```

## Manager commands

All commands are designed to be idempotent and safe to run repeatedly.

```text
install    first-run config + download/install binary + automatic cron setup + automatic start
update     download/install again, refresh cron, then start tailscaled
start      start tailscaled; download/install first if runtime files are missing
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
- If the binary in `/tmp` is missing, downloads the `.tar.gz` archive and installs it
- If the `tailscaled` process is missing, starts it
- If already installed and running, skips work and remains idempotent

That means both `install` and `ensure` now carry `start` semantics: if files are missing they reinstall, and if the daemon is not running they bring `tailscaled` up.

By default `UPDATE_ON_ENSURE=0`, so cron does not download every 5 minutes. To force download/install every cron run, set this in `.env`:

```sh
UPDATE_ON_ENSURE=1
```

## Local build

The build script lives at `.github/workflows/build-package.sh` because it is primarily used by GitHub Actions; it can also be run locally:

```sh
.github/workflows/build-package.sh \
  --ref v1.100.0 \
  --goos linux \
  --goarch arm64 \
  --out dist
```

## Automated build and release

GitHub Actions checks the latest stable tag from official `tailscale/tailscale` at 03:17 UTC on the first day of every month. If the corresponding `vX.Y.Z` release does not exist, it builds 10 architecture archives and publishes a release. Release tags follow official Tailscale tags directly and do not add a `-small` suffix.

Manual trigger:

```sh
gh workflow run "Build minimal Tailscale packages" \
  --repo xinghaix/tailscale-small \
  -f tailscale_ref=v1.100.0 \
  -f force=true
```

On release, the workflow:

1. Builds `.tar.gz` archives for all 10 targets
2. Uploads the `.tar.gz` files and `tsmanager.sh` to GitHub Releases
3. Mirrors the same files to the version directory on the `cdn` branch
4. Generates `latest/` for jsDelivr usage

Releases and CDN no longer publish `tailscale-small_*.txt`, `.sha256`, or `SHA256SUMS` files; router-side installs only need the matching `.tar.gz` archive.

## License

Repository scripts and workflows are MIT licensed.

Tailscale itself comes from the official `tailscale/tailscale` repository and follows its upstream licenses. Generated binaries are built from official source code. This project does not own the Tailscale trademark or upstream source copyright.
