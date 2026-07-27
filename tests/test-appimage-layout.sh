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
APPDIR="$APPDIR" "$APPDIR/AppRun" --status | grep -Fq 'Turbo Decky:'
! grep -RniE 'OnUnitActiveSec=|OnCalendar=|recomp_algorithm|recompress=' \
  "$APPDIR/usr/lib/turbodecky" >/dev/null

# Use a no-op authentication agent so this smoke test is portable to both a
# root container and an unprivileged CI runner.
AUTH_BIN="$TMP/auth-bin"
mkdir -p "$AUTH_BIN"
cat > "$AUTH_BIN/pkexec" <<'EOF_PKEXEC'
#!/usr/bin/env bash
exec "$@"
EOF_PKEXEC
chmod +x "$AUTH_BIN/pkexec"

# Exercise the launcher/backend FIFO in a disposable dry-run root. The same
# path is used by the desktop action, while no real package or system service
# is touched.
PATH="$AUTH_BIN:$PATH" TURBODECKY_DRY_RUN=1 APPDIR="$APPDIR" \
  "$APPDIR/AppRun" --apply-zram \
  <<< 's' > "$TMP/apply.out" 2> "$TMP/apply.err"
grep -Fq 'Operação concluída.' "$TMP/apply.out"

# The kernel action must show the first-install confirmation before the
# privileged backend starts; dry-run then exits without pacman or downloads.
PATH="$AUTH_BIN:$PATH" TURBODECKY_DRY_RUN=1 APPDIR="$APPDIR" \
  "$APPDIR/AppRun" --install-kernel \
  <<< 'S' > "$TMP/kernel-rejected.out" 2> "$TMP/kernel-rejected.err"
! grep -Fq 'Operação concluída.' "$TMP/kernel-rejected.out"

PATH="$AUTH_BIN:$PATH" TURBODECKY_DRY_RUN=1 APPDIR="$APPDIR" \
  "$APPDIR/AppRun" --install-kernel \
  <<< 's' > "$TMP/kernel.out" 2> "$TMP/kernel.err"
grep -Fq 'Operação concluída.' "$TMP/kernel.out"
printf 'Turbo Decky AppDir validation passed\n'
