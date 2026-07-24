#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT="${1:-./InstallTD.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ROOT="$TMP/root"
mkdir -p "$ROOT/etc/sysctl.d" "$ROOT/etc/tmpfiles.d" \
  "$ROOT/etc/systemd/zram-generator.conf.d" "$ROOT/etc/default" \
  "$ROOT/etc/security/limits.d" "$ROOT/etc/environment.d" \
  "$ROOT/etc/udev/rules.d" "$ROOT/etc/systemd/system" \
  "$ROOT/usr/local/bin" "$ROOT/var/lib/turbodecky/state" "$ROOT/home"
printf 'GRUB_CMDLINE_LINUX="quiet splash zswap.enabled=0 mitigations=auto"\n' > "$ROOT/etc/default/grub"
printf 'original=1\n' > "$ROOT/etc/sysctl.d/99-turbodecky.conf"

export TURBODECKY_ROOTFS="$ROOT"
export TURBODECKY_DRY_RUN=1
export TURBODECKY_LIBRARY=1
export TURBODECKY_UI=terminal
export TURBODECKY_ASSUME_YES=1
# shellcheck source=/dev/null
source "$SCRIPT"

# Backup e restauração devem preservar exatamente o arquivo preexistente.
write_charcoal_sysctl
grep -Fqx 'vm.swappiness=1' "$SYSCTL_FILE"
restore_files
grep -Fqx 'original=1' "$SYSCTL_FILE"

# Reinicia o estado para validar uma instalação limpa.
rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR" "$BACKUP_DIR"
write_charcoal_sysctl
write_charcoal_memory
write_zram_config
validate_generated_profile

required_sysctl=(
  'vm.swappiness=1'
  'vm.page-cluster=0'
  'vm.min_free_kbytes=262144'
  'vm.compaction_proactiveness=15'
  'vm.dirty_expire_centisecs=3500'
  'vm.dirty_writeback_centisecs=500'
  'vm.watermark_boost_factor=0'
  'vm.watermark_scale_factor=125'
  'kernel.split_lock_mitigate=0'
  'vm.dirty_background_bytes=209715200'
  'vm.dirty_bytes=409430400'
  'vm.vfs_cache_pressure=125'
)
for line in "${required_sysctl[@]}"; do grep -Fqx "$line" "$SYSCTL_FILE"; done
! grep -Fq 'zram_recomp' "$SYSCTL_FILE"

required_memory=(
  'w! /sys/kernel/mm/transparent_hugepage/enabled - - - - madvise'
  'w! /sys/kernel/mm/transparent_hugepage/defrag - - - - defer'
  'w! /sys/kernel/mm/transparent_hugepage/shmem_enabled - - - - advise'
  'w! /sys/kernel/mm/transparent_hugepage/khugepaged/defrag - - - - 0'
  'w! /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_none - - - - 64'
  'w! /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_swap - - - - 0'
  'w! /sys/kernel/mm/ksm/run - - - - 0'
  'w! /sys/kernel/mm/lru_gen/enabled - - - - 7'
  'w! /sys/kernel/mm/lru_gen/min_ttl_ms - - - - 0'
)
for line in "${required_memory[@]}"; do grep -Fqx "$line" "$MEMORY_FILE"; done

# O ZRAM permanece padrão; não há unidade, calendário ou comando de recompressão.
grep -Fqx 'compression-algorithm = lz4 zstd' "$ZRAM_FILE"
! grep -Eqi 'recomp|OnUnitActiveSec|OnCalendar' "$ZRAM_FILE"

# Migração remove resíduos de versões antigas sem recriá-los.
for file in "${LEGACY_RECOMPRESSION_FILES[@]}"; do
  target="$(p "$file")"
  mkdir -p "$(dirname "$target")"
  : > "$target"
done
cleanup_legacy_recompression
for file in "${LEGACY_RECOMPRESSION_FILES[@]}"; do [[ ! -e "$(p "$file")" ]]; done

# A edição do GRUB é idempotente e não duplica chaves.
update_grub_file zram
grep -Fq 'zswap.enabled=0' "$GRUB_FILE"
[[ "$(grep -o 'zswap.enabled=' "$GRUB_FILE" | wc -l)" -eq 1 ]]
update_grub_file zswap
grep -Fq 'zswap.enabled=1' "$GRUB_FILE"
grep -Fq 'zswap.compressor=lz4' "$GRUB_FILE"
[[ "$(grep -o 'zswap.enabled=' "$GRUB_FILE" | wc -l)" -eq 1 ]]

# Status e versão devem funcionar sem privilégios em um root isolado.
status_report | grep -Fq 'Root de teste:'
TURBODECKY_LIBRARY=0 TURBODECKY_ROOTFS="$ROOT" TURBODECKY_DRY_RUN=1 \
  bash "$SCRIPT" --version | grep -Fqx '4.0.0-test'

# Ciclo completo em root isolado: aplica, cria os arquivos e reverte ao baseline.
CYCLE_ROOT="$TMP/cycle-root"
mkdir -p "$CYCLE_ROOT/etc/default" "$CYCLE_ROOT/etc/systemd/system" \
  "$CYCLE_ROOT/usr/local/bin" "$CYCLE_ROOT/var/log"
printf 'GRUB_CMDLINE_LINUX="quiet"\n' > "$CYCLE_ROOT/etc/default/grub"
TURBODECKY_LIBRARY=0 TURBODECKY_ROOTFS="$CYCLE_ROOT" \
  TURBODECKY_DRY_RUN=1 TURBODECKY_UI=terminal TURBODECKY_ASSUME_YES=1 \
  bash "$SCRIPT" --apply-zram >/dev/null
for generated in \
  "$CYCLE_ROOT/etc/sysctl.d/99-turbodecky.conf" \
  "$CYCLE_ROOT/etc/tmpfiles.d/99-turbodecky-memory.conf" \
  "$CYCLE_ROOT/etc/systemd/zram-generator.conf.d/00-turbodecky.conf"; do
  [[ -s "$generated" ]]
done
TURBODECKY_LIBRARY=0 TURBODECKY_ROOTFS="$CYCLE_ROOT" \
  TURBODECKY_DRY_RUN=1 TURBODECKY_UI=terminal TURBODECKY_ASSUME_YES=1 \
  bash "$SCRIPT" --revert >/dev/null
for generated in \
  "$CYCLE_ROOT/etc/sysctl.d/99-turbodecky.conf" \
  "$CYCLE_ROOT/etc/tmpfiles.d/99-turbodecky-memory.conf" \
  "$CYCLE_ROOT/etc/systemd/zram-generator.conf.d/00-turbodecky.conf"; do
  [[ ! -e "$generated" ]]
done
grep -Fqx 'GRUB_CMDLINE_LINUX="quiet"' "$CYCLE_ROOT/etc/default/grub"

printf 'Turbo Decky local validation passed\n'
