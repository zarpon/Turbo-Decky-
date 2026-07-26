#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT="${1:-./InstallTD.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
ROOT="$TMP/root"
mkdir -p \
  "$ROOT/etc/default" \
  "$ROOT/etc/systemd/system" \
  "$ROOT/var/lib/turbodecky/state" \
  "$ROOT/var/lib/turbodecky/bin" \
  "$ROOT/home"
printf 'GRUB_CMDLINE_LINUX="quiet"\n' > "$ROOT/etc/default/grub"
printf '# baseline\n' > "$ROOT/etc/fstab"

export TURBODECKY_ROOTFS="$ROOT"
export TURBODECKY_DRY_RUN=1
export TURBODECKY_LIBRARY=1
export TURBODECKY_UI=terminal
export TURBODECKY_ASSUME_YES=1
# shellcheck source=/dev/null
source "$SCRIPT"

mkdir -p "$STATE_DIR" "$BACKUP_DIR"
write_zswap_runtime_service
[[ -x "$ZSWAP_RUNTIME_HELPER" ]]
[[ -s "$ZSWAP_RUNTIME_SERVICE" ]]
bash -n "$ZSWAP_RUNTIME_HELPER"
grep -Fqx 'After=local-fs.target systemd-sysctl.service swap.target' "$ZSWAP_RUNTIME_SERVICE"
grep -Fqx 'Wants=swap.target' "$ZSWAP_RUNTIME_SERVICE"
grep -Fqx 'ExecStart=/var/lib/turbodecky/bin/zswap-runtime-activate.sh' "$ZSWAP_RUNTIME_SERVICE"
remove_zswap_runtime_service
[[ ! -e "$ZSWAP_RUNTIME_HELPER" ]]
[[ ! -e "$ZSWAP_RUNTIME_SERVICE" ]]

# A zram device reported by zramctl is not necessarily an active swap. The
# guard must consult swapon first and avoid a false-positive failure.
MOCK_BIN="$TMP/mock-bin"
SYSTEMCTL_LOG="$TMP/systemctl.log"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/systemctl" <<'EOF_SYSTEMCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG:?}"
exit 0
EOF_SYSTEMCTL
cat > "$MOCK_BIN/swapon" <<'EOF_SWAPON'
#!/usr/bin/env bash
if [[ "${1:-}" == --show=NAME ]]; then
  exit 0
fi
exit 0
EOF_SWAPON
cat > "$MOCK_BIN/zramctl" <<'EOF_ZRAMCTL'
#!/usr/bin/env bash
printf '/dev/zram0\n'
EOF_ZRAMCTL
chmod +x "$MOCK_BIN/systemctl" "$MOCK_BIN/swapon" "$MOCK_BIN/zramctl"
export SYSTEMCTL_LOG
OLD_PATH="$PATH"
PATH="$MOCK_BIN:$PATH"
ROOTFS=""
DRY_RUN=0
remove_managed_zram
grep -Fqx 'mask --now systemd-zram-setup@zram0.service' "$SYSTEMCTL_LOG"
PATH="$OLD_PATH"

ROOTFS=""
DRY_RUN=0
ZSWAP_SYSFS_DIR="$TMP/zswap"
mkdir -p "$ZSWAP_SYSFS_DIR"
printf 'N\n' > "$ZSWAP_SYSFS_DIR/enabled"
printf 'zstd\n' > "$ZSWAP_SYSFS_DIR/compressor"
printf '20\n' > "$ZSWAP_SYSFS_DIR/max_pool_percent"
printf 'zbud\n' > "$ZSWAP_SYSFS_DIR/zpool"
printf 'N\n' > "$ZSWAP_SYSFS_DIR/shrinker_enabled"
chmod 0644 "$ZSWAP_SYSFS_DIR"/*
configure_zswap_runtime
grep -Fqx '1' "$ZSWAP_SYSFS_DIR/enabled"
grep -Fqx 'lz4' "$ZSWAP_SYSFS_DIR/compressor"
grep -Fqx '35' "$ZSWAP_SYSFS_DIR/max_pool_percent"
grep -Fqx 'zsmalloc' "$ZSWAP_SYSFS_DIR/zpool"
grep -Fqx '1' "$ZSWAP_SYSFS_DIR/shrinker_enabled"
zswap_runtime_enabled

printf 'N\n' > "$ZSWAP_SYSFS_DIR/enabled"
if (
  write_runtime_value() {
    local file="$1" value="$2"
    if [[ "$file" == "$ZSWAP_SYSFS_DIR/enabled" && "$value" == 1 ]]; then
      return 0
    fi
    printf '%s\n' "$value" > "$file"
  }
  configure_zswap_runtime
) 2> "$TMP/configure-failure.err"; then
  printf 'configure_zswap_runtime aceitou estado desativado\n' >&2
  exit 1
fi
grep -Fq 'O kernel manteve o ZSWAP desativado' "$TMP/configure-failure.err"
! grep -Eq '^(Y|1)$' "$ZSWAP_SYSFS_DIR/enabled"

declare -f apply_zswap_profile | grep -Fq 'write_zswap_runtime_service'
declare -f apply_zram_profile | grep -Fq 'remove_zswap_runtime_service'
declare -f revert_all | grep -Fq 'remove_zswap_runtime_service'

printf 'Turbo Decky ZSWAP runtime guard validation passed\n'
