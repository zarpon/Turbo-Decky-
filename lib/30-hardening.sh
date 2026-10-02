#!/usr/bin/env bash
# Compatibility cleanup and safety layer. Sourced last so upgrades from older
# Turbo Decky releases are normalized before a new profile is applied.

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


prepare_apply() {
  operation_begin "$1"
  snapshot_runtime_once
  snapshot_services_once
  local file
  while IFS= read -r file; do backup_file_once "$file"; done < <(managed_files)
  ui_progress_update 14 "Snapshots completos; verificando componentes antigos"
  cleanup_legacy_installation
  ui_progress_update 20 "Gravando parâmetros de memória, cache e armazenamento"
  write_charcoal_sysctl
  write_charcoal_memory
  write_common_files
  ui_progress_update 24 "Aplicando a política de serviços"
  set_service_policy
}
