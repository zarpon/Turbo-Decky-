#!/usr/bin/env bash
# Authoritative runtime profile synchronized with linux-charcoal-vulcano.
# The source-specific optional recompression setting is intentionally omitted;
# Turbo Decky keeps only the ordinary zram-generator configuration.
# vm.swappiness is intentionally left under SteamOS or user control.

status_report() {
  local profile="não aplicado" lines=()
  [[ -f "$PROFILE_STATE" ]] && profile="$(cat "$PROFILE_STATE")"
  lines+=("Turbo Decky: $TURBODECKY_VERSION" "Perfil gerenciado: $profile")
  if [[ -z "$ROOTFS" ]]; then
    lines+=("Kernel: $(uname -r)")
    if command -v zramctl >/dev/null 2>&1; then
      local zram_status
      zram_status="$(zramctl --noheadings --output NAME,ALGORITHM,DISKSIZE,DATA,COMPR 2>/dev/null | xargs || true)"
      lines+=("ZRAM: ${zram_status:-inativo}")
    fi
    local pair key value file
    for pair in "${CHARCOAL_SYSCTL[@]}"; do
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
  for expected in "${CHARCOAL_SYSCTL[@]}"; do
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
