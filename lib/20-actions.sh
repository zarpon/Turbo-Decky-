#!/usr/bin/env bash
usage() {
  cat <<EOF_USAGE
Uso: $0 [ação]
  --apply-zswap       aplica sysctl/THP Charcoal e perfil ZSWAP
  --apply-zram        aplica sysctl/THP Charcoal e ZRAM padrão
  --status            mostra o diagnóstico
  --revert            restaura o snapshot anterior
  --recover           recupera uma operação interrompida
  --gui               abre a interface gráfica/TUI
  --version           mostra a versão
EOF_USAGE
}

main_gui() {
  local action
  while :; do
    action="$(ui_menu)"
    # Execute actions in their own shell so a handled menu error does not
    # disable errexit throughout the privileged backend.
    case "$action" in
      zswap) bash "$SCRIPT_DIR/InstallTD.sh" --apply-zswap || true ;;
      zram) bash "$SCRIPT_DIR/InstallTD.sh" --apply-zram || true ;;
      status) show_status ;;
      recover) bash "$SCRIPT_DIR/InstallTD.sh" --recover || true ;;
      revert) bash "$SCRIPT_DIR/InstallTD.sh" --revert || true ;;
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
    --recover) recover_operation ;;
    --gui) main_gui ;;
    --version) printf '%s\n' "$TURBODECKY_VERSION" ;;
    --help|-h) usage ;;
    *) usage; exit 2 ;;
  esac
}
