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
# Ordering after swap.target is not proof of successful backing swap.
swapon --show=NAME --noheadings --raw | grep -Fxq /home/.swap/turbodecky.swap
printf '0\n' > "$params/enabled"
printf 'lz4\n' > "$params/compressor"
printf '35\n' > "$params/max_pool_percent"
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
  ui_progress_update 5 "Validando requisitos, conflitos e memória disponível"
  prepare_apply zram
  ui_progress_update 28 "Finalizando a configuração de memória"
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
  operation_commit zram
  ui_info "Perfil ZRAM aplicado. O ZSWAP foi desativado em runtime e no próximo boot. Não há timer, serviço ou rotina de recompressão. Reinicie o sistema."
}

apply_zswap_profile() {
  ui_progress_start "Aplicando o perfil Charcoal com ZSWAP" 100
  ui_progress_update 5 "Validando requisitos, conflitos e memória disponível"
  prepare_apply zswap
  ui_progress_update 25 "Removendo a ZRAM ativa"
  remove_managed_zram
  ui_progress_update 34 "Removendo a configuração persistente da ZRAM"
  backup_file_once "$ZRAM_FILE"
  rm -f "$ZRAM_FILE"
  ui_progress_update 48 "Criando ou validando o swap exclusivo de 8 GiB"
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
  operation_commit zswap
  ui_info "Perfil ZSWAP aplicado e confirmado em runtime. O serviço persistente reafirmará a ativação após o swapfile estar disponível em cada boot. Reinicie o sistema."
}

revert_all() {
  require_root revert
  if [[ ! -s "$FILE_MANIFEST" ]]; then
    ui_info "Não há snapshot do Turbo Decky para reverter. Nenhuma alteração foi feita."
    return 0
  fi
  validate_snapshot || die "Snapshot inválido. Nenhuma reversão foi iniciada."
  check_file_conflicts || die "Conflito detectado; arquivos atuais e backups preservados."
  ui_confirm "Restaurar os snapshots verificados? O swap do SteamOS e arquivos externos serão preservados." || return 0
  ui_progress_start "Restaurando configurações do Turbo Decky" 100
  ui_progress_update 5 "Verificando snapshots e bloqueando outras operações"
  operation_begin revert
  ui_progress_update 20 "Parando o serviço ZSWAP gerenciado"
  remove_zswap_runtime_service
  ui_progress_update 35 "Desativando o swap exclusivo do Turbo Decky"
  remove_created_swapfile
  ui_progress_update 50 "Restaurando os arquivos verificados"
  restore_files
  if [[ -z "$ROOTFS" && "$DRY_RUN" != 1 ]]; then
    ui_progress_update 70 "Restaurando serviços e swap anteriores"
    systemctl daemon-reload
    restore_services
    restore_swap_activity
    udevadm control --reload-rules
    ui_progress_update 84 "Atualizando bootloader e initramfs"
    update_grub_runtime
  fi
  ui_progress_update 94 "Restaurando parâmetros de memória em runtime"
  restore_runtime
  operation_commit revert
  log "reversão concluída e verificada"
  ui_info "Configurações anteriores restauradas. Reinicie o sistema."
}
