#!/usr/bin/env bash

# Loaded after lib/20-actions.sh. Keep the release validation helpers from that
# module, but replace its destructive two-step kernel transaction. The Charcoal
# package declares replaces/conflicts for linux-neptune-616, so pacman must
# install it first and perform the bootable-kernel replacement atomically.
install_charcoal_kernel() {
  require_root kernel
  local stock_packages=() stock_list remaining_stock=() installed_packages
  local tmp metadata json release_tag archive_name archive_url checksum_name checksum_url
  local archive_path checksum_path package_dir package package_name charcoal_package_found=0
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
  mapfile -t stock_packages < <(
    grep -E '^linux-neptune($|[-.])' <<< "$installed_packages" || true
  )

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

  for command in pacman curl python3 mktemp steamos-readonly steamos-devmode; do
    command -v "$command" >/dev/null 2>&1 || \
      die "Comando obrigatório ausente: $command"
  done

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/turbodecky-charcoal.XXXXXX")"
  KERNEL_TMP_DIR="$tmp"
  trap 'rm -rf -- "${KERNEL_TMP_DIR:-}"; KERNEL_TMP_DIR=""; restore_steamos_readonly' EXIT
  json="$tmp/release.json"

  ui_progress_update 22 "Consultando a última release"
  curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --proto '=https' \
    --proto-redir '=https' \
    --retry 3 \
    --connect-timeout 15 \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    --user-agent "$CHARCOAL_KERNEL_USER_AGENT" \
    --output "$json" \
    "$CHARCOAL_KERNEL_RELEASE_API" || \
      die "Não foi possível consultar a última release Charcoal."

  metadata="$(parse_charcoal_release_metadata "$json")" || \
    die "Não foi possível identificar os assets exigidos na última release Charcoal."
  local -a fields
  mapfile -t fields <<< "$metadata"
  (( ${#fields[@]} == 5 )) || die "Metadados incompletos da release Charcoal."

  release_tag=${fields[0]}
  archive_name=${fields[1]}
  archive_url=${fields[2]}
  checksum_name=${fields[3]}
  checksum_url=${fields[4]}
  archive_path="$tmp/$archive_name"
  checksum_path="$tmp/$checksum_name"
  package_dir="$tmp/packages"

  ui_progress_update 32 "Baixando a release $release_tag"
  download_charcoal_file "$archive_url" "$archive_path" || \
    die "Não foi possível baixar o ZIP da release Charcoal."
  download_charcoal_file "$checksum_url" "$checksum_path" || \
    die "Não foi possível baixar o checksum do ZIP Charcoal."

  ui_progress_update 44 "Verificando o SHA-256 do ZIP da release"
  verify_charcoal_release_archive "$archive_path" "$checksum_path" "$archive_name" || \
    die "A verificação SHA-256 do ZIP Charcoal falhou."

  ui_progress_update 54 "Extraindo e verificando os pacotes Charcoal"
  extract_and_verify_charcoal_packages "$archive_path" "$package_dir" || \
    die "Não foi possível validar os pacotes da release Charcoal."

  mapfile -d '' -t packages < <(
    find "$package_dir" -maxdepth 1 -type f -name 'linux-charcoal-*.pkg.tar.zst' \
      -print0 | sort -z
  )
  (( ${#packages[@]} >= 2 )) || \
    die "A release verificada não contém os pacotes esperados do kernel e headers."

  ui_progress_update 64 "Validando cada pacote antes da transação"
  for package in "${packages[@]}"; do
    package_name="$(kernel_package_names "$package")" || \
      die "Pacote inválido ou ilegível: $(basename "$package")"
    if [[ "$package_name" =~ ^linux-charcoal($|[-.]) ]]; then
      charcoal_package_found=1
    fi
  done
  (( charcoal_package_found == 1 )) || \
    die "O ZIP não contém um pacote linux-charcoal válido."

  ui_progress_update 66 "Preparando a transação do pacman"
  unlock_steamos
  enable_steamos_devmode

  # Do not uninstall the bootable stock kernel first. pacman consumes the
  # Charcoal package's replaces/conflicts metadata and swaps the base kernel in
  # the same successful transaction. The explicit lowercase-s confirmation in
  # the UI authorizes this non-interactive replacement.
  ui_progress_update 72 "Instalando o Charcoal e substituindo o kernel stock"
  pacman -U --noconfirm "${packages[@]}" || \
    die "A transação do pacman não conseguiu instalar o kernel Charcoal."
  kernel_charcoal_installed || \
    die "O kernel Charcoal não foi confirmado após a instalação."

  # Header or auxiliary Neptune packages may not be covered by the base
  # package's replaces metadata. Remove them only after a bootable Charcoal
  # kernel has been confirmed, then validate the final package state.
  installed_packages="$(pacman_installed_packages)" || \
    die "Não foi possível consultar o banco do pacman após instalar o Charcoal."
  mapfile -t remaining_stock < <(
    grep -E '^linux-neptune($|[-.])' <<< "$installed_packages" || true
  )
  if ((${#remaining_stock[@]} > 0)); then
    stock_list="$(IFS=', '; printf '%s' "${remaining_stock[*]}")"
    ui_progress_update 86 "Removendo pacotes stock remanescentes: $stock_list"
    pacman -R --noconfirm "${remaining_stock[@]}" || \
      die "O Charcoal foi instalado, mas os pacotes stock remanescentes não puderam ser removidos."
  fi

  installed_packages="$(pacman_installed_packages)" || \
    die "Não foi possível validar o estado final dos kernels instalados."
  kernel_charcoal_installed || \
    die "O kernel Charcoal deixou de estar instalado durante a limpeza final."
  if grep -Eq '^linux-neptune($|[-.])' <<< "$installed_packages"; then
    die "Ainda existem pacotes do kernel stock após a instalação do Charcoal."
  fi

  ui_progress_update 92 "Atualizando o bootloader e o initramfs"
  update_grub_runtime
  rm -rf -- "$tmp"
  KERNEL_TMP_DIR=""
  ui_progress_finish "Kernel Charcoal instalado com sucesso"
  restore_steamos_readonly
  ui_info "Kernel Charcoal instalado. Reinicie o sistema."
}
