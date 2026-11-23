#!/usr/bin/env bash
# Installs a local `flutter build linux --release` on a machine whose glibc is older than the
# libmpv VyseTV ships with (mpv 0.41 needs glibc 2.38; Ubuntu 22.04 has 2.35).
#
# The app's own libmpv and libraries come from a released AppImage, Ubuntu 24.04's glibc is put
# next to them, and the app binary is pointed at it. Nothing outside the install folder changes.
#
#   flutter build linux --release
#   scripts/install_linux_local.sh [path/to/VyseTV-x86_64.AppImage]
#
# Needs: patchelf, curl, dpkg-deb. Install folder: ~/.local/opt/vysetv (override with DEST).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="$ROOT/build/linux/x64/release/bundle"
APPIMAGE="${1:-$HOME/Downloads/VyseTV-x86_64.AppImage}"
DEST="${DEST:-$HOME/.local/opt/vysetv}"
GLIBC_DEB="libc6_2.39-0ubuntu8.12_amd64.deb"
GLIBC_URL="http://archive.ubuntu.com/ubuntu/pool/main/g/glibc/$GLIBC_DEB"

[[ -d "$BUNDLE/lib" ]] || { echo "No build at $BUNDLE: run flutter build linux --release first" >&2; exit 1; }
[[ -f "$APPIMAGE" ]] || { echo "AppImage not found: $APPIMAGE (pass its path)" >&2; exit 1; }
for t in patchelf curl dpkg-deb; do command -v "$t" >/dev/null || { echo "Missing tool: $t" >&2; exit 1; }; done

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

echo "Unpacking the AppImage (libmpv and its libraries)"
cp "$APPIMAGE" "$W/app.AppImage" && chmod +x "$W/app.AppImage"
(cd "$W" && ./app.AppImage --appimage-extract >/dev/null)
T="$W/squashfs-root"

echo "Fetching Ubuntu 24.04's glibc"
curl -fsSo "$W/$GLIBC_DEB" "$GLIBC_URL"
dpkg-deb -x "$W/$GLIBC_DEB" "$W/libc"
G="$W/libc/usr/lib/x86_64-linux-gnu"
mkdir "$T/glibc"
for f in ld-linux-x86-64.so.2 libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 libresolv.so.2 \
         libutil.so.1 libmvec.so.1 libnss_dns.so.2 libnss_files.so.2 libanl.so.1; do
  cp -a "$G/$f" "$T/glibc/"
done

echo "Putting this build's code over it"
cp -a "$BUNDLE/lib/libapp.so" "$BUNDLE/lib/libflutter_linux_gtk.so" "$T/lib/"
cp -a "$BUNDLE"/lib/lib*_plugin.so "$BUNDLE/lib/torrserver" "$T/lib/"
# Network modes (Settings -> Network): the WARP and Anti-DPI programs, when this build has them (scripts/build_usque.sh, build_byedpi.sh)
for prog in usque ciadpi; do [[ -f "$BUNDLE/lib/$prog" ]] && cp -a "$BUNDLE/lib/$prog" "$T/lib/"; done
rm -rf "$T/data/flutter_assets"
cp -a "$BUNDLE/data/flutter_assets" "$T/data/"

# this build's own runner (the AppImage's is older than the code), on the AppImage's libmpv
cp -a "$BUNDLE/vyse_tv" "$T/vyse_tv"
patchelf --replace-needed libmpv.so.1 libmpv.so.2 "$T/vyse_tv"
patchelf --force-rpath --set-interpreter "$DEST/glibc/ld-linux-x86-64.so.2" --set-rpath '$ORIGIN/glibc:$ORIGIN/lib' "$T/vyse_tv"

echo "Installing to $DEST"
mkdir -p "$DEST"
rsync -a --delete "$T"/ "$DEST"/
# start through the wrapper: it sets LD_LIBRARY_PATH for the bundled libraries
mkdir -p "$HOME/.local/bin"
ln -sf "$DEST/vysetv.sh" "$HOME/.local/bin/vyse_tv"
sed -i "s#^Exec=.*#Exec=$DEST/vysetv.sh#" "$HOME/.local/share/applications/com.vyse.vyse_tv.desktop" 2>/dev/null || true
echo "Done. Start it with $DEST/vysetv.sh"
