setup_lavd() {
  require_root lavd
  command -v pacman >/dev/null 2>&1 || die "pacman não encontrado."
  unlock_steamos
  trap restore_steamos_readonly EXIT
  command -v steamos-devmode >/dev/null 2>&1 && steamos-devmode enable --no-prompt || true
  [[ ! -e /var/lib/pacman/db.lck ]] || die "O pacman está ocupado."
  pacman-key --init 2>/dev/null || true
  pacman-key --populate archlinux holo 2>/dev/null || true
  pacman -Sy --noconfirm --needed scx-scheds
  [[ -x /usr/bin/scx_lavd ]] || die "scx_lavd não foi instalado."
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
  systemctl daemon-reload
  systemctl enable --now scx_lavd.service
  ui_info "SCX LAVD instalado e ativo."
}

install_charcoal_kernel() {
  require_root kernel
  command -v pacman >/dev/null 2>&1 || die "pacman não encontrado."
  for command in curl python3 unzip; do command -v "$command" >/dev/null 2>&1 || die "Comando obrigatório ausente: $command"; done
  ui_confirm "Instalar os pacotes da última Release de zarpon/linux-charcoal-TD?" || return 0
  local tmp json url zip
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"; restore_steamos_readonly' EXIT
  json="$tmp/release.json"
  curl --fail --location --retry 3 https://api.github.com/repos/zarpon/linux-charcoal-TD/releases/latest -o "$json"
  url="$(python3 - "$json" <<'PY'
import json, sys
release=json.load(open(sys.argv[1], encoding='utf-8'))
assets=[a for a in release.get('assets',[]) if a.get('name','').endswith('.zip')]
if not assets: raise SystemExit(1)
print(assets[0]['browser_download_url'])
PY
)" || die "Release sem ZIP instalável."
  zip="$tmp/kernel.zip"
  curl --fail --location --retry 3 "$url" -o "$zip"
  unzip -tq "$zip"
  unzip -q "$zip" -d "$tmp/packages"
  mapfile -d '' -t packages < <(find "$tmp/packages" -type f -name '*.pkg.tar.zst' -print0)
  ((${#packages[@]} > 0)) || die "Nenhum pacote .pkg.tar.zst encontrado."
  unlock_steamos
  command -v steamos-devmode >/dev/null 2>&1 && steamos-devmode enable --no-prompt || true
  pacman -U --needed "${packages[@]}"
  update_grub_runtime
  ui_info "Kernel Charcoal instalado. Reinicie o sistema."
}

restore_stock_kernel() {
  require_root stock-kernel
  command -v pacman >/dev/null 2>&1 || die "pacman não encontrado."
  ui_confirm "Remover linux-charcoal e reinstalar linux-neptune-616?" || return 0
  unlock_steamos
  trap restore_steamos_readonly EXIT
  command -v steamos-devmode >/dev/null 2>&1 && steamos-devmode enable --no-prompt || true
  mapfile -t charcoal_packages < <(pacman -Qq 2>/dev/null | grep '^linux-charcoal' || true)
  ((${#charcoal_packages[@]} == 0)) || pacman -Rs --noconfirm "${charcoal_packages[@]}"
  pacman -S --noconfirm --needed linux-neptune-616
  update_grub_runtime
  ui_info "Kernel padrão reinstalado. Reinicie o sistema."
}

validate_generated_profile() {
  local failed=0 expected
  for expected in "${CHARCOAL_SYSCTL[@]}"; do
    grep -Fqx "$expected" "$SYSCTL_FILE" || { printf 'ausente: %s\n' "$expected" >&2; failed=1; }
  done
  for expected in "${CHARCOAL_MEMORY_TMPFILES[@]}"; do
    grep -Fqx "$expected" "$MEMORY_FILE" || { printf 'ausente: %s\n' "$expected" >&2; failed=1; }
  done
  grep -Fq 'compression-algorithm = lz4 zstd' "$ZRAM_FILE" || failed=1
  ! grep -Eqi 'recomp|OnUnitActiveSec|OnCalendar' "$ZRAM_FILE" || failed=1
  return "$failed"
}

usage() {
  cat <<EOF_USAGE
Uso: $0 [ação]
  --apply-zswap       aplica sysctl/THP Charcoal e perfil ZSWAP
  --apply-zram        aplica sysctl/THP Charcoal e ZRAM padrão
  --status            mostra o diagnóstico
  --revert            restaura o snapshot anterior
  --install-kernel    instala o kernel Charcoal
  --restore-kernel    restaura o kernel SteamOS
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
      kernel) install_charcoal_kernel ;;
      stock-kernel) restore_stock_kernel ;;
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
    --install-kernel) install_charcoal_kernel ;;
    --restore-kernel) restore_stock_kernel ;;
    --setup-lavd) setup_lavd ;;
    --gui) main_gui ;;
    --version) printf '%s\n' "$TURBODECKY_VERSION" ;;
    --help|-h) usage ;;
    *) usage; exit 2 ;;
  esac
}
