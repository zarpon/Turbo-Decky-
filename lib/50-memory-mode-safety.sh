#!/usr/bin/env bash
# Final memory-mode safety layer. This file is sourced after every compatibility
# and source-sync layer so ZRAM and ZSWAP remain mutually exclusive at runtime
# and across boots, while reversal restores the state captured before Turbo Decky.

ZSWAP_SYSFS_DIR="${TURBODECKY_ZSWAP_SYSFS_DIR:-/sys/module/zswap/parameters}"

write_runtime_value() {
  local file="$1" value="$2"
  [[ -w "$file" ]] || return 1
  printf '%s\n' "$value" > "$file"
}

disable_zswap_runtime() {
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0
  local enabled="$ZSWAP_SYSFS_DIR/enabled"
  [[ -e "$enabled" ]] || return 0
  write_runtime_value "$enabled" 0 || die "Não foi possível desativar o ZSWAP em runtime."
  case "$(cat "$enabled" 2>/dev/null || true)" in
    N|0) ;;
    *) die "O ZSWAP permaneceu ativo depois da tentativa de desativação." ;;
  esac
}

configure_zswap_runtime() {
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0
  [[ -d "$ZSWAP_SYSFS_DIR" ]] || {
    log "parâmetros runtime do ZSWAP indisponíveis; a configuração será aplicada no próximo boot"
    return 0
  }

  # Disable first so compressor/zpool can be changed safely, then enable only
  # after a real backing swapfile has been activated.
  write_runtime_value "$ZSWAP_SYSFS_DIR/enabled" 0 || true
  write_runtime_value "$ZSWAP_SYSFS_DIR/compressor" "$ZSWAP_COMPRESSOR" || true
  write_runtime_value "$ZSWAP_SYSFS_DIR/max_pool_percent" 35 || true
  write_runtime_value "$ZSWAP_SYSFS_DIR/zpool" zsmalloc || true
  write_runtime_value "$ZSWAP_SYSFS_DIR/shrinker_enabled" 1 || true
  write_runtime_value "$ZSWAP_SYSFS_DIR/enabled" 1 || \
    log "não foi possível ativar o ZSWAP em runtime; ele será ativado no próximo boot"
}

snapshot_runtime_once() {
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0
  [[ -f "$RUNTIME_SNAPSHOT" ]] && return 0
  mkdir -p "$STATE_DIR"
  : > "$RUNTIME_SNAPSHOT"

  local pair key value relative file
  for pair in "${CHARCOAL_SYSCTL[@]}"; do
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

  # Keep enabled last. During restore, ZSWAP is disabled first, parameters are
  # restored, and its original enabled state is written only at the end.
  for relative in compressor max_pool_percent zpool shrinker_enabled enabled; do
    file="$ZSWAP_SYSFS_DIR/$relative"
    [[ -r "$file" ]] || continue
    value="$(cat "$file" 2>/dev/null || true)"
    [[ -n "$value" ]] && printf 'sysfs\t%s\t%s\n' "$file" "$value" >> "$RUNTIME_SNAPSHOT"
  done
}

restore_runtime() {
  [[ -f "$RUNTIME_SNAPSHOT" ]] || return 0
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0

  # If ZSWAP parameters were captured, turn it off before restoring mutable
  # compressor/zpool values. Its saved enabled value is the final snapshot row.
  if grep -Fq $'sysfs\t'"$ZSWAP_SYSFS_DIR/" "$RUNTIME_SNAPSHOT" 2>/dev/null; then
    write_runtime_value "$ZSWAP_SYSFS_DIR/enabled" 0 || true
  fi

  local type key value
  while IFS=$'\t' read -r type key value; do
    case "$type" in
      sysctl) sysctl -q -w "$key=$value" 2>/dev/null || true ;;
      sysfs) write_runtime_value "$key" "$value" 2>/dev/null || true ;;
    esac
  done < "$RUNTIME_SNAPSHOT"
}

restore_services() {
  [[ -f "$SERVICE_SNAPSHOT" ]] || return 0
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0

  local service enabled active
  while IFS=$'\t' read -r service enabled active; do
    if [[ "$enabled" == masked || "$enabled" == masked-runtime ]]; then
      systemctl mask "$service" 2>/dev/null || true
    else
      # static/generated/indirect units cannot be enabled, but they still must
      # be unmasked because Turbo Decky may have masked them for ZSWAP.
      systemctl unmask "$service" 2>/dev/null || true
      case "$enabled" in
        enabled|enabled-runtime|linked|linked-runtime|alias)
          systemctl enable "$service" 2>/dev/null || true
          ;;
        disabled)
          systemctl disable "$service" 2>/dev/null || true
          ;;
      esac
    fi

    if [[ "$active" == active ]]; then
      systemctl start "$service" 2>/dev/null || true
    else
      systemctl stop "$service" 2>/dev/null || true
    fi
  done < "$SERVICE_SNAPSHOT"
}

cleanup_legacy_installation() {
  local file
  cleanup_legacy_recompression
  if [[ -z "$ROOTFS" && "$DRY_RUN" != 1 ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now zswap-config.service zram-config.service \
      mglru-tune.service thp-config.service turbodecky-power-monitor.service \
      2>/dev/null || true
  fi
  restore_legacy_backup "$(p /etc/fstab)" || true
  restore_legacy_backup "$(p /etc/default/grub)" || true
  restore_legacy_backup "$(p /etc/sysctl.d/99-sdweak-performance.conf)" || \
    rm -f -- "$(p /etc/sysctl.d/99-sdweak-performance.conf)"
  restore_legacy_backup "$(p /usr/lib/systemd/zram-generator.conf)" || true
  for file in "${LEGACY_GENERATED_FILES[@]}"; do
    rm -rf -- "$(p "$file")"
  done
  rm -f -- "$(p /etc/environment.d/)"turbodecky*.conf 2>/dev/null || true
  if [[ -z "$ROOTFS" && "$DRY_RUN" != 1 ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
  fi
}

zram_runtime_devices() {
  local device
  if command -v swapon >/dev/null 2>&1; then
    if swapon --show=NAME --noheadings --raw 2>/dev/null | while IFS= read -r device; do
      if [[ "$device" =~ (^|/)zram[0-9]+$ ]]; then
        printf '%s\n' "$device"
      fi
    done; then
      return 0
    fi
  fi
  if command -v zramctl >/dev/null 2>&1; then
    zramctl --noheadings --output NAME 2>/dev/null | while IFS= read -r device; do
      if [[ "$device" =~ (^|/)zram[0-9]+$ ]]; then
        printf '%s\n' "$device"
      fi
    done
  fi
}

zram_runtime_active() {
  [[ -n "$(zram_runtime_devices)" ]]
}

remove_managed_zram() {
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0
  # Masking is required: stopping alone allows the generator-created unit to
  # return on the next boot when a vendor ZRAM configuration still exists.
  systemctl mask --now systemd-zram-setup@zram0.service 2>/dev/null || \
    die "Não foi possível mascarar e parar a ZRAM antes de ativar o ZSWAP."
  if zram_runtime_active; then
    while IFS= read -r device; do
      [[ -n "$device" ]] || continue
      swapoff "$device" 2>/dev/null || true
    done < <(zram_runtime_devices)
    zram_runtime_active && die "A ZRAM permaneceu ativa depois da tentativa de desativação."
  fi
}

activate_zram() {
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0
  disable_zswap_runtime
  systemctl daemon-reload || die "Não foi possível recarregar as unidades da ZRAM."
  systemctl unmask systemd-zram-setup@zram0.service || \
    die "Não foi possível liberar a unidade da ZRAM."
  systemctl restart systemd-zram-setup@zram0.service || \
    die "Não foi possível ativar a ZRAM em runtime."
  systemctl is-active --quiet systemd-zram-setup@zram0.service || \
    die "A unidade da ZRAM não ficou ativa após a reinicialização."
}
