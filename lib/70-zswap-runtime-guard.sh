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
  write_runtime_value "$ZSWAP_SYSFS_DIR/compressor" "$ZSWAP_COMPRESSOR" || \
    die "Não foi possível configurar o compressor $ZSWAP_COMPRESSOR do ZSWAP."
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
  cat <<'EOF_HELPER' | sed "s/@TURBODECKY_ZSWAP_COMPRESSOR@/$ZSWAP_COMPRESSOR/g" | \
    atomic_write "$ZSWAP_RUNTIME_HELPER" 0755
#!/usr/bin/env bash
set -Eeuo pipefail

readonly params=/sys/module/zswap/parameters
[[ -d "$params" ]]
printf '0\n' > "$params/enabled"
printf '%s\n' '@TURBODECKY_ZSWAP_COMPRESSOR@' > "$params/compressor"
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
  ui_progress_start "Aplicando o perfil Charcoal com ZRAM" 100
  ui_progress_update 5 "Preparando snapshots e permissões"
  prepare_apply zram
  ui_progress_update 28 "Limpando componentes legados"
  remove_zswap_runtime_service
  ui_progress_update 38 "Removendo o swapfile incompatível"
  remove_created_swapfile
  ui_progress_update 48 "Gravando a configuração persistente da ZRAM"
  write_zram_config
  ui_progress_update 58 "Atualizando os parâmetros do boot"
  update_grub_file zram
  ui_progress_update 68 "Aplicando sysctl, THP e regras de armazenamento"
  apply_runtime_profiles
  ui_progress_update 76 "Desativando o ZSWAP"
  disable_zswap_runtime
  ui_progress_update 84 "Ativando a ZRAM"
  activate_zram
  ui_progress_update 92 "Atualizando o bootloader e o initramfs"
  update_grub_runtime
  ui_progress_update 97 "Registrando o perfil aplicado"
  printf 'zram\n' > "$PROFILE_STATE"
  log "perfil ZRAM aplicado"
  ui_progress_finish "Perfil ZRAM aplicado"
  restore_steamos_readonly
  ui_info "Perfil ZRAM aplicado. O ZSWAP foi desativado em runtime e no próximo boot. Não há timer, serviço ou rotina de recompressão. Reinicie o sistema."
}

apply_zswap_profile() {
  ui_progress_start "Aplicando o perfil Charcoal com ZSWAP" 100
  ui_progress_update 5 "Preparando snapshots e permissões"
  prepare_apply zswap
  ui_progress_update 25 "Removendo a ZRAM ativa"
  remove_managed_zram
  ui_progress_update 34 "Removendo a configuração persistente da ZRAM"
  backup_file_once "$ZRAM_FILE"
  rm -f "$ZRAM_FILE"
  ui_progress_update 48 "Criando e ativando o swapfile de suporte"
  ensure_swapfile
  ui_progress_update 60 "Configurando o ZSWAP em runtime"
  configure_zswap_runtime
  ui_progress_update 70 "Gravando a proteção de ativação no boot"
  write_zswap_runtime_service
  ui_progress_update 78 "Atualizando os parâmetros do boot"
  update_grub_file zswap
  ui_progress_update 86 "Aplicando sysctl, THP e regras de armazenamento"
  apply_runtime_profiles
  ui_progress_update 93 "Atualizando o bootloader e o initramfs"
  update_grub_runtime
  if [[ -z "$ROOTFS" && "$DRY_RUN" != 1 ]]; then
    zswap_runtime_enabled || die "O ZSWAP não está ativo ao final da aplicação do perfil."
  fi
  ui_progress_update 97 "Registrando o perfil aplicado"
  printf 'zswap\n' > "$PROFILE_STATE"
  log "perfil ZSWAP aplicado"
  ui_progress_finish "Perfil ZSWAP aplicado"
  restore_steamos_readonly
  ui_info "Perfil ZSWAP aplicado e confirmado em runtime. O serviço persistente reafirmará a ativação após o swapfile estar disponível em cada boot. Reinicie o sistema."
}

revert_all() {
  require_root revert
  ui_confirm "A reversão restaurará os arquivos e estados capturados antes da primeira aplicação. Continuar?" || return 0
  ui_progress_start "Revertendo as alterações do Turbo Decky" 100
  ui_progress_update 5 "Preparando a reversão"
  unlock_steamos
  trap restore_steamos_readonly EXIT
  ui_progress_update 18 "Removendo serviços persistentes do ZSWAP"
  remove_zswap_runtime_service
  ui_progress_update 28 "Limpando componentes legados"
  cleanup_legacy_installation
  ui_progress_update 38 "Parando a ZRAM gerenciada"
  remove_managed_zram
  ui_progress_update 48 "Removendo o swapfile criado pelo Turbo Decky"
  remove_created_swapfile
  ui_progress_update 60 "Restaurando arquivos do snapshot"
  restore_files
  if [[ -z "$ROOTFS" && "$DRY_RUN" != 1 ]]; then
    ui_progress_update 80 "Restaurando serviços e configurações do sistema"
    systemctl daemon-reload 2>/dev/null || true
    restore_services
    sysctl --system 2>/dev/null || true
    udevadm control --reload-rules 2>/dev/null || true
    swapon -a 2>/dev/null || true
    ui_progress_update 90 "Atualizando o bootloader e o initramfs"
    update_grub_runtime
  fi
  ui_progress_update 94 "Restaurando parâmetros de runtime"
  restore_runtime
  ui_progress_update 96 "Removendo o estado interno do Turbo Decky"
  rm -rf "$STATE_DIR"
  log "reversão concluída"
  ui_progress_finish "Reversão concluída"
  restore_steamos_readonly
  ui_info "Reversão concluída. Os arquivos e estados anteriores foram restaurados quando havia snapshot disponível. Reinicie o sistema."
}
