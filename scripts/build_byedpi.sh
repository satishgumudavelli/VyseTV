#!/usr/bin/env bash
# Builds libciadpi.so (ByeDPI: a local SOCKS5 proxy that changes how a TLS connection starts) for Android, both ABIs,
# from a pinned commit, and puts it in android/app/src/main/jniLibs/<abi>/. Mirrors the Vega app's script.
# The result is an Android PIE executable packaged as a .so (not a JNI library).
#
#   scripts/build_byedpi.sh [path/to/byedpi-checkout]     (cloned into build/byedpi-src when no path is given)
#
# Needs: git, the Android NDK (NDK_DIR or ANDROID_SDK_ROOT/ndk/<version>, default ~/Documents/Android/Sdk/ndk).
set -euo pipefail

REVISION=7efde1b1296eaaa187b70e951894dde17527489c # upstream v0.17.3
REPO_URL=https://github.com/hufrea/byedpi.git

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/build/byedpi-src}"
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Documents/Android/Sdk}}"
NDK="${NDK_DIR:-$(ls -d "$SDK"/ndk/* 2>/dev/null | sort -V | tail -1)}"
[[ -d "$NDK" ]] || { echo "No Android NDK found (set NDK_DIR)" >&2; exit 1; }
TOOLS="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"

if [[ ! -d "$SRC/.git" ]]; then
  mkdir -p "$(dirname "$SRC")"
  git clone "$REPO_URL" "$SRC"
  git -C "$SRC" checkout "$REVISION"
fi
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$REVISION" ]] || { echo "Expected ByeDPI v0.17.3 at commit $REVISION" >&2; exit 1; }
[[ -z "$(git -C "$SRC" status --porcelain)" ]] || { echo "ByeDPI source checkout must be clean" >&2; exit 1; }

FILES=(packets.c main.c conev.c proxy.c desync.c mpool.c extend.c)
for ABI in arm64-v8a armeabi-v7a; do
  if [[ "$ABI" == armeabi-v7a ]]; then TARGET=armv7a-linux-androideabi24; WANT_INTERP='/system/bin/linker[]]'
  else TARGET=aarch64-linux-android24; WANT_INTERP='/system/bin/linker64'; fi
  OUT="$ROOT/build/byedpi-build/$ABI/libciadpi.so"
  mkdir -p "$(dirname "$OUT")"
  ( cd "$SRC" && "$TOOLS/clang" --target="$TARGET" -D_DEFAULT_SOURCE -I"$SRC" -std=c99 -O2 -fPIE -pie \
      -Wall -Wno-unused -Wextra -Wno-unused-parameter \
      -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384 -Wl,-z,relro -Wl,-z,now -Wl,--build-id=sha1 \
      -o "$OUT" "${FILES[@]}" )
  "$TOOLS/llvm-strip" --strip-all "$OUT"
  H="$("$TOOLS/llvm-readelf" -W -l "$OUT")"
  # every LOAD segment aligned to 16 KB (devices with 16 KB pages), RELRO ends on a page boundary, Android interpreter present
  while read -r line; do
    align=$((16#$(awk '{print $NF}' <<<"$line" | sed 's/^0x//')))
    (( align >= 16384 )) || { echo "Unaligned LOAD segment: $line" >&2; exit 1; }
  done < <(grep -E '^\s+LOAD\s' <<<"$H")
  grep -Eq 'GNU_RELRO' <<<"$H" || { echo "Missing RELRO protection ($ABI)" >&2; exit 1; }
  grep -Eq "$WANT_INTERP" <<<"$H" || { echo "Missing Android executable interpreter ($ABI)" >&2; exit 1; }
  DEST="$ROOT/android/app/src/main/jniLibs/$ABI"
  mkdir -p "$DEST"
  cp "$OUT" "$DEST/libciadpi.so"
  echo "ByeDPI ($ABI) built: $(sha256sum "$DEST/libciadpi.so" | cut -d' ' -f1)  $(stat -c %s "$DEST/libciadpi.so") bytes"
done

# The Linux program, for the desktop app: linux/network/ciadpi (installed into the bundle's lib folder by linux/CMakeLists.txt)
OUT="$ROOT/linux/network/ciadpi"
mkdir -p "$(dirname "$OUT")"
( cd "$SRC" && "${CC:-cc}" -D_DEFAULT_SOURCE -I"$SRC" -std=c99 -O2 -Wall -Wno-unused -Wextra -Wno-unused-parameter -o "$OUT" "${FILES[@]}" )
strip "$OUT"
echo "ByeDPI (linux x86-64) built: $(sha256sum "$OUT" | cut -d' ' -f1)  $(stat -c %s "$OUT") bytes"
