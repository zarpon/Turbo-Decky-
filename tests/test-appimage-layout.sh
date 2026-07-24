#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
APPDIR_OUTPUT="$TMP/TurboDecky.AppDir" BUILD_DIR="$TMP/build" DIST_DIR="$TMP/dist" \
  bash "$ROOT/packaging/appimage/build-appimage.sh" --appdir-only >/dev/null

APPDIR="$TMP/TurboDecky.AppDir"
[[ -x "$APPDIR/AppRun" ]]
[[ -x "$APPDIR/usr/bin/turbodecky" ]]
[[ -x "$APPDIR/usr/lib/turbodecky/InstallTD.sh" ]]
[[ -L "$APPDIR/.DirIcon" ]]
[[ -L "$APPDIR/turbodecky.desktop" ]]
grep -Fqx 'Exec=turbodecky' "$APPDIR/usr/share/applications/turbodecky.desktop"
grep -Fqx 'Icon=turbodecky' "$APPDIR/usr/share/applications/turbodecky.desktop"
APPDIR="$APPDIR" "$APPDIR/AppRun" --version | grep -Eq '^[0-9]+\.[0-9]+'
! grep -RniE 'OnUnitActiveSec=|OnCalendar=|recomp_algorithm|recompress=' \
  "$APPDIR/usr/lib/turbodecky" >/dev/null
printf 'Turbo Decky AppDir validation passed\n'
