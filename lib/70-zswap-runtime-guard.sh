#!/usr/bin/env bash
# Runtime and boot-time guard for the ZSWAP profile. Sourced last so it can
# enforce postconditions after all compatibility layers have been loaded.

ZSWAP_RUNTIME_HELPER="$(p /var/lib/turbodecky/bin/zswap-runtime-activate.sh)"
ZSWAP_RUNTIME_SERVICE="$(p /etc/systemd/system/turbodecky-zswap-runtime.service)"

zswap_runtime_enabled() {
  local value
  [[ -r "$ZSWAP_SYSFS_DIR/enabled" ]] || return 1
  value="$(cat "$ZSWAP_SYSFS_DIR/enabled" 2>/dev/null || true)"
  [[ "$value" == Y || "$value" == 1 ]]
}

configure_zswap_runtime() {
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0
  [[ -d "$ZSWAP_SYSFS_DIR" ]] || \
    die "Os parâmetros runtime do ZSWAP não estão disponíveis neste kernel."

  write_runtime_value "$ZSWAP_SYSFS_DIR/enabled" 0 || \
    die "Não foi possível preparar o ZSWAP para configuração."
  write_runtime_value "$ZSWAP_SYSFS_DIR/compressor" lz4 || \
    die "Não foi possível configurar o compressor LZ4 do ZSWAP."
  write_runtime_value "$ZSWAP_SYSFS_DIR/max_pool_percent" 35 || \
    die "Não foi possível configurar o limite do pool do ZSWAP."
  write_runtime_value "$ZSWAP_SYSFS_DIR/zpool" zsmalloc || \
    die "Não foi possível configurar o zpool zsmalloc do ZSWAP."
  write_runtime_value "$ZSWAP_SYSFS_DIR/shrinker_enabled" 1 || \
    die "Não foi possível habilitar o shrinker do ZSWAP."
  write_runtime_value "$ZSWAP_SYSFS_DIR/enabled" 1 || \
    die "Não foi possível ativar o ZSWAP em runtime."

  zswap_runtime_enabled || \
    die "O kernel manteve o ZSWAP desativado após a tentativa de ativação."
}

write_zswap_runtime_service() {
  backup_file_once "$ZSWAP_RUNTIME_HELPER"
  cat <<'EOF_HELPER' | atomic_write "$ZSWAP_RUNTIME_HELPER" 0755
#!/usr/bin/env bash
set -Eeuo pipefail

readonly params=/sys/module/zswap/parameters
[[ -d "$params" ]]
printf '0\n' > "$params/enabled"
printf 'lz4\n' > "$params/compressor"
printf '35\n' > "$params/max_pool_percent"
printf 'zsmalloc\n' > "$params/zpool"
printf '1\n' > "$params/shrinker_enabled"
printf '1\n' > "$params/enabled"
value="$(cat "$params/enabled")"
[[ "$value" == Y || "$value" == 1 ]]
EOF_HELPER

  backup_file_once "$ZSWAP_RUNTIME_SERVICE"
  cat <<'EOF_SERVICE' | atomic_write "$ZSWAP_RUNTIME_SERVICE" 0644
[Unit]
Description=Turbo Decky ZSWAP runtime activation
Documentation=https://github.com/zarpon/Turbo-Decky-
After=local-fs.target systemd-sysctl.service swap.target
Wants=swap.target
ConditionPathExists=/sys/module/zswap/parameters/enabled

[Service]
Type=oneshot
ExecStart=/var/lib/turbodecky/bin/zswap-runtime-activate.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  if [[ -z "$ROOTFS" && "$DRY_RUN" != 1 ]]; then
    systemctl daemon-reload
    systemctl enable --now turbodecky-zswap-runtime.service
    systemctl is-active --quiet turbodecky-zswap-runtime.service || \
      die "O serviço persistente do ZSWAP não ficou ativo."
    zswap_runtime_enabled || \
      die "O ZSWAP permaneceu desativado após iniciar o serviço persistente."
  fi
}

remove_zswap_runtime_service() {
  if [[ -z "$ROOTFS" && "$DRY_RUN" != 1 ]]; then
    systemctl disable --now turbodecky-zswap-runtime.service 2>/dev/null || true
  fi
  rm -f -- "$ZSWAP_RUNTIME_SERVICE" "$ZSWAP_RUNTIME_HELPER"
  if [[ -z "$ROOTFS" && "$DRY_RUN" != 1 ]]; then
    systemctl daemon-reload 2>/dev/null || true
  fi
}

apply_zram_profile() {
  prepare_apply zram
  remove_zswap_runtime_service
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
  write_zswap_runtime_service
  update_grub_file zswap
  apply_runtime_profiles
  update_grub_runtime
  zswap_runtime_enabled || die "O ZSWAP não está ativo ao final da aplicação do perfil."
  printf 'zswap\n' > "$PROFILE_STATE"
  log "perfil ZSWAP aplicado"
  ui_info "Perfil ZSWAP aplicado e confirmado em runtime. O serviço persistente reafirmará a ativação após o swapfile estar disponível em cada boot. Reinicie o sistema."
}

revert_all() {
  require_root revert
  ui_confirm "A reversão restaurará os arquivos e estados capturados antes da primeira aplicação. Continuar?" || return 0
  unlock_steamos
  trap restore_steamos_readonly EXIT
  remove_zswap_runtime_service
  cleanup_legacy_installation
  remove_managed_zram
  remove_created_swapfile
  restore_files
  if [[ -z "$ROOTFS" && "$DRY_RUN" != 1 ]]; then
    systemctl daemon-reload 2>/dev/null || true
    restore_services
    sysctl --system 2>/dev/null || true
    udevadm control --reload-rules 2>/dev/null || true
    swapon -a 2>/dev/null || true
    update_grub_runtime
  fi
  restore_runtime
  rm -rf "$STATE_DIR"
  log "reversão concluída"
  ui_info "Reversão concluída. Os arquivos e estados anteriores foram restaurados quando havia snapshot disponível. Reinicie o sistema."
}
