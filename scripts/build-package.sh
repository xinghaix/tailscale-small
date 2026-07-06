#!/bin/sh
set -eu

REF=""
GOOS_TARGET="linux"
GOARCH_TARGET=""
GOARM_TARGET=""
GOMIPS_TARGET=""
GOMIPS64_TARGET=""
OUT_DIR="dist"
SRC_DIR=""
UPSTREAM_REPO="https://github.com/tailscale/tailscale.git"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --ref) REF=$2; shift 2 ;;
        --goos) GOOS_TARGET=$2; shift 2 ;;
        --goarch) GOARCH_TARGET=$2; shift 2 ;;
        --goarm) GOARM_TARGET=$2; shift 2 ;;
        --gomips) GOMIPS_TARGET=$2; shift 2 ;;
        --gomips64) GOMIPS64_TARGET=$2; shift 2 ;;
        --out) OUT_DIR=$2; shift 2 ;;
        --src) SRC_DIR=$2; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -n "$REF" ] || { echo "--ref is required" >&2; exit 2; }
[ -n "$GOARCH_TARGET" ] || { echo "--goarch is required" >&2; exit 2; }

mkdir -p "$OUT_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd)
WORK_ROOT=$(mktemp -d)
cleanup() { rm -rf "$WORK_ROOT"; }
trap cleanup EXIT INT TERM

if [ -n "$SRC_DIR" ]; then
    SRC=$SRC_DIR
else
    SRC=$WORK_ROOT/tailscale
    if ! git clone --depth 1 --branch "$REF" "$UPSTREAM_REPO" "$SRC"; then
        git clone "$UPSTREAM_REPO" "$SRC"
        (cd "$SRC" && git fetch --depth 1 origin "$REF" && git checkout FETCH_HEAD)
    fi
fi

VERSION=$REF
VERSION=${VERSION#refs/tags/}
TARGET="$GOOS_TARGET-$GOARCH_TARGET"
if [ -n "$GOARM_TARGET" ]; then TARGET="$TARGET-v$GOARM_TARGET"; fi
if [ -n "$GOMIPS_TARGET" ]; then TARGET="$TARGET-$GOMIPS_TARGET"; fi
if [ -n "$GOMIPS64_TARGET" ]; then TARGET="$TARGET-$GOMIPS64_TARGET"; fi

PKG=$WORK_ROOT/pkg
mkdir -p "$PKG"

BUILD_ENV="GOOS=$GOOS_TARGET GOARCH=$GOARCH_TARGET CGO_ENABLED=0 TS_USE_TOOLCHAIN=1"
if [ -n "$GOARM_TARGET" ]; then BUILD_ENV="$BUILD_ENV GOARM=$GOARM_TARGET"; fi
if [ -n "$GOMIPS_TARGET" ]; then BUILD_ENV="$BUILD_ENV GOMIPS=$GOMIPS_TARGET"; fi
if [ -n "$GOMIPS64_TARGET" ]; then BUILD_ENV="$BUILD_ENV GOMIPS64=$GOMIPS64_TARGET"; fi

echo "building $VERSION for $TARGET"
(
    cd "$SRC"
    # shellcheck disable=SC2086
    env $BUILD_ENV ./build_dist.sh --extra-small --box -o "$PKG/tailscale" ./cmd/tailscaled
)
chmod 0755 "$PKG/tailscale"
ln -sf tailscale "$PKG/tailscaled"

BEFORE_SIZE=$(wc -c <"$PKG/tailscale" | tr -d ' ')
UPX_STATUS="not-installed"
if command -v upx >/dev/null 2>&1; then
    if upx --best --lzma "$PKG/tailscale"; then
        if upx -t "$PKG/tailscale"; then
            UPX_STATUS="packed"
        else
            UPX_STATUS="packed-test-failed"
        fi
    else
        UPX_STATUS="unsupported-or-failed"
    fi
fi
AFTER_SIZE=$(wc -c <"$PKG/tailscale" | tr -d ' ')

ARCHIVE="tailscale-small_${VERSION}_${TARGET}.tar.gz"
ARCHIVE_PATH="$OUT_DIR/$ARCHIVE"
rm -f "$ARCHIVE_PATH"

(
    cd "$PKG"
    if tar --version 2>/dev/null | grep -qi 'gnu tar'; then
        tar --owner=0 --group=0 -czf "$ARCHIVE_PATH" tailscale tailscaled
    else
        COPYFILE_DISABLE=1 tar -czf "$ARCHIVE_PATH" tailscale tailscaled
    fi
)

SHA_FILE="$OUT_DIR/$ARCHIVE.sha256"
(
    cd "$OUT_DIR"
    sha256sum "$ARCHIVE" >"$ARCHIVE.sha256" 2>/dev/null || shasum -a 256 "$ARCHIVE" >"$ARCHIVE.sha256"
)

INFO_FILE="$OUT_DIR/tailscale-small_${VERSION}_${TARGET}.txt"
{
    echo "version=$VERSION"
    echo "target=$TARGET"
    echo "goos=$GOOS_TARGET"
    echo "goarch=$GOARCH_TARGET"
    echo "goarm=$GOARM_TARGET"
    echo "gomips=$GOMIPS_TARGET"
    echo "gomips64=$GOMIPS64_TARGET"
    echo "size_before_upx=$BEFORE_SIZE"
    echo "size_after_upx=$AFTER_SIZE"
    echo "upx_status=$UPX_STATUS"
    file "$PKG/tailscale" || true
    tar -tzf "$ARCHIVE_PATH"
    cat "$SHA_FILE"
} >"$INFO_FILE"

echo "archive=$ARCHIVE_PATH"
echo "sha256=$(cat "$SHA_FILE")"
echo "upx_status=$UPX_STATUS"
