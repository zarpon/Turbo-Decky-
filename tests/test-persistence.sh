#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT="${1:-./InstallTD.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
ROOT="$TMP/root"
mkdir -p "$ROOT/etc/default" "$ROOT/etc/systemd/zram-generator.conf.d" "$ROOT/home"
printf 'GRUB_CMDLINE_LINUX="quiet splash"\n' > "$ROOT/etc/default/grub"
printf '# baseline fstab\n' > "$ROOT/etc/fstab"
printf '# user zram configuration\n' > "$ROOT/etc/systemd/zram-generator.conf.d/00-turbodecky.conf"
printf 'original swap contents\n' > "$ROOT/home/swapfile"
export TURBODECKY_ROOTFS="$ROOT" TURBODECKY_DRY_RUN=1 TURBODECKY_LIBRARY=1
export TURBODECKY_UI=terminal TURBODECKY_ASSUME_YES=1
source "$SCRIPT"

apply_zram_profile
[[ -s "$SYSCTL_FILE" && -s "$MEMORY_FILE" && -s "$ENV_FILE" && -s "$UDEV_FILE" ]]
grep -Fqx zram "$PROFILE_STATE"
grep -Fq mitigations=off "$GRUB_FILE"
grep -Fq zswap.enabled=0 "$GRUB_FILE"
! grep -Fq 'iostats}="0"' "$UDEV_FILE"
apply_zswap_profile
[[ ! -e "$ZRAM_FILE" && -f "$ZSWAP_RUNTIME_SERVICE" ]]
[[ "$(stat -Lc '%s' "$SWAPFILE")" == 8589934592 ]]
grep -Fq "$SWAPFILE none swap sw,pri=-2 0 0" "$FSTAB_FILE"
grep -Fqx 'original swap contents' "$ROOT/home/swapfile"
grep -Fq 'grep -Fxq /home/.swap/turbodecky.swap' "$ZSWAP_RUNTIME_HELPER"
[[ -f "$STATE_DIR/swapfile-created" && ! -d "$STATE_DIR/transaction" ]]
apply_zram_profile
[[ ! -e "$SWAPFILE" ]]
grep -Fqx 'original swap contents' "$ROOT/home/swapfile"
apply_zswap_profile
revert_all
grep -Fqx 'GRUB_CMDLINE_LINUX="quiet splash"' "$GRUB_FILE"
grep -Fqx '# baseline fstab' "$FSTAB_FILE"
grep -Fqx '# user zram configuration' "$ZRAM_FILE"
grep -Fqx 'original swap contents' "$ROOT/home/swapfile"
[[ ! -e "$SWAPFILE" && ! -e "$STATE_DIR" ]]
for f in "$SYSCTL_FILE" "$MEMORY_FILE" "$ENV_FILE" "$LIMITS_FILE" "$UDEV_FILE"; do [[ ! -e "$f" ]]; done

# Broken symlinks are preserved exactly by snapshots.
mkdir -p "$ROOT/etc" "$STATE_DIR"
ln -s /nonexistent-target "$ROOT/etc/test-link"
backup_file_once "$ROOT/etc/test-link"
rm "$ROOT/etc/test-link"
printf 'replacement\n' > "$ROOT/etc/test-link"
restore_files
[[ -L "$ROOT/etc/test-link" && "$(readlink "$ROOT/etc/test-link")" == /nonexistent-target ]]
printf 'Turbo Decky safe persistence validation passed\n'
