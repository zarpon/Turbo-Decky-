#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT="$(realpath "${1:-./InstallTD.sh}")"
REPO="$(dirname "$SCRIPT")"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
new_root() {
  local root="$TMP/$1"
  mkdir -p "$root/etc/default" "$root/home" "$root/etc/systemd/zram-generator.conf.d"
  printf 'GRUB_CMDLINE_LINUX="quiet root=UUID=example"\n' > "$root/etc/default/grub"
  printf '# baseline\n' > "$root/etc/fstab"
  printf '# external zram\n' > "$root/etc/systemd/zram-generator.conf.d/00-turbodecky.conf"
  printf '%s' "$root"
}
run() {
  TURBODECKY_ROOTFS="$1" TURBODECKY_DRY_RUN=1 TURBODECKY_LIBRARY=0 \
    TURBODECKY_UI=terminal TURBODECKY_ASSUME_YES=1 bash "$SCRIPT" "$2"
}

# Revert on a clean system is a no-op, including third-party files.
ROOT="$(new_root empty)"
run "$ROOT" --revert > "$TMP/noop.out"
grep -Fqx '# external zram' "$ROOT/etc/systemd/zram-generator.conf.d/00-turbodecky.conf"
[[ ! -d "$ROOT/var/lib/turbodecky/state" ]]

# Validate all backups before changing even the first target.
ROOT="$(new_root missing)"
run "$ROOT" --apply-zram > /dev/null 2>&1
STATE="$ROOT/var/lib/turbodecky/state"
backup="$(awk -F '\t' -v f="$ROOT/etc/default/grub" '$1 == f {print $2}' "$STATE/files.tsv")"
cp "$ROOT/etc/default/grub" "$TMP/current-grub"
rm "$backup"
if run "$ROOT" --revert > "$TMP/missing.out" 2>&1; then exit 1; fi
cmp "$ROOT/etc/default/grub" "$TMP/current-grub"
[[ -d "$STATE/backups" ]]

# Corrupted backup and later user edits cannot be overwritten.
ROOT="$(new_root corrupt)"
run "$ROOT" --apply-zram >/dev/null 2>&1
STATE="$ROOT/var/lib/turbodecky/state"
backup="$(awk -F '\t' -v f="$ROOT/etc/default/grub" '$1 == f {print $2}' "$STATE/files.tsv")"
printf 'corrupted\n' > "$backup"
if run "$ROOT" --revert > "$TMP/corrupt.out" 2>&1; then exit 1; fi
grep -Fq 'Backup corrompido' "$TMP/corrupt.out"
ROOT="$(new_root conflict)"
run "$ROOT" --apply-zram >/dev/null 2>&1
printf '# user change\n' >> "$ROOT/etc/default/grub"
if run "$ROOT" --revert > "$TMP/conflict.out" 2>&1; then exit 1; fi
grep -Fq '# user change' "$ROOT/etc/default/grub"
grep -Fq 'Alteração externa' "$TMP/conflict.out"

# Fail after changes have begun: restore the previous profile and keep baseline.
ROOT="$(new_root rollback)"
run "$ROOT" --apply-zram >/dev/null 2>&1
cp "$ROOT/etc/default/grub" "$TMP/before-grub"
if TURBODECKY_ROOTFS="$ROOT" TURBODECKY_DRY_RUN=1 TURBODECKY_LIBRARY=1 \
  TURBODECKY_UI=terminal TURBODECKY_ASSUME_YES=1 bash -c \
  'source "$1"; configure_zswap_runtime() { die "injected runtime failure"; }; apply_zswap_profile' _ "$SCRIPT" \
  > "$TMP/rollback.out" 2>&1; then exit 1; fi
cmp "$ROOT/etc/default/grub" "$TMP/before-grub"
grep -Fqx zram "$ROOT/var/lib/turbodecky/state/profile"
grep -Fqx failed-restored "$ROOT/var/lib/turbodecky/state/operation-state"
[[ ! -e "$ROOT/home/.swap/turbodecky.swap" && ! -d "$ROOT/var/lib/turbodecky/state/transaction" ]]
run "$ROOT" --revert >/dev/null 2>&1

# An unexpected command failure must take the same recovery path.
ROOT="$(new_root unexpected)"
if TURBODECKY_ROOTFS="$ROOT" TURBODECKY_DRY_RUN=1 TURBODECKY_LIBRARY=1 \
  TURBODECKY_UI=terminal TURBODECKY_ASSUME_YES=1 bash -c \
  'source "$1"; apply_runtime_profiles() { false; }; apply_zram_profile' _ "$SCRIPT" \
  > "$TMP/unexpected.out" 2>&1; then exit 1; fi
grep -Fq 'Falha na etapa' "$TMP/unexpected.out"
grep -Fqx '# external zram' "$ROOT/etc/systemd/zram-generator.conf.d/00-turbodecky.conf"

# If recovery itself fails, retain the journal and allow a later retry.
ROOT="$(new_root partial)"
if TURBODECKY_ROOTFS="$ROOT" TURBODECKY_DRY_RUN=1 TURBODECKY_LIBRARY=1 \
  TURBODECKY_UI=terminal TURBODECKY_ASSUME_YES=1 bash -c '
    source "$1"
    prepare_apply zram
    backup="$OPERATION_DIR/backups/$(printf %s "$GRUB_FILE" | sha256sum | cut -d " " -f1)"
    cp "$backup" "$STATE_DIR/recovery-backup"
    printf "%s\n" "$backup" > "$STATE_DIR/recovery-path"
    rm "$backup"
    die "injected failure with missing transaction backup"
  ' _ "$SCRIPT" > "$TMP/partial.out" 2>&1; then exit 1; fi
STATE="$ROOT/var/lib/turbodecky/state"
grep -Fqx partial "$STATE/operation-state"
[[ -d "$STATE/transaction" && -f "$ROOT/etc/default/grub" ]]
cp "$STATE/recovery-backup" "$(cat "$STATE/recovery-path")"
run "$ROOT" --recover > "$TMP/retry.out" 2>&1
grep -Fqx '# external zram' "$ROOT/etc/systemd/zram-generator.conf.d/00-turbodecky.conf"
[[ ! -e "$ROOT/etc/sysctl.d/99-turbodecky.conf" ]]

# SIGKILL leaves a recoverable journal; a new application must refuse it.
ROOT="$(new_root killed)"
TURBODECKY_ROOTFS="$ROOT" TURBODECKY_DRY_RUN=1 TURBODECKY_LIBRARY=1 \
 TURBODECKY_UI=terminal TURBODECKY_ASSUME_YES=1 bash -c \
 'source "$1"; prepare_apply zram; kill -KILL $$' _ "$SCRIPT" >/dev/null 2>&1 &
pid=$!
wait "$pid" 2>/dev/null || true
[[ -d "$ROOT/var/lib/turbodecky/state/transaction" ]]
if run "$ROOT" --apply-zram > "$TMP/pending.out" 2>&1; then exit 1; fi
run "$ROOT" --recover > "$TMP/recovered.out" 2>&1
grep -Fqx '# external zram' "$ROOT/etc/systemd/zram-generator.conf.d/00-turbodecky.conf"
[[ ! -e "$ROOT/etc/sysctl.d/99-turbodecky.conf" ]]

# Existing files at either swap path must remain untouched without ownership.
ROOT="$(new_root swap)"
mkdir -p "$ROOT/home/.swap" "$ROOT/etc/modprobe.d" "$ROOT/etc/modules-load.d"
printf 'user swap\n' > "$ROOT/home/swapfile"
printf 'external dedicated-path file\n' > "$ROOT/home/.swap/turbodecky.swap"
printf '# user amdgpu settings\n' > "$ROOT/etc/modprobe.d/amdgpu.conf"
printf 'ntsync\n' > "$ROOT/etc/modules-load.d/ntsync.conf"
if run "$ROOT" --apply-zswap > "$TMP/swap.out" 2>&1; then exit 1; fi
grep -Fqx 'user swap' "$ROOT/home/swapfile"
grep -Fqx 'external dedicated-path file' "$ROOT/home/.swap/turbodecky.swap"
grep -Fqx '# user amdgpu settings' "$ROOT/etc/modprobe.d/amdgpu.conf"
grep -Fqx ntsync "$ROOT/etc/modules-load.d/ntsync.conf"

# Menus must return only the identifier; YAD must have an explicit separator.
ROOT="$(new_root menu)"
choice="$(TURBODECKY_ROOTFS="$ROOT" TURBODECKY_LIBRARY=1 TURBODECKY_UI=terminal \
 bash -c 'source "$1"; ui_menu' _ "$SCRIPT" <<< '3' 2>/dev/null)"
[[ "$choice" == status ]]
APPDIR_OUTPUT="$TMP/AppDir" bash "$REPO/packaging/appimage/build-appimage.sh" --appdir-only >/dev/null
printf '3\n6\n' | APPDIR="$TMP/AppDir" "$TMP/AppDir/AppRun" > "$TMP/menu.out" 2> "$TMP/menu.err"
grep -Fq 'Turbo Decky:' "$TMP/menu.out"
! grep -Fq 'Ação inválida' "$TMP/menu.err"
! grep -RniE 'setup_lavd|pacman -Sy|--setup-lavd' "$REPO/lib" "$REPO/packaging/appimage/turbodecky"

# The global lock must prevent another process from entering.
ROOT="$(new_root locked)"
mkdir -p "$ROOT/run/lock"
flock "$ROOT/run/lock/turbodecky.lock" bash -c \
  'TURBODECKY_ROOTFS="$1" TURBODECKY_DRY_RUN=1 TURBODECKY_UI=terminal bash "$2" --apply-zram' _ "$ROOT" "$SCRIPT" \
  > "$TMP/lock.out" 2>&1 && exit 1
grep -Fq 'Outra operação' "$TMP/lock.out"
printf 'Turbo Decky transaction and UI safety validation passed\n'
