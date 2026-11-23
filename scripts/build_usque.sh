#!/usr/bin/env bash
# Builds libusque.so (usque: a Cloudflare WARP client with a local HTTP proxy) for Android, both ABIs,
# from a pinned commit, and puts it in android/app/src/main/jniLibs/<abi>/. Mirrors the Vega app's script.
#
#   scripts/build_usque.sh [path/to/usque-checkout]     (cloned into build/usque-src when no path is given)
#
# Needs: git, curl, tar, the Android NDK (NDK_DIR or
# ANDROID_SDK_ROOT/ndk/<version>, default ~/Documents/Android/Sdk/ndk).
set -euo pipefail

REVISION=6aa03fc97d12848dce34eedbd187fb1077b5d1ea # Diniboy1123/usque v1.5.1-0.20260720063354-6aa03fc97d12
GO_VERSION=go1.26.3
REPO_URL=https://github.com/Diniboy1123/usque.git

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/build/usque-src}"
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Documents/Android/Sdk}}"
NDK="${NDK_DIR:-$(ls -d "$SDK"/ndk/* 2>/dev/null | sort -V | tail -1)}"
[[ -d "$NDK" ]] || { echo "No Android NDK found (set NDK_DIR)" >&2; exit 1; }
TOOLS="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"

if [[ ! -d "$SRC/.git" ]]; then
  mkdir -p "$(dirname "$SRC")"
  git clone "$REPO_URL" "$SRC"
  git -C "$SRC" checkout "$REVISION"
fi
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$REVISION" ]] || { echo "Expected usque at commit $REVISION" >&2; exit 1; }
[[ -z "$(git -C "$SRC" status --porcelain)" ]] || { echo "usque source checkout must be clean" >&2; exit 1; }

# the pinned Go toolchain, downloaded once into build/ (the system's Go may be too old to read usque's go.mod)
GO_DIR="$ROOT/build/$GO_VERSION"
if [[ ! -x "$GO_DIR/go/bin/go" ]]; then
  mkdir -p "$GO_DIR"
  TARBALL="$GO_DIR/$GO_VERSION.linux-amd64.tar.gz"
  for attempt in 1 2 3 4 5; do   # the download host resets connections at random on some networks
    curl -fsSL -o "$TARBALL" "https://dl.google.com/go/$GO_VERSION.linux-amd64.tar.gz" && break
    echo "Go download failed (attempt $attempt), retrying" >&2; sleep 3
  done
  tar -C "$GO_DIR" -xzf "$TARBALL" && rm -f "$TARBALL"
fi
# Modules: the default proxy, then a mirror, then the source hosts (the "|" moves on after any error, a "," only after "not found"). usque's go.sum pins every module's hash, and -mod=readonly refuses
# anything it doesn't list, so the checksum database (also unreachable on some networks) is not needed.
export PATH="$GO_DIR/go/bin:$PATH" GOTOOLCHAIN=local GOFLAGS=-mod=readonly GOOS=android
export GOPROXY="${GOPROXY:-https://proxy.golang.org|https://goproxy.cn|direct}" GOSUMDB=off
# fetch the modules first, with retries (the module proxy resets connections at random on some networks)
for attempt in 1 2 3 4 5 6 7 8; do
  ( cd "$SRC" && GOOS=linux go mod download ) && break
  echo "go mod download failed (attempt $attempt), retrying" >&2; sleep 3
done
for ABI in arm64-v8a armeabi-v7a; do
  OUT="$ROOT/build/usque-build/$ABI/libusque.so"
  mkdir -p "$(dirname "$OUT")"
  if [[ "$ABI" == armeabi-v7a ]]; then
    # Go cannot link android/arm without cgo: the NDK clang is the external linker (PIE against libc/libdl/liblog)
    ( cd "$SRC" && GOARCH=arm GOARM=7 CGO_ENABLED=1 CC="$TOOLS/armv7a-linux-androideabi24-clang" \
        go build -trimpath -ldflags '-s -w' -o "$OUT" . )
    WANT_CLASS=ELF32 WANT_MACHINE=ARM WANT_INTERP='/system/bin/linker[]]'
  else
    ( cd "$SRC" && GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags '-s -w' -o "$OUT" . )
    WANT_CLASS=ELF64 WANT_MACHINE=AArch64 WANT_INTERP='/system/bin/linker64'
  fi
  H="$("$TOOLS/llvm-readelf" -W -h -l "$OUT")"
  grep -Eq "Class:\s+$WANT_CLASS\b" <<<"$H" || { echo "Expected $WANT_CLASS binary for $ABI" >&2; exit 1; }
  grep -Eq "Machine:\s+$WANT_MACHINE\b" <<<"$H" || { echo "Expected $WANT_MACHINE binary for $ABI" >&2; exit 1; }
  grep -Eq "$WANT_INTERP" <<<"$H" || { echo "Missing Android executable interpreter for $ABI" >&2; exit 1; }
  grep -Eq 'Type:\s+DYN\b' <<<"$H" || { echo "usque must be a PIE executable ($ABI)" >&2; exit 1; }
  DEST="$ROOT/android/app/src/main/jniLibs/$ABI"
  mkdir -p "$DEST"
  cp "$OUT" "$DEST/libusque.so"
  echo "usque ($ABI) built: $(sha256sum "$DEST/libusque.so" | cut -d' ' -f1)  $(stat -c %s "$DEST/libusque.so") bytes"
done

# The Linux program (x86-64), for the desktop app: linux/network/usque (installed into the bundle's lib folder by linux/CMakeLists.txt)
OUT="$ROOT/linux/network/usque"
mkdir -p "$(dirname "$OUT")"
( cd "$SRC" && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags '-s -w' -o "$OUT" . )
echo "usque (linux x86-64) built: $(sha256sum "$OUT" | cut -d' ' -f1)  $(stat -c %s "$OUT") bytes"
