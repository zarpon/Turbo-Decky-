enable_steamos_devmode() {
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0
  if command -v steamos-devmode >/dev/null 2>&1; then
    steamos-devmode enable --no-prompt || \
      die "Não foi possível habilitar o modo desenvolvedor do SteamOS."
  fi
}

setup_lavd() {
  require_root lavd
  ui_progress_start "Instalando e ativando o SCX LAVD" 100
  ui_progress_update 8 "Preparando o sistema"

  if [[ "$DRY_RUN" == 1 ]]; then
    ui_progress_update 60 "Simulação: nenhuma alteração será feita no sistema"
    ui_progress_finish "Simulação do SCX LAVD concluída"
    restore_steamos_readonly
    return 0
  fi

  command -v pacman >/dev/null 2>&1 || die "pacman não encontrado."
  command -v systemctl >/dev/null 2>&1 || die "systemctl não encontrado."
  unlock_steamos
  trap restore_steamos_readonly EXIT
  enable_steamos_devmode
  mkdir -p "$STATE_DIR" "$BACKUP_DIR"
  snapshot_services_once
  [[ ! -e "$(p /var/lib/pacman/db.lck)" ]] || die "O pacman está ocupado."
  ui_progress_update 24 "Inicializando as chaves do gerenciador de pacotes"
  pacman-key --init 2>/dev/null || true
  pacman-key --populate archlinux holo 2>/dev/null || true
  ui_progress_update 42 "Baixando e instalando o scheduler"
  pacman -Sy --noconfirm --needed scx-scheds
  ui_progress_update 60 "Validando o binário SCX LAVD"
  [[ -x "$(p /usr/bin/scx_lavd)" ]] || die "scx_lavd não foi instalado."
  ui_progress_update 72 "Gravando o serviço persistente"
  backup_file_once "$(p /etc/systemd/system/scx_lavd.service)"
  cat <<'EOF_LAVD' | atomic_write "$(p /etc/systemd/system/scx_lavd.service)" 0644
[Unit]
Description=Turbo Decky SCX LAVD
After=multi-user.target
Conflicts=scx.service

[Service]
Type=simple
ExecStart=/usr/bin/scx_lavd --performance
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_LAVD
  ui_progress_update 88 "Habilitando o serviço no boot"
  systemctl daemon-reload
  systemctl enable --now scx_lavd.service
  systemctl is-active --quiet scx_lavd.service || die "O serviço SCX LAVD não ficou ativo."
  ui_progress_finish "SCX LAVD instalado e ativo"
  restore_steamos_readonly
  ui_info "SCX LAVD instalado e ativo."
}

usage() {
  cat <<EOF_USAGE
Uso: $0 [ação]
  --apply-zswap       aplica sysctl/THP Charcoal e perfil ZSWAP
  --apply-zram        aplica sysctl/THP Charcoal e ZRAM padrão
  --status            mostra o diagnóstico
  --revert            restaura o snapshot anterior
  --setup-lavd        instala/ativa SCX LAVD
  --gui               abre a interface gráfica/TUI
  --version           mostra a versão
EOF_USAGE
}

main_gui() {
  local action
  while :; do
    action="$(ui_menu)"
    case "$action" in
      zswap) apply_zswap_profile ;;
      zram) apply_zram_profile ;;
      status) show_status ;;
      lavd) setup_lavd ;;
      revert) revert_all ;;
      *) break ;;
    esac
  done
}

main() {
  case "${1:---gui}" in
    --apply-zswap) apply_zswap_profile ;;
    --apply-zram) apply_zram_profile ;;
    --status) show_status ;;
    --revert) revert_all ;;
    --setup-lavd) setup_lavd ;;
    --gui) main_gui ;;
    --version) printf '%s\n' "$TURBODECKY_VERSION" ;;
    --help|-h) usage ;;
    *) usage; exit 2 ;;
  esac
}
