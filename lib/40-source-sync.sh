#!/usr/bin/env bash
# Authoritative runtime profile synchronized with linux-charcoal-vulcano.
# The source-specific optional recompression setting is intentionally omitted;
# Turbo Decky keeps only the ordinary zram-generator configuration.
# vm.swappiness is intentionally left under SteamOS or user control.

readonly CHARCOAL_SYSCTL_ACTIVE=(
  "vm.page-cluster=0"
  "vm.min_free_kbytes=262144"
  "vm.compaction_proactiveness=15"
  "vm.dirty_expire_centisecs=3500"
  "vm.dirty_writeback_centisecs=500"
  "vm.watermark_boost_factor=0"
  "vm.watermark_scale_factor=125"
  "kernel.split_lock_mitigate=0"
  "vm.dirty_background_bytes=209715200"
  "vm.dirty_bytes=409430400"
  "vm.vfs_cache_pressure=125"
)

snapshot_runtime_once() {
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0
  [[ -f "$RUNTIME_SNAPSHOT" ]] && return 0
  mkdir -p "$STATE_DIR"
  : > "$RUNTIME_SNAPSHOT"
  local pair key value relative file
  for pair in "${CHARCOAL_SYSCTL_ACTIVE[@]}"; do
    key="${pair%%=*}"
    value="$(sysctl -n "$key" 2>/dev/null || true)"
    [[ -n "$value" ]] && printf 'sysctl\t%s\t%s\n' "$key" "$value" >> "$RUNTIME_SNAPSHOT"
  done
  for relative in \
    transparent_hugepage/enabled transparent_hugepage/defrag \
    transparent_hugepage/shmem_enabled transparent_hugepage/khugepaged/defrag \
    transparent_hugepage/khugepaged/max_ptes_none \
    transparent_hugepage/khugepaged/max_ptes_swap ksm/run \
    lru_gen/enabled lru_gen/min_ttl_ms; do
    file="/sys/kernel/mm/$relative"
    value="$(selector_value "$file" 2>/dev/null || true)"
    [[ -n "$value" ]] && printf 'sysfs\t%s\t%s\n' "$file" "$value" >> "$RUNTIME_SNAPSHOT"
  done
}

write_charcoal_sysctl() {
  backup_file_once "$SYSCTL_FILE"
  {
    printf '# Turbo Decky - perfil sincronizado com linux-charcoal-vulcano\n'
    printf '# vm.swappiness permanece sob controle do SteamOS ou do usuário.\n'
    printf '# Ajustes opcionais de recompressão não fazem parte deste perfil.\n'
    printf '%s\n' "${CHARCOAL_SYSCTL_ACTIVE[@]}"
  } | atomic_write "$SYSCTL_FILE" 0644
}

status_report() {
  local profile="não aplicado" lines=()
  [[ -f "$PROFILE_STATE" ]] && profile="$(cat "$PROFILE_STATE")"
  lines+=("Turbo Decky: $TURBODECKY_VERSION" "Perfil gerenciado: $profile")
  if [[ -z "$ROOTFS" ]]; then
    lines+=("Kernel: $(uname -r)")
    if command -v zramctl >/dev/null 2>&1; then
      lines+=("ZRAM: $(zramctl --noheadings --output NAME,ALGORITHM,DISKSIZE,DATA,COMPR 2>/dev/null | xargs || echo inativo)")
    fi
    local pair key value file
    for pair in "${CHARCOAL_SYSCTL_ACTIVE[@]}"; do
      key="${pair%%=*}"
      value="$(sysctl -n "$key" 2>/dev/null || echo indisponível)"
      lines+=("$key=$value")
    done
    for file in enabled defrag shmem_enabled khugepaged/defrag khugepaged/max_ptes_none khugepaged/max_ptes_swap; do
      value="$(selector_value "/sys/kernel/mm/transparent_hugepage/$file" 2>/dev/null || echo indisponível)"
      lines+=("THP $file=$value")
    done
  else
    lines+=("Root de teste: $ROOTFS")
  fi
  printf '%s\n' "${lines[@]}"
}

validate_generated_profile() {
  local failed=0 expected
  for expected in "${CHARCOAL_SYSCTL_ACTIVE[@]}"; do
    grep -Fqx "$expected" "$SYSCTL_FILE" || {
      printf 'ausente: %s\n' "$expected" >&2
      failed=1
    }
  done
  if grep -Eq '^[[:space:]]*vm\.swappiness[[:space:]]*=' "$SYSCTL_FILE"; then
    printf 'vm.swappiness não deve ser gerenciado pelo Turbo Decky\n' >&2
    failed=1
  fi
  for expected in "${CHARCOAL_MEMORY_TMPFILES[@]}"; do
    grep -Fqx "$expected" "$MEMORY_FILE" || {
      printf 'ausente: %s\n' "$expected" >&2
      failed=1
    }
  done
  grep -Fq 'compression-algorithm = lz4 zstd' "$ZRAM_FILE" || failed=1
  ! grep -Eqi 'recomp|OnUnitActiveSec|OnCalendar' "$ZRAM_FILE" || failed=1
  return "$failed"
}
