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

readonly CHARCOAL_KERNEL_REPOSITORY="zarpon/linux-charcoal-vulcano"
readonly CHARCOAL_KERNEL_RELEASE_API="https://api.github.com/repos/${CHARCOAL_KERNEL_REPOSITORY}/releases/latest"
readonly CHARCOAL_KERNEL_RELEASE_DOWNLOAD_PREFIX="https://github.com/${CHARCOAL_KERNEL_REPOSITORY}/releases/download/"
readonly CHARCOAL_KERNEL_USER_AGENT="charcoal-kernel-installer"

download_charcoal_file() {
  local url=$1
  local destination=$2

  curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --proto '=https' \
    --proto-redir '=https' \
    --retry 3 \
    --connect-timeout 15 \
    --output "$destination" \
    "$url"
}

parse_charcoal_release_metadata() {
  local release_json=$1

  python3 - "$release_json" "$CHARCOAL_KERNEL_REPOSITORY" \
    "$CHARCOAL_KERNEL_RELEASE_DOWNLOAD_PREFIX" <<'PY'
import json
import sys
from pathlib import PurePosixPath

release_json, repository, download_prefix = sys.argv[1:]

try:
    with open(release_json, encoding="utf-8") as handle:
        release = json.load(handle)
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"Não foi possível interpretar a resposta da release: {exc}")

if not isinstance(release, dict) or release.get("draft") or release.get("prerelease"):
    raise SystemExit("O GitHub não retornou uma release estável publicada")

def text(value, label):
    if not isinstance(value, str) or not value or any(char in value for char in "\x00\r\n"):
        raise SystemExit(f"Campo inválido na resposta da release: {label}")
    return value

def asset_url(asset, expected_name):
    name = text(asset.get("name"), "nome do asset")
    url = text(asset.get("browser_download_url"), "URL do asset")
    if name != expected_name:
        raise SystemExit(f"Nome de asset inesperado: {name}")
    if not url.startswith(download_prefix):
        raise SystemExit(f"Asset fora das releases de {repository}: {url}")
    return name, url

tag_name = text(release.get("tag_name"), "tag da release")
assets = release.get("assets")
if not isinstance(assets, list):
    raise SystemExit("A release do GitHub não possui assets")

archives = [
    asset for asset in assets
    if isinstance(asset, dict)
    and str(asset.get("name", "")).startswith("linux-charcoal-")
    and str(asset.get("name", "")).endswith(".zip")
]
checksums = [
    asset for asset in assets
    if isinstance(asset, dict) and asset.get("name") == "RELEASE-ZIP-SHA256SUM"
]

if len(archives) != 1:
    raise SystemExit("Era esperado exatamente um ZIP da release linux-charcoal")
if len(checksums) != 1:
    raise SystemExit("Era esperado exatamente um asset RELEASE-ZIP-SHA256SUM")

archive_name, archive_url = asset_url(
    archives[0], text(archives[0].get("name"), "nome do arquivo")
)
checksum_name, checksum_url = asset_url(checksums[0], "RELEASE-ZIP-SHA256SUM")

if PurePosixPath(archive_name).name != archive_name:
    raise SystemExit("Nome de ZIP inválido")

print(tag_name)
print(archive_name)
print(archive_url)
print(checksum_name)
print(checksum_url)
PY
}

verify_charcoal_release_archive() {
  local archive=$1
  local checksum_file=$2
  local archive_name=$3

  python3 - "$archive" "$checksum_file" "$archive_name" <<'PY'
import hashlib
import re
import sys

archive, checksum_file, archive_name = sys.argv[1:]

try:
    lines = open(checksum_file, encoding="utf-8").read().splitlines()
except OSError as exc:
    raise SystemExit(f"Não foi possível ler o checksum da release: {exc}")

entries = []
for line in lines:
    match = re.fullmatch(r"([0-9a-fA-F]{64}) [ *](.+)", line)
    if not match:
        raise SystemExit("Formato inválido de RELEASE-ZIP-SHA256SUM")
    entries.append((match.group(1).lower(), match.group(2)))

if len(entries) != 1 or entries[0][1] != archive_name:
    raise SystemExit("O checksum não corresponde ao ZIP selecionado")

digest = hashlib.sha256()
with open(archive, "rb") as handle:
    for block in iter(lambda: handle.read(1024 * 1024), b""):
        digest.update(block)

if digest.hexdigest() != entries[0][0]:
    raise SystemExit("Falha na verificação SHA-256 do ZIP da release")
PY
}

extract_and_verify_charcoal_packages() {
  local archive=$1
  local destination=$2

  python3 - "$archive" "$destination" <<'PY'
import hashlib
import re
import stat
import sys
import zipfile
from pathlib import Path, PurePosixPath

archive, destination = map(Path, sys.argv[1:])
package_pattern = re.compile(r"^linux-charcoal-[^/\\\x00\r\n]+\.pkg\.tar\.zst$")
checksum_pattern = re.compile(
    r"([0-9a-fA-F]{64}) [ *](linux-charcoal-[^/\\\x00\r\n]+\.pkg\.tar\.zst)"
)

try:
    with zipfile.ZipFile(archive) as handle:
        infos = handle.infolist()
        names = [info.filename for info in infos]
        if len(names) != len(set(names)):
            raise ValueError("a release contém entradas ZIP duplicadas")

        if "SHA256SUMS" not in names:
            raise ValueError("a release não contém SHA256SUMS")

        package_infos = [info for info in infos if package_pattern.fullmatch(info.filename)]
        package_names = {info.filename for info in package_infos}
        if not package_infos:
            raise ValueError("a release não contém pacotes Charcoal")
        if not any("-headers-" not in name for name in package_names):
            raise ValueError("a release não contém o pacote do kernel")
        if not any("-headers-" in name for name in package_names):
            raise ValueError("a release não contém o pacote de headers")

        for info in [next(info for info in infos if info.filename == "SHA256SUMS"), *package_infos]:
            if PurePosixPath(info.filename).name != info.filename:
                raise ValueError(f"caminho inseguro na release: {info.filename}")
            if stat.S_ISLNK(info.external_attr >> 16):
                raise ValueError(f"link simbólico na release: {info.filename}")

        manifest = handle.read("SHA256SUMS").decode("utf-8")
        checksums = {}
        for line in manifest.splitlines():
            match = checksum_pattern.fullmatch(line)
            if not match:
                raise ValueError("formato inválido de SHA256SUMS")
            digest, name = match.groups()
            if name in checksums:
                raise ValueError(f"checksum duplicado: {name}")
            checksums[name] = digest.lower()

        if set(checksums) != package_names:
            raise ValueError("a lista de pacotes não corresponde a SHA256SUMS")

        destination.mkdir(mode=0o700)
        (destination / "SHA256SUMS").write_text(manifest, encoding="utf-8")

        for info in package_infos:
            package_target = destination / info.filename
            digest = hashlib.sha256()
            with handle.open(info) as source, package_target.open("xb") as target:
                for block in iter(lambda: source.read(1024 * 1024), b""):
                    digest.update(block)
                    target.write(block)
            if digest.hexdigest() != checksums[info.filename]:
                package_target.unlink(missing_ok=True)
                raise ValueError(f"falha no SHA-256 do pacote: {info.filename}")
except (OSError, ValueError, zipfile.BadZipFile, UnicodeDecodeError) as exc:
    raise SystemExit(f"Não foi possível validar os pacotes da release: {exc}")
PY
}

kernel_install_confirmation() {
  local stock_packages=("$@") stock_list charcoal_present=0
  kernel_charcoal_installed && charcoal_present=1 || true
  stock_list="$(IFS=', '; printf '%s' "${stock_packages[*]}")"

  if (( ! charcoal_present )); then
    if ((${#stock_packages[@]} > 0)); then
      ui_confirm_exact_s "ATENÇÃO: esta é a primeira instalação do kernel Charcoal. Para evitar falha, o kernel stock ($stock_list) será removido obrigatoriamente antes da instalação."
    else
      ui_confirm_exact_s "Esta é a primeira instalação do kernel Charcoal. Nenhum kernel stock foi detectado no pacman; se existir um pacote fora do banco, ele deverá ser removido para evitar conflito."
    fi
  elif ((${#stock_packages[@]} > 0)); then
    ui_confirm_exact_s "ATENÇÃO: o kernel stock ($stock_list) ainda está instalado. Ele será removido obrigatoriamente antes de atualizar o kernel Charcoal; mantê-lo pode causar falha."
  else
    ui_confirm "Instalar os pacotes da última release de zarpon/linux-charcoal-vulcano?"
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

enable_steamos_devmode() {
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0
  if command -v steamos-devmode >/dev/null 2>&1; then
    steamos-devmode enable --no-prompt || \
      die "Não foi possível habilitar o modo desenvolvedor do SteamOS."
  fi
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

  for command in pacman curl python3 mktemp steamos-readonly steamos-devmode; do
    command -v "$command" >/dev/null 2>&1 || die "Comando obrigatório ausente: $command"
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
    "$CHARCOAL_KERNEL_RELEASE_API" || die "Não foi possível consultar a última release Charcoal."

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

  ui_progress_update 66 "Preparando a transação do pacman"
  unlock_steamos
  enable_steamos_devmode

  if ((${#stock_packages[@]} > 0)); then
    stock_list="$(IFS=', '; printf '%s' "${stock_packages[*]}")"
    ui_progress_update 68 "Removendo o kernel stock: $stock_list"
    pacman -R --noconfirm "${stock_packages[@]}"
    installed_packages="$(pacman_installed_packages)" || \
      die "Não foi possível consultar o banco do pacman após remover o kernel stock."
    mapfile -t remaining_stock < <(grep -E '^linux-neptune($|[-.])' <<< "$installed_packages" || true)
    ((${#remaining_stock[@]} == 0)) || die "Não foi possível remover completamente o kernel stock."
  fi

  ui_progress_update 80 "Instalando os pacotes do kernel Charcoal"
  # The explicit Turbo Decky confirmation above replaces pacman's interactive
  # stock-kernel prompt. Keep the transaction non-interactive so the AppImage
  # cannot block behind a package-manager question after authentication.
  pacman -U --noconfirm "${packages[@]}"
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
  enable_steamos_devmode
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
