# tailscale-small

English | [中文](README.md)

Minimal Tailscale release packages for tiny systems, embedded Linux, routers, and read-only or low-storage devices.

This project does not fork Tailscale. GitHub Actions periodically fetches the latest release tag from official `tailscale/tailscale` and builds minimal binaries with the official build script. On-device, a single-file `tsmanager.sh` handles install, autostart, self-heal, diagnostics, and uninstall.

## Features

- Official Tailscale source and `build_dist.sh --extra-small --box`
- `CGO_ENABLED=0`; combined binary `tailscale`; `tailscaled -> tailscale`
- Optional UPX; unsupported archs keep the Go-stripped binary
- Each archive contains only `tailscale` and `tailscaled`
- BusyBox/POSIX sh `tsmanager.sh` runtime manager
- Auto-detects Linux CPU arch; **`VERSION` controls downloads**; custom `PACKAGE_URL` is explicit opt-in
- Version may be `latest` or pinned (e.g. `v1.100.0`); pinned versions do **not** silently fall back to latest unless `VERSION_FALLBACK=1`
- Downloads prefer jsDelivr CDN, then GitHub Releases; no router-side sha/checksum tools; light binary validation before install
- Autostart backends: procd / systemd / OpenRC, with cron `ensure` as fallback

## Why this exists

Official Tailscale is powerful, but the full distribution is often too large for small routers, embedded systems, and rescue images. This repo provides a reproducible, auto-updated minimal package that can run from `/tmp` or another small writable area.

## Architecture overview

Two independent pipelines meet at release artifacts:

| Pipeline | Artifacts | Consumers |
| --- | --- | --- |
| Build / publish | `tailscale-small_<ver>_<target>.tar.gz` + `tsmanager.sh` | GitHub Releases, `cdn` branch / jsDelivr |
| Runtime management | on-device `.env`, binary, service/cron, state | routers / embedded devices |

```text
upstream tailscale/tailscale (tag vX.Y.Z)
        │
        ▼
GitHub Actions (monthly 1st 03:17 UTC / manual)
  build_dist.sh --extra-small --box · CGO_ENABLED=0 · optional UPX
        │
        ├─► GitHub Release tag = vX.Y.Z (no -small suffix)
        │     · 10-arch .tar.gz
        │     · tsmanager.sh
        │
        └─► branch `cdn`
              · cdn/vX.Y.Z/…  ·  cdn/latest/…
              · jsDelivr purge + HTTP checks
```

Repository layout:

```text
tailscale-small/
├── tsmanager.sh                 # single-file POSIX runtime manager
├── tests/run.sh                 # developer regression tests
├── README.md / README.en.md     # user docs (includes architecture)
└── .github/workflows/
    ├── build.yml                # build + release + CDN sync
    └── build-package.sh         # per-arch packager
```

**Out of scope**

- No Tailscale source fork
- No mandatory router-side `sha256sum` / checksum files
- No multi-script distribution
- `ensure` does not auto-upgrade by default (`UPDATE_ON_ENSURE=0`)
- Auto-derived download URLs are not persisted (empty `PACKAGE_URL` is not written to `.env`)

## Supported architectures

The workflow builds 10 Linux targets:

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

`tsmanager.sh` maps `uname -m` and, when needed, `/proc/cpuinfo`. On failure, set `TARGET` manually.

## Archive contents

```text
tailscale-small_<tailscale-version>_<target>.tar.gz
```

After extraction:

```text
tailscale
tailscaled -> tailscale
```

`tailscale` is the real binary; `tailscaled` is a symlink. The combined binary selects CLI or daemon mode from argv.

## Download options

### GitHub Releases

Release tags follow official Tailscale tags (no `-small` suffix). Example (`v1.100.0`):

```text
https://github.com/xinghaix/tailscale-small/releases/download/v1.100.0/tailscale-small_v1.100.0_linux-arm64.tar.gz
https://github.com/xinghaix/tailscale-small/releases/download/v1.100.0/tsmanager.sh
```

### jsDelivr CDN

After each release, the workflow mirrors files to the `cdn` branch for jsDelivr:

```text
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/tsmanager.sh
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/tailscale-small_latest_linux-arm64.tar.gz
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/v1.100.0/tailscale-small_v1.100.0_linux-arm64.tar.gz
```

Latest script source from `main`:

```text
https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@main/tsmanager.sh
```

jsDelivr caches files: versioned URLs are most stable; `latest` may lag briefly. On-device download order: **user `PACKAGE_URL` → CDN → GitHub Releases**.

Release artifacts are only per-arch `.tar.gz` plus `tsmanager.sh` (no `.sha256` / `SHA256SUMS` / note txt).

## Runtime layout

Designed for small `/data` and larger `/tmp`:

```text
persistent (small)                 volatile (large)
/data/tailscale/                   /tmp/tailscale/
  tsmanager.sh   ← self-install    tailscale
  .env           ← explicit cfg    tailscaled -> tailscale
  state/         ← identity        pid / log / downloads / lock / breaker

socket (fixed)
  /var/run/tailscale/tailscaled.sock
```

| Path | Default | Role |
| --- | --- | --- |
| `DATA_DIR` | `/data/tailscale` | script, `.env`, `state/` |
| `TMP_DIR` | `/tmp/tailscale` | binary, downloads, logs, lock, breaker |
| `SOCKET` | `/var/run/tailscale/tailscaled.sock` | CLI ↔ daemon |
| managed script | `$DATA_DIR/tsmanager.sh` | installed by `install` / `enable` / `cron` |

`/tmp` wipe on reboot is expected: `ensure` / `start` reinstall when the binary is missing.

## Configuration model

Priority:

```text
process environment (values set before sourcing .env are restored)
        >  persisted .env
        >  built-in defaults
```

### VERSION and PACKAGE_URL

| Case | Behavior |
| --- | --- |
| empty `PACKAGE_URL` | derive URL from `VERSION + TARGET` (CDN primary, GitHub fallback) |
| non-empty `PACKAGE_URL` | **wins** over `VERSION`; `VERSION` is recorded only |
| interactive “no custom URL” | force `PACKAGE_URL=''` |
| save `.env` | persist `PACKAGE_URL` **only when non-empty** |

### Version resolution

| `VERSION` | Behavior |
| --- | --- |
| `latest` | CDN `latest` path; GitHub fallback resolves the newest tag |
| pinned e.g. `v1.100.0` | trust local config; no silent rewrite if the tag list is missing |
| `VERSION_FALLBACK=1` | allow fall back to `latest` only when the online list is available and lacks the pin |

### `.env`

- `ENV_SCHEMA_VERSION` is currently `2`
- Startup normalization handles legacy `TS_PACKAGE_URL`, duplicated `latest/latest` URLs, and VERSION vs latest-URL conflicts
- `.env` is root-equivalent; suspicious command substitution is warned
- `AUTH_KEY` is not persisted by default; `status` shows only `auth_key=set/unset`

## Download and install pipeline

```text
URL candidates: PACKAGE_URL → CDN → GitHub Release
        │
        ▼
download (curl / wget / busybox wget; fail over)
        │
        ▼
extract → validate (executable, version/help, reject HTML error pages / tiny files)
        │
        ▼
atomic replace BIN (keep tailscale.old) + ln -sf tailscale DAEMON
if daemon is running and binary changed → restart
```

Disk space is checked before install; temp package/unpack paths are cleaned on EXIT. Startup failure may roll back to `.old`.

## Process safety

| Mechanism | Role |
| --- | --- |
| `LOCKDIR` | serialize install/ensure/cron; reclaim stale locks |
| `find_pid` | prefer pidfile + **this project's path**; avoid killing system tailscaled |
| ready wait | wait for pid + socket (`START_WAIT_SECONDS`) |
| circuit breaker | trip after repeated start failures; clear with `clear-error` |
| log rotate | trim when over `LOG_MAX_KB` |
| `reset-state` | reject unsafe STATEDIR; outside `DATA_DIR` needs confirm or `FORCE_RESET` |

## Autostart backends

`BOOT_BACKEND=auto`: `procd → systemd → OpenRC → cron → manual`

| backend | Artifact | Keepalive |
| --- | --- | --- |
| procd | `/etc/init.d/tailscale-small` | procd respawn |
| systemd | `tailscale-small.service` | `Restart=on-failure` |
| OpenRC | `/etc/init.d/tailscale-small` | supervise-daemon |
| cron | `BEGIN/END tsmanager.sh` block | `ensure` every 5 minutes |
| manual | none | none |

- service/cron always invoke `$DATA_DIR/tsmanager.sh`
- native enable failure: remove half-written service, then write cron (no dual keepalive)
- backend switch / `disable` / `uninstall` remove residuals

`ensure`: read config → install if binary missing (`UPDATE_ON_ENSURE=1` forces reinstall) → start if not running → restart if binary just updated.

## Router installation

Intended for systems with tiny `/data` and roomier `/tmp`.

1. Fetch the manager:

```sh
mkdir -p /data/tailscale
cd /data/tailscale
wget -O tsmanager.sh https://cdn.jsdelivr.net/gh/xinghaix/tailscale-small@cdn/latest/tsmanager.sh
chmod +x tsmanager.sh
```

If jsDelivr is unreachable, use GitHub Releases or a LAN HTTP URL.

2. First install:

```sh
/data/tailscale/tsmanager.sh install
```

Bare `install` ≡ `install enable`:

- interactive `.env` (explicit user values only)
- download/install binary into `/tmp/tailscale`
- enable autostart/keepalive (native preferred, else cron)
- start `tailscaled`
- self-install script to `$DATA_DIR/tsmanager.sh`

```sh
/data/tailscale/tsmanager.sh install only      # files only
/data/tailscale/tsmanager.sh install start     # install + start, no autostart
/data/tailscale/tsmanager.sh install enable    # install + autostart + start (default)
/data/tailscale/tsmanager.sh install keepalive # same as enable
```

Interactive prompts (5): `statedir`, `config`, `VERSION`, custom URL yes/no, custom `PACKAGE_URL` (empty re-prompts or cancels).

3. Start / login:

```sh
/data/tailscale/tsmanager.sh start
/data/tailscale/tsmanager.sh up
# or
/tmp/tailscale/tailscale --socket=/var/run/tailscale/tailscaled.sock up --auth-key=tskey-... --hostname=router
```

Custom source:

```sh
PACKAGE_URL='https://example.com/tailscale-small_v1.100.0_linux-arm64.tar.gz' \
/data/tailscale/tsmanager.sh install
```

## Commands

All commands are idempotent.

```text
install / install only|start|enable|keepalive
update          reinstall, refresh autostart/keepalive, then start
start|stop|restart
clear-error     clear startup breaker
service-install|service-remove
enable|disable  autostart on/off (disable clears all backend residuals)
boot-status
doctor [tailscale]
up|login-status|reset-state
config          reconfigure wizard / batch .env (alias: reconfigure)
uninstall
status|ensure|cron|selftest|help
```

Global options: `-y` / `--yes` non-interactive; `-n` / `--dry-run` print planned actions only.

```text
config plane    install plane       runtime plane       autostart plane     diagnose plane
config          install only        start/stop/restart  enable/disable      status
                install start       ensure              service-install     doctor
                install enable*     update              service-remove      doctor tailscale
                update              up / login-status    boot-status         selftest
                uninstall           reset-state          cron                clear-error
```

\* Bare `install` ≡ `install enable`.

State machine:

```text
[not installed] --install only--> [files present]
[not installed] --install start--> [running]
[not installed] --install enable--> [running + autostart]
[files present] --start/ensure--> [running]
[running] --stop--> [files present]
[running] --binary updated--> [running] (auto restart)
[running] --start failures--> [tripped] --clear-error--> [startable]
any --uninstall--> [not installed] (optional keep .env/state/script)
```

Common:

```sh
/data/tailscale/tsmanager.sh doctor
/data/tailscale/tsmanager.sh enable
/data/tailscale/tsmanager.sh boot-status
TS_HOSTNAME=router ADVERTISE_ROUTES=192.168.1.0/24 \
  /data/tailscale/tsmanager.sh up --accept-routes=true
```

### Uninstall

```sh
/data/tailscale/tsmanager.sh uninstall
# force optional deletes:
DELETE_CONFIG=1 DELETE_SCRIPT=1 /data/tailscale/tsmanager.sh uninstall
```

- stop process; remove all backends (procd/systemd/OpenRC/cron)
- clear `/tmp/tailscale` runtime files
- keep `.env`, state, and script by default; prompt for optional deletes

### Self-healing cron

```sh
/data/tailscale/tsmanager.sh cron
```

Every 5 minutes `ensure` reinstalls missing files, starts a missing daemon, and rotates oversized logs. Default does not re-download; set `UPDATE_ON_ENSURE=1` to force.

## Tests and build

```sh
sh tests/run.sh
DATA_DIR=/tmp/ts-data TMP_DIR=/tmp/ts-tmp TARGET=linux-arm64 ./tsmanager.sh selftest
```

Local package:

```sh
.github/workflows/build-package.sh \
  --ref v1.100.0 \
  --goos linux \
  --goarch arm64 \
  --out dist
```

Manual release:

```sh
gh workflow run "Build minimal Tailscale packages" \
  --repo xinghaix/tailscale-small \
  -f tailscale_ref=v1.100.0 \
  -f force=true
```

Existing same-tag releases are skipped unless `force=true`.

## Maintenance notes

- Runtime changes: update `tsmanager.sh`, then `tests/run.sh`, then both READMEs
- Release-shape changes: sync `.github/workflows` and the Architecture / Download / Build sections above
- Docs describe current facts only; no temporary roadmaps

## License

Repository scripts and workflows are licensed under the GNU General Public License v3.0 (GPL-3.0).

Tailscale itself comes from official `tailscale/tailscale` and follows its upstream licenses. Generated binaries are built from official source. This project does not own the Tailscale trademark or upstream copyright.
