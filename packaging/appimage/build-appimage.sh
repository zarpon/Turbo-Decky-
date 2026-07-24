#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="${1:-build}"
[[ "$MODE" == build || "$MODE" == --appdir-only ]] || {
  printf 'Uso: %s [--appdir-only]\n' "$0" >&2
  exit 2
}

VERSION="${VERSION:-$(grep -Eo 'TURBODECKY_VERSION="[^"]+"' "$ROOT/lib/00-core.sh" | head -n1 | cut -d'"' -f2)}"
VERSION="${VERSION:-4.0.0-test}"
ARCH="${ARCH:-x86_64}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build/appimage}"
APPDIR="${APPDIR_OUTPUT:-$BUILD_DIR/TurboDecky.AppDir}"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
OUTPUT="${APPIMAGE_OUTPUT:-$DIST_DIR/TurboDecky-${VERSION}-${ARCH}.AppImage}"

rm -rf -- "$APPDIR"
mkdir -p \
  "$APPDIR/usr/bin" \
  "$APPDIR/usr/lib/turbodecky/lib" \
  "$APPDIR/usr/share/applications" \
  "$APPDIR/usr/share/icons/hicolor/scalable/apps" \
  "$APPDIR/usr/share/metainfo"

install -m 0755 "$ROOT/packaging/appimage/AppRun" "$APPDIR/AppRun"
install -m 0755 "$ROOT/packaging/appimage/turbodecky" "$APPDIR/usr/bin/turbodecky"
install -m 0755 "$ROOT/InstallTD.sh" "$APPDIR/usr/lib/turbodecky/InstallTD.sh"
cp -a "$ROOT/lib/." "$APPDIR/usr/lib/turbodecky/lib/"
find "$APPDIR/usr/lib/turbodecky/lib" -type d -exec chmod 0755 {} +
find "$APPDIR/usr/lib/turbodecky/lib" -type f -exec chmod 0644 {} +
install -m 0644 "$ROOT/packaging/appimage/turbodecky.desktop" \
  "$APPDIR/usr/share/applications/turbodecky.desktop"
install -m 0644 "$ROOT/packaging/appimage/turbodecky.svg" \
  "$APPDIR/usr/share/icons/hicolor/scalable/apps/turbodecky.svg"
install -m 0644 "$ROOT/packaging/appimage/io.github.zarpon.TurboDecky.metainfo.xml" \
  "$APPDIR/usr/share/metainfo/io.github.zarpon.TurboDecky.metainfo.xml"

ln -s usr/share/applications/turbodecky.desktop "$APPDIR/turbodecky.desktop"
ln -s usr/share/icons/hicolor/scalable/apps/turbodecky.svg "$APPDIR/turbodecky.svg"
ln -s turbodecky.svg "$APPDIR/.DirIcon"

bash -n "$APPDIR/AppRun" "$APPDIR/usr/bin/turbodecky"
bash -n "$APPDIR/usr/lib/turbodecky/InstallTD.sh"
for file in "$APPDIR"/usr/lib/turbodecky/lib/*.sh; do bash -n "$file"; done
[[ -x "$APPDIR/AppRun" && -x "$APPDIR/usr/bin/turbodecky" ]]
[[ -L "$APPDIR/.DirIcon" && -L "$APPDIR/turbodecky.desktop" ]]
grep -Fqx 'Exec=turbodecky' "$APPDIR/usr/share/applications/turbodecky.desktop"
grep -Fqx 'Icon=turbodecky' "$APPDIR/usr/share/applications/turbodecky.desktop"
if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$APPDIR/usr/share/applications/turbodecky.desktop"
fi

if [[ "$MODE" == --appdir-only ]]; then
  printf '%s\n' "$APPDIR"
  exit 0
fi

mkdir -p "$DIST_DIR" "$BUILD_DIR/tools"
APPIMAGETOOL="${APPIMAGETOOL:-$BUILD_DIR/tools/appimagetool-${ARCH}.AppImage}"
if [[ ! -x "$APPIMAGETOOL" ]]; then
  curl --proto '=https' --tlsv1.2 --fail --location --retry 3 \
    "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${ARCH}.AppImage" \
    -o "$APPIMAGETOOL"
  chmod 0755 "$APPIMAGETOOL"
fi

rm -f -- "$OUTPUT"
ARCH="$ARCH" VERSION="$VERSION" APPIMAGE_EXTRACT_AND_RUN=1 \
  "$APPIMAGETOOL" "$APPDIR" "$OUTPUT"
chmod 0755 "$OUTPUT"
output_dir="$(dirname "$OUTPUT")"
output_name="$(basename "$OUTPUT")"
(
  cd "$output_dir"
  sha256sum "$output_name" > "$output_name.sha256"
)
printf '%s\n' "$OUTPUT"
