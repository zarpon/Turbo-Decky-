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
  if [[ -e "$enabled" ]]; then
    write_runtime_value "$enabled" 0 || log "não foi possível desativar o ZSWAP em runtime"
  fi
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
  write_runtime_value "$ZSWAP_SYSFS_DIR/compressor" lz4 || true
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

remove_managed_zram() {
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0
  # Masking is required: stopping alone allows the generator-created unit to
  # return on the next boot when a vendor ZRAM configuration still exists.
  systemctl mask --now systemd-zram-setup@zram0.service 2>/dev/null || true
}

activate_zram() {
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0
  disable_zswap_runtime
  systemctl daemon-reload
  systemctl unmask systemd-zram-setup@zram0.service 2>/dev/null || true
  systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || true
}

apply_zram_profile() {
  prepare_apply zram
  remove_created_swapfile
  write_zram_config
  update_grub_file zram
  apply_runtime_profiles
  disable_zswap_runtime
  activate_zram
  update_grub_runtime
  printf 'zram\n' > "$PROFILE_STATE"
  log "perfil ZRAM aplicado"
  ui_info "Perfil ZRAM aplicado. O ZSWAP foi desativado em runtime e no próximo boot. Não há timer, serviço ou rotina de recompressão. Reinicie o sistema."
}

apply_zswap_profile() {
  prepare_apply zswap
  remove_managed_zram
  backup_file_once "$ZRAM_FILE"
  rm -f "$ZRAM_FILE"
  ensure_swapfile
  configure_zswap_runtime
  update_grub_file zswap
  apply_runtime_profiles
  update_grub_runtime
  printf 'zswap\n' > "$PROFILE_STATE"
  log "perfil ZSWAP aplicado"
  ui_info "Perfil ZSWAP aplicado. O ZRAM foi interrompido e mascarado para permanecer desativado no próximo boot. Reinicie o sistema."
}
