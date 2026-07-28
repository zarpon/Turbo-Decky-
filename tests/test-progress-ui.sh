#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT="${1:-./InstallTD.sh}"
REPO_ROOT="$(cd "$(dirname "$SCRIPT")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

ROOT="$TMP/root"
mkdir -p "$ROOT/etc/default" "$ROOT/etc/sysctl.d" "$ROOT/etc/tmpfiles.d" \
  "$ROOT/etc/systemd/zram-generator.conf.d" "$ROOT/etc/security/limits.d" \
  "$ROOT/etc/environment.d" "$ROOT/etc/udev/rules.d" "$ROOT/etc/systemd/system" \
  "$ROOT/var/lib/turbodecky/state" "$ROOT/home"
printf 'GRUB_CMDLINE_LINUX="quiet"\n' > "$ROOT/etc/default/grub"

export TURBODECKY_ROOTFS="$ROOT"
export TURBODECKY_DRY_RUN=1
export TURBODECKY_LIBRARY=1
export TURBODECKY_UI=terminal
export TURBODECKY_ASSUME_YES=1
# shellcheck source=/dev/null
source "$SCRIPT"

progress_output="$TMP/progress.out"
TURBODECKY_PROGRESS_PROTOCOL=1 bash -c 'source "$1"; apply_zram_profile' _ "$SCRIPT" \
  > "$progress_output" 2> "$TMP/progress.err"
grep -Fq $'TURBODECKY_PROGRESS\t0\tAplicando o perfil Charcoal com ZRAM' "$progress_output"
grep -Fq $'TURBODECKY_PROGRESS\t84\tAtivando a ZRAM' "$progress_output"
grep -Fq $'TURBODECKY_PROGRESS\t100\tPerfil ZRAM aplicado' "$progress_output"

terminal_output="$(bash -c 'source "$1"; ui_progress_start "Teste" 100; ui_progress_update 50 "Etapa intermediária"; ui_progress_finish "Concluído"' _ "$SCRIPT" 2>&1)"
grep -Fq '[ 50%] Etapa intermediária' <<< "$terminal_output"
grep -Fq '[100%] Concluído' <<< "$terminal_output"

# Package actions must also expose progress and must not invoke pacman during
# a dry-run, even when a test root is supplied explicitly.
old_progress_protocol="$PROGRESS_PROTOCOL"
PROGRESS_PROTOCOL=1
lavd_output="$(setup_lavd 2> "$TMP/lavd.err")"
PROGRESS_PROTOCOL="$old_progress_protocol"
grep -Fq $'TURBODECKY_PROGRESS\t100\tSimulação do SCX LAVD concluída' <<< "$lavd_output"

# Simulate an installation with both the bootable stock package and its headers.
# pacman -U must install/replace the bootable kernel first. Only after Charcoal
# is visible may the installer remove a Neptune headers residue.
MOCK_BIN="$TMP/mock-bin"
mkdir -p "$MOCK_BIN"
PACMAN_STATE="$TMP/pacman.state"
PACMAN_LOG="$TMP/pacman.log"
DEVMODE_LOG="$TMP/devmode.log"
STEAM_READONLY_LOG="$TMP/steamos-readonly.log"
printf 'stock\n' > "$PACMAN_STATE"
cat > "$MOCK_BIN/pacman" <<'EOF_PACMAN'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  -Qq)
    state="$(cat "${PACMAN_STATE:?}")"
    case "$state" in
      stock)
        printf 'linux-neptune-616\nlinux-neptune-616-headers\n'
        ;;
      custom-with-stock-headers)
        printf 'linux-charcoal-616\nlinux-neptune-616-headers\n'
        ;;
      custom)
        printf 'linux-charcoal-616\n'
        ;;
    esac
    exit 0
    ;;
  -Qp)
    [[ "${PACMAN_INVALID:-0}" != 1 ]] || exit 1
    printf 'linux-charcoal-616\n'
    ;;
  -R)
    printf 'remove-stock-residue\n' >> "${PACMAN_LOG:?}"
    printf 'custom\n' > "${PACMAN_STATE:?}"
    ;;
  -Rs)
    printf 'remove-charcoal\n' >> "${PACMAN_LOG:?}"
    printf 'none\n' > "${PACMAN_STATE:?}"
    ;;
  -Ssq)
    printf 'linux-neptune-616\nlinux-neptune-616-headers\n'
    ;;
  -S)
    printf 'install-stock\n' >> "${PACMAN_LOG:?}"
    printf 'stock\n' > "${PACMAN_STATE:?}"
    ;;
  -U)
    [[ "${PACMAN_INSTALL_FAIL:-0}" != 1 ]] || exit 1
    printf 'install-charcoal\n' >> "${PACMAN_LOG:?}"
    printf 'custom-with-stock-headers\n' > "${PACMAN_STATE:?}"
    ;;
  *)
    printf '%s\n' "$*" >> "${PACMAN_LOG:?}"
    ;;
esac
EOF_PACMAN
cat > "$MOCK_BIN/curl" <<'EOF_CURL'
#!/usr/bin/env bash
set -Eeuo pipefail
output=""
while (($#)); do
  if [[ "$1" == -o || "$1" == --output ]]; then output="$2"; shift 2; continue; fi
  shift
done
if [[ "$output" == *.json ]]; then
  printf '%s\n' '{"tag_name":"v-test","draft":false,"prerelease":false,"assets":[{"name":"linux-charcoal-test.zip","browser_download_url":"https://github.com/zarpon/linux-charcoal-vulcano/releases/download/v-test/linux-charcoal-test.zip"},{"name":"RELEASE-ZIP-SHA256SUM","browser_download_url":"https://github.com/zarpon/linux-charcoal-vulcano/releases/download/v-test/RELEASE-ZIP-SHA256SUM"}]}' > "$output"
elif [[ "$(basename "$output")" == RELEASE-ZIP-SHA256SUM ]]; then
  sha256sum "$(cat "$TMP_CHARCOAL_ARCHIVE")" | \
    awk '{print $1 "  linux-charcoal-test.zip"}' > "$output"
else
  /usr/bin/python3 - "$output" <<'PY_ZIP'
import hashlib
import zipfile
import sys

packages = {
    "linux-charcoal-616.pkg.tar.zst": b"test kernel package",
    "linux-charcoal-616-headers-1.pkg.tar.zst": b"test headers package",
}
manifest = "\n".join(
    f"{hashlib.sha256(data).hexdigest()}  {name}"
    for name, data in packages.items()
)
with zipfile.ZipFile(sys.argv[1], "w") as package_zip:
    package_zip.writestr("SHA256SUMS", manifest + "\n")
    for name, data in packages.items():
        package_zip.writestr(name, data)
PY_ZIP
  printf '%s\n' "$output" > "$TMP_CHARCOAL_ARCHIVE"
fi
EOF_CURL
cat > "$MOCK_BIN/unzip" <<'EOF_UNZIP'
#!/usr/bin/env bash
printf 'unzip should not be called\n' >&2
exit 127
EOF_UNZIP
cat > "$MOCK_BIN/steamos-devmode" <<'EOF_DEVMODE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DEVMODE_LOG:?}"
if [[ "${DEVMODE_FAIL:-0}" == 1 ]]; then
  exit 1
fi
exit 0
EOF_DEVMODE
cat > "$MOCK_BIN/steamos-readonly" <<'EOF_READONLY'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  status) printf 'enabled\n' ;;
  disable) printf 'disable\n' >> "${STEAM_READONLY_LOG:?}" ;;
  enable) printf 'enable\n' >> "${STEAM_READONLY_LOG:?}" ;;
  *) exit 1 ;;
esac
EOF_READONLY
chmod +x "$MOCK_BIN/pacman" "$MOCK_BIN/curl" "$MOCK_BIN/unzip" \
  "$MOCK_BIN/steamos-devmode" "$MOCK_BIN/steamos-readonly"

kernel_output="$TMP/kernel.out"
PATH="$MOCK_BIN:$PATH" PACMAN_STATE="$PACMAN_STATE" PACMAN_LOG="$PACMAN_LOG" \
  DEVMODE_LOG="$DEVMODE_LOG" STEAM_READONLY_LOG="$STEAM_READONLY_LOG" \
  TMP_CHARCOAL_ARCHIVE="$TMP/charcoal-archive.path" \
  TURBODECKY_ROOTFS= \
  TURBODECKY_DRY_RUN=0 TURBODECKY_PROGRESS_PROTOCOL=1 \
  TURBODECKY_KERNEL_STOCK_CONFIRMED=1 \
  bash -c 'source "$1"; require_root() { :; }; update_grub_runtime() { :; }; install_charcoal_kernel' _ "$SCRIPT" > "$kernel_output" 2> "$TMP/kernel.err"
grep -Fq $'TURBODECKY_PROGRESS\t72\tInstalando o Charcoal e substituindo o kernel stock' "$kernel_output"
grep -Fq $'TURBODECKY_PROGRESS\t86\tRemovendo pacotes stock remanescentes: linux-neptune-616-headers' "$kernel_output"
grep -Fqx 'install-charcoal' "$PACMAN_LOG"
grep -Fqx 'remove-stock-residue' "$PACMAN_LOG"
[[ "$(sed -n '1p' "$PACMAN_LOG")" == install-charcoal ]]
[[ "$(sed -n '2p' "$PACMAN_LOG")" == remove-stock-residue ]]
[[ "$(cat "$PACMAN_STATE")" == custom ]]
grep -Fqx 'enable --no-prompt' "$DEVMODE_LOG"

# A failed SteamOS developer-mode transition must stop before any package
# transaction and leave the stock kernel untouched.
printf 'stock\n' > "$PACMAN_STATE"
: > "$PACMAN_LOG"
if PATH="$MOCK_BIN:$PATH" PACMAN_STATE="$PACMAN_STATE" PACMAN_LOG="$PACMAN_LOG" \
  DEVMODE_LOG="$DEVMODE_LOG" STEAM_READONLY_LOG="$STEAM_READONLY_LOG" \
  TMP_CHARCOAL_ARCHIVE="$TMP/charcoal-archive.path" \
  DEVMODE_FAIL=1 TURBODECKY_ROOTFS= \
  TURBODECKY_DRY_RUN=0 TURBODECKY_PROGRESS_PROTOCOL=1 \
  TURBODECKY_KERNEL_STOCK_CONFIRMED=1 \
  bash -c 'source "$1"; require_root() { :; }; update_grub_runtime() { :; }; install_charcoal_kernel' _ "$SCRIPT" \
  > "$TMP/devmode-failure.out" 2> "$TMP/devmode-failure.err"; then
  printf 'falha do modo desenvolvedor foi ignorada\n' >&2
  exit 1
fi
grep -Fq 'modo desenvolvedor do SteamOS' "$TMP/devmode-failure.err"
[[ ! -s "$PACMAN_LOG" ]]
[[ "$(cat "$PACMAN_STATE")" == stock ]]

# A failed pacman -U transaction must not pre-remove linux-neptune. This is the
# regression that broke real installations in the previous two-step flow.
printf 'stock\n' > "$PACMAN_STATE"
: > "$PACMAN_LOG"
if PATH="$MOCK_BIN:$PATH" PACMAN_STATE="$PACMAN_STATE" PACMAN_LOG="$PACMAN_LOG" \
  DEVMODE_LOG="$DEVMODE_LOG" STEAM_READONLY_LOG="$STEAM_READONLY_LOG" \
  TMP_CHARCOAL_ARCHIVE="$TMP/charcoal-archive.path" \
  PACMAN_INSTALL_FAIL=1 TURBODECKY_ROOTFS= \
  TURBODECKY_DRY_RUN=0 TURBODECKY_PROGRESS_PROTOCOL=1 \
  TURBODECKY_KERNEL_STOCK_CONFIRMED=1 \
  bash -c 'source "$1"; require_root() { :; }; update_grub_runtime() { :; }; install_charcoal_kernel' _ "$SCRIPT" \
  > "$TMP/pacman-failure.out" 2> "$TMP/pacman-failure.err"; then
  printf 'falha do pacman -U foi ignorada\n' >&2
  exit 1
fi
grep -Fq 'não conseguiu instalar o kernel Charcoal' "$TMP/pacman-failure.err"
[[ ! -s "$PACMAN_LOG" ]]
[[ "$(cat "$PACMAN_STATE")" == stock ]]

# A first installation must still display the dedicated confirmation even when
# no linux-neptune package appears in the pacman database.
if ui_confirm_exact_s 'Digite s para validar a remoção' <<< 'S'; then
  printf 'a confirmação aceitou S maiúsculo\n' >&2
  exit 1
fi
ui_confirm_exact_s 'Digite s para validar a remoção' <<< 's'
confirmation_text_seen=""
ui_confirm_exact_s() {
  confirmation_text_seen="$*"
  return 1
}
PATH="$MOCK_BIN:$PATH"
export PATH PACMAN_STATE PACMAN_LOG
printf 'none\n' > "$PACMAN_STATE"
TURBODECKY_ASSUME_YES=0
TURBODECKY_KERNEL_STOCK_CONFIRMED=0
install_charcoal_kernel
grep -Fq 'primeira instalação do kernel Charcoal' <<< "$confirmation_text_seen"

# A corrupt package must stop before any package transaction.
printf 'stock\n' > "$PACMAN_STATE"
: > "$PACMAN_LOG"
if PATH="$MOCK_BIN:$PATH" PACMAN_INVALID=1 \
  STEAM_READONLY_LOG="$STEAM_READONLY_LOG" TMP_CHARCOAL_ARCHIVE="$TMP/charcoal-archive.path" \
  TURBODECKY_ROOTFS= \
  TURBODECKY_DRY_RUN=0 TURBODECKY_PROGRESS_PROTOCOL=1 \
  TURBODECKY_KERNEL_STOCK_CONFIRMED=1 \
  bash -c 'source "$1"; require_root() { :; }; update_grub_runtime() { :; }; install_charcoal_kernel' _ "$SCRIPT" \
  > "$TMP/invalid-kernel.out" 2> "$TMP/invalid-kernel.err"; then
  printf 'pacote inválido foi aceito\n' >&2
  exit 1
fi
[[ ! -s "$PACMAN_LOG" ]]
[[ "$(cat "$PACMAN_STATE")" == stock ]]

# Restoring the stock kernel must query the package database before removal and
# must choose the bootable package rather than its headers subpackage.
printf 'custom\n' > "$PACMAN_STATE"
: > "$PACMAN_LOG"
PATH="$MOCK_BIN:$PATH" PACMAN_STATE="$PACMAN_STATE" PACMAN_LOG="$PACMAN_LOG" \
  DEVMODE_LOG="$DEVMODE_LOG" STEAM_READONLY_LOG="$STEAM_READONLY_LOG" \
  TURBODECKY_ROOTFS= \
  TURBODECKY_DRY_RUN=0 TURBODECKY_ASSUME_YES=1 \
  TURBODECKY_PROGRESS_PROTOCOL=1 \
  bash -c 'source "$1"; require_root() { :; }; update_grub_runtime() { :; }; restore_stock_kernel' _ "$SCRIPT" \
  > "$TMP/restore-kernel.out" 2> "$TMP/restore-kernel.err"
grep -Fq $'TURBODECKY_PROGRESS\t70\tInstalando linux-neptune-616' \
  "$TMP/restore-kernel.out"
grep -Fqx 'remove-charcoal' "$PACMAN_LOG"
grep -Fqx 'install-stock' "$PACMAN_LOG"
[[ "$(cat "$PACMAN_STATE")" == stock ]]

grep -Fq 'ui_progress_start' "$REPO_ROOT/lib/70-zswap-runtime-guard.sh"
grep -Fq 'TURBODECKY_PROGRESS_PROTOCOL=1' "$REPO_ROOT/packaging/appimage/turbodecky"
grep -Fq 'pacman -U --noconfirm' "$REPO_ROOT/lib/25-kernel-install-atomic.sh"
grep -Fq 'substituindo o kernel stock' "$REPO_ROOT/lib/25-kernel-install-atomic.sh"
grep -Fq 'zarpon/linux-charcoal-vulcano' "$REPO_ROOT/lib/20-actions.sh"
grep -Fq 'RELEASE-ZIP-SHA256SUM' "$REPO_ROOT/lib/20-actions.sh"
grep -Fqx 'disable' "$STEAM_READONLY_LOG"

printf 'Turbo Decky progress and atomic kernel-install validation passed\n'
