pacman_installed_packages() {
  command -v pacman >/dev/null 2>&1 || return 1
  pacman -Qq 2>/dev/null
}

kernel_stock_package_list() {
  local installed
  installed="$(pacman_installed_packages)" || return 1
  grep -E '^linux-neptune($|[-.])' <<< "$installed" || true
}

kernel_charcoal_installed() {
  local installed
  installed="$(pacman_installed_packages)" || return 1
  grep -Eq '^linux-charcoal($|[-.])' <<< "$installed"
}

kernel_install_confirmation() {
  local stock_packages=("$@") stock_list charcoal_present=0
  kernel_charcoal_installed && charcoal_present=1 || true
  stock_list="$(IFS=', '; printf '%s' "${stock_packages[*]}")"

  if (( ! charcoal_present )); then
    if ((${#stock_packages[@]} > 0)); then
      ui_confirm_required "Esta é a primeira instalação do kernel Charcoal. Para evitar falha, o kernel stock ($stock_list) será removido obrigatoriamente antes da instalação. Continuar?"
    else
      ui_confirm_required "Esta é a primeira instalação do kernel Charcoal. Nenhum kernel stock foi detectado; se existir um pacote fora do banco do pacman, ele também deverá ser removido para evitar conflito. Continuar?"
    fi
  elif ((${#stock_packages[@]} > 0)); then
    ui_confirm_required "O kernel stock ($stock_list) ainda está instalado. Ele será removido obrigatoriamente antes de atualizar o kernel Charcoal; mantê-lo pode causar falha. Continuar?"
  else
    ui_confirm "Instalar os pacotes da última release de zarpon/linux-charcoal-TD?"
  fi
}

kernel_package_names() {
  local package name
  for package in "$@"; do
    name="$(pacman -Qp --print-format '%n' "$package" 2>/dev/null)" || return 1
    [[ -n "$name" ]] || return 1
    printf '%s\n' "$name"
  done
}

kernel_stock_candidate() {
  local candidates preferred
  if ! command -v pacman >/dev/null 2>&1; then
    if [[ "$DRY_RUN" == 1 ]]; then
      printf '%s\n' linux-neptune-616
      return 0
    fi
    return 1
  fi
  if ! candidates="$(pacman -Ssq '^linux-neptune($|[-.])' 2>/dev/null)"; then
    if [[ "$DRY_RUN" == 1 ]]; then
      printf '%s\n' linux-neptune-616
      return 0
    fi
    return 1
  fi
  # Do not select headers/debug/firmware subpackages as the bootable stock
  # kernel. Keep only the base package with a numeric version suffix.
  candidates="$(grep -E '^linux-neptune(-[0-9][0-9.-]*)?$' <<< "$candidates" || true)"
  preferred="$(grep -Fx 'linux-neptune-616' <<< "$candidates" || true)"
  if [[ -n "$preferred" ]]; then
    printf '%s\n' "$preferred"
  elif [[ -n "$candidates" ]]; then
    sort -V <<< "$candidates" | tail -n 1
  else
    if [[ "$DRY_RUN" == 1 ]]; then
      printf '%s\n' linux-neptune-616
      return 0
    fi
    return 1
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
  mkdir -p "$STATE_DIR" "$BACKUP_DIR"
  snapshot_services_once
  command -v steamos-devmode >/dev/null 2>&1 && steamos-devmode enable --no-prompt || true
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

install_charcoal_kernel() {
  require_root kernel
  local stock_packages=() stock_list remaining_stock=() installed_packages
  local tmp json url zip package package_name charcoal_package_found=0
  local packages=()
  installed_packages=""
  if command -v pacman >/dev/null 2>&1; then
    installed_packages="$(pacman_installed_packages)" || {
      [[ "$DRY_RUN" == 1 ]] || \
        die "Não foi possível consultar os pacotes instalados no pacman."
    }
  else
    [[ "$DRY_RUN" == 1 ]] || die "pacman não encontrado."
  fi
  mapfile -t stock_packages < <(grep -E '^linux-neptune($|[-.])' <<< "$installed_packages" || true)
  if [[ "${TURBODECKY_KERNEL_STOCK_CONFIRMED:-0}" != 1 ]]; then
    if ! kernel_install_confirmation "${stock_packages[@]}"; then
      cleanup_dry_run_sandbox
      return 0
    fi
  fi

  ui_progress_start "Instalando o kernel Charcoal" 100
  ui_progress_update 8 "Preparando a instalação"
  if [[ "$DRY_RUN" == 1 ]]; then
    ui_progress_update 60 "Simulação: o pacote e o kernel stock não serão alterados"
    ui_progress_finish "Simulação da instalação do kernel concluída"
    restore_steamos_readonly
    return 0
  fi

  for command in pacman curl python3 unzip; do
    command -v "$command" >/dev/null 2>&1 || die "Comando obrigatório ausente: $command"
  done

  tmp="$(mktemp -d)"
  KERNEL_TMP_DIR="$tmp"
  trap 'rm -rf -- "${KERNEL_TMP_DIR:-}"; KERNEL_TMP_DIR=""; restore_steamos_readonly' EXIT
  unlock_steamos
  json="$tmp/release.json"
  ui_progress_update 22 "Consultando a última release"
  curl --fail --location --retry 3 \
    https://api.github.com/repos/zarpon/linux-charcoal-TD/releases/latest -o "$json"
  url="$(python3 - "$json" <<'PY'
import json
import sys

release = json.load(open(sys.argv[1], encoding="utf-8"))
assets = [
    asset for asset in release.get("assets", [])
    if asset.get("name", "").lower().endswith(".zip")
    and asset.get("browser_download_url")
]
if not assets:
    raise SystemExit(1)
print(assets[0]["browser_download_url"])
PY
)" || die "Release sem ZIP instalável."

  zip="$tmp/kernel.zip"
  ui_progress_update 38 "Baixando os pacotes do kernel"
  curl --fail --location --retry 3 "$url" -o "$zip"
  ui_progress_update 52 "Validando o arquivo ZIP"
  unzip -tq "$zip"
  ui_progress_update 60 "Extraindo os pacotes"
  unzip -q "$zip" -d "$tmp/packages"
  mapfile -d '' -t packages < <(
    find "$tmp/packages" -type f -name '*.pkg.tar.zst' -print0
  )
  ((${#packages[@]} > 0)) || die "Nenhum pacote .pkg.tar.zst encontrado."

  ui_progress_update 64 "Validando cada pacote antes de remover o kernel stock"
  for package in "${packages[@]}"; do
    package_name="$(kernel_package_names "$package")" || \
      die "Pacote inválido ou ilegível: $(basename "$package")"
    if [[ "$package_name" =~ ^linux-charcoal($|[-.]) ]]; then
      charcoal_package_found=1
    fi
  done
  (( charcoal_package_found == 1 )) || \
    die "O ZIP não contém um pacote linux-charcoal válido."

  if ((${#stock_packages[@]} > 0)); then
    stock_list="$(IFS=', '; printf '%s' "${stock_packages[*]}")"
    ui_progress_update 68 "Removendo o kernel stock: $stock_list"
    pacman -R --noconfirm "${stock_packages[@]}"
    installed_packages="$(pacman_installed_packages)" || \
      die "Não foi possível consultar o banco do pacman após remover o kernel stock."
    mapfile -t remaining_stock < <(grep -E '^linux-neptune($|[-.])' <<< "$installed_packages" || true)
    ((${#remaining_stock[@]} == 0)) || die "Não foi possível remover completamente o kernel stock."
  fi

  command -v steamos-devmode >/dev/null 2>&1 && steamos-devmode enable --no-prompt || true
  ui_progress_update 80 "Instalando os pacotes do kernel Charcoal"
  pacman -U --noconfirm --needed "${packages[@]}"
  kernel_charcoal_installed || die "O kernel Charcoal não foi confirmado após a instalação."
  ui_progress_update 92 "Atualizando o bootloader e o initramfs"
  update_grub_runtime
  rm -rf -- "$tmp"
  KERNEL_TMP_DIR=""
  ui_progress_finish "Kernel Charcoal instalado com sucesso"
  restore_steamos_readonly
  ui_info "Kernel Charcoal instalado. Reinicie o sistema."
}

restore_stock_kernel() {
  require_root stock-kernel
  local stock_package charcoal_packages=() installed_stock=() installed_packages
  stock_package="$(kernel_stock_candidate)" || \
    die "Não foi possível localizar um pacote linux-neptune nos repositórios configurados."
  if ! ui_confirm "Remover o kernel Charcoal e reinstalar $stock_package?"; then
    cleanup_dry_run_sandbox
    return 0
  fi

  ui_progress_start "Restaurando o kernel padrão do SteamOS" 100
  ui_progress_update 8 "Preparando a restauração"
  if [[ "$DRY_RUN" == 1 ]]; then
    ui_progress_update 60 "Simulação: nenhum pacote será alterado"
    ui_progress_finish "Simulação da restauração concluída"
    restore_steamos_readonly
    return 0
  fi

  command -v pacman >/dev/null 2>&1 || die "pacman não encontrado."
  unlock_steamos
  trap restore_steamos_readonly EXIT
  command -v steamos-devmode >/dev/null 2>&1 && steamos-devmode enable --no-prompt || true
  installed_packages="$(pacman_installed_packages)" || \
    die "Não foi possível consultar os pacotes instalados antes de remover o kernel Charcoal."
  mapfile -t charcoal_packages < <(
    grep -E '^linux-charcoal($|[-.])' <<< "$installed_packages" || true
  )
  ui_progress_update 35 "Removendo os pacotes Charcoal"
  ((${#charcoal_packages[@]} == 0)) || pacman -Rs --noconfirm "${charcoal_packages[@]}"
  ui_progress_update 70 "Instalando $stock_package"
  pacman -S --noconfirm --needed "$stock_package"
  installed_packages="$(pacman_installed_packages)" || \
    die "Não foi possível consultar o banco do pacman após restaurar o kernel stock."
  mapfile -t installed_stock < <(grep -E '^linux-neptune($|[-.])' <<< "$installed_packages" || true)
  ((${#installed_stock[@]} > 0)) || die "O kernel stock não foi confirmado após a restauração."
  if grep -Eq '^linux-charcoal($|[-.])' <<< "$installed_packages"; then
    die "O kernel Charcoal ainda está instalado após a restauração."
  fi
  ui_progress_update 92 "Atualizando o bootloader e o initramfs"
  update_grub_runtime
  ui_progress_finish "Kernel padrão restaurado com sucesso"
  restore_steamos_readonly
  ui_info "Kernel padrão reinstalado. Reinicie o sistema."
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
