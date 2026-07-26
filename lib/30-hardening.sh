#!/usr/bin/env bash
# Compatibility cleanup and safety layer. Sourced last so upgrades from older
# Turbo Decky releases are normalized before a new profile is applied.

: "${KERNEL_TMP_DIR:=}"

if ! declare -p LEGACY_GENERATED_FILES >/dev/null 2>&1; then
LEGACY_GENERATED_FILES=(
  "/etc/systemd/system/zswap-config.service"
  "/etc/systemd/system/zram-config.service"
  "/etc/systemd/system/mglru-tune.service"
  "/etc/systemd/system/thp-config.service"
  "/etc/systemd/system/io-boost@.service"
  "/etc/systemd/system/turbodecky-power-monitor.service"
  "/etc/tmpfiles.d/TdMemoryTweak.conf"
  "/etc/tmpfiles.d/mglru.conf"
  "/etc/tmpfiles.d/thp_shrinker.conf"
  "/etc/tmpfiles.d/custom-timers.conf"
  "/etc/security/limits.d/99-game-limits.conf"
  "/etc/modprobe.d/amdgpu.conf"
  "/etc/modprobe.d/99-amdgpu-tuning.conf"
  "/etc/modules-load.d/ntsync.conf"
  "/etc/udev/rules.d/99-turbodecky-power.rules"
  "/etc/udev/rules.d/99-io-boost.rules"
  "/etc/systemd/zram-generator.conf.d/00-turbodecky.conf"
  "/var/lib/turbodecky/bin/zswap-config.sh"
  "/var/lib/turbodecky/bin/zram-config.sh"
  "/var/lib/turbodecky/bin/io-boost.sh"
  "/var/lib/turbodecky/bin/turbodecky-power-monitor.sh"
  "/var/lib/turbodecky/bin/thp-config.sh"
  "/usr/local/bin/zswap-config.sh"
  "/usr/local/bin/zram-config.sh"
  "/usr/local/bin/io-boost.sh"
  "/usr/local/bin/turbodecky-power-monitor.sh"
)
readonly LEGACY_GENERATED_FILES
fi

restore_legacy_backup() {
  local target="$1" backup="${1}.bak-turbodecky"
  if [[ -e "$backup" || -L "$backup" ]]; then
    rm -rf -- "$target"
    mv -- "$backup" "$target"
    log "backup legado restaurado: $target"
    return 0
  fi
  return 1
}

prepare_apply() {
  require_root "$@"
  unlock_steamos
  trap restore_steamos_readonly EXIT
  mkdir -p "$STATE_DIR" "$BACKUP_DIR"
  # Capture runtime and service state before legacy cleanup disables or
  # removes anything; otherwise reversal would snapshot the already-changed
  # state instead of the user's original state.
  snapshot_runtime_once
  snapshot_services_once
  # This path is also listed among legacy artifacts. Snapshot it before the
  # cleanup, otherwise the first application would erase a pre-existing
  # user configuration and reversal could not restore it.
  backup_file_once "$ZRAM_FILE"
  cleanup_legacy_installation
  write_charcoal_sysctl
  write_charcoal_memory
  write_common_files
  set_service_policy
}
