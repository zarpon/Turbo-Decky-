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

# Simula a instalação do kernel: o stock deve ser removido antes do pacote
# Charcoal e a checagem final deve confirmar o pacote customizado.
MOCK_BIN="$TMP/mock-bin"
mkdir -p "$MOCK_BIN"
PACMAN_STATE="$TMP/pacman.state"
PACMAN_LOG="$TMP/pacman.log"
DEVMODE_LOG="$TMP/devmode.log"
printf 'stock\n' > "$PACMAN_STATE"
cat > "$MOCK_BIN/pacman" <<'EOF_PACMAN'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  -Qq)
    state="$(cat "${PACMAN_STATE:?}")"
    [[ "$state" == stock ]] && printf 'linux-neptune-616\n'
    [[ "$state" == custom ]] && printf 'linux-charcoal-616\n'
    exit 0
    ;;
  -Qp)
    [[ "${PACMAN_INVALID:-0}" != 1 ]] || exit 1
    printf 'linux-charcoal-616\n'
    ;;
  -R)
    printf 'remove\n' >> "${PACMAN_LOG:?}"
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
    printf 'install\n' >> "${PACMAN_LOG:?}"
    printf 'custom\n' > "${PACMAN_STATE:?}"
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
  if [[ "$1" == -o ]]; then output="$2"; shift 2; continue; fi
  shift
done
if [[ "$output" == *.json ]]; then
  printf '{"assets":[{"name":"kernel.zip","browser_download_url":"https://example.invalid/kernel.zip"}]}\n' > "$output"
else
  /usr/bin/python3 - "$output" <<'PY_ZIP'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "w") as package_zip:
    package_zip.writestr("linux-charcoal-616.pkg.tar.zst", b"test package")
PY_ZIP
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
chmod +x "$MOCK_BIN/pacman" "$MOCK_BIN/curl" "$MOCK_BIN/unzip" "$MOCK_BIN/steamos-devmode"

kernel_output="$TMP/kernel.out"
PATH="$MOCK_BIN:$PATH" PACMAN_STATE="$PACMAN_STATE" PACMAN_LOG="$PACMAN_LOG" \
  DEVMODE_LOG="$DEVMODE_LOG" \
  TURBODECKY_ROOTFS= \
  TURBODECKY_DRY_RUN=0 TURBODECKY_PROGRESS_PROTOCOL=1 \
  TURBODECKY_KERNEL_STOCK_CONFIRMED=1 \
  bash -c 'source "$1"; require_root() { :; }; update_grub_runtime() { :; }; install_charcoal_kernel' _ "$SCRIPT" > "$kernel_output" 2> "$TMP/kernel.err"
grep -Fq $'TURBODECKY_PROGRESS\t68\tRemovendo o kernel stock: linux-neptune-616' "$kernel_output"
grep -Fqx 'remove' "$PACMAN_LOG"
grep -Fqx 'install' "$PACMAN_LOG"
[[ "$(sed -n '1p' "$PACMAN_LOG")" == remove ]]
[[ "$(sed -n '2p' "$PACMAN_LOG")" == install ]]
grep -Fqx 'enable --no-prompt' "$DEVMODE_LOG"

# A failed SteamOS developer-mode transition must stop before the destructive
# removal of the stock kernel.
printf 'stock\n' > "$PACMAN_STATE"
: > "$PACMAN_LOG"
if PATH="$MOCK_BIN:$PATH" PACMAN_STATE="$PACMAN_STATE" PACMAN_LOG="$PACMAN_LOG" \
  DEVMODE_LOG="$DEVMODE_LOG" DEVMODE_FAIL=1 TURBODECKY_ROOTFS= \
  TURBODECKY_DRY_RUN=0 TURBODECKY_PROGRESS_PROTOCOL=1 \
  TURBODECKY_KERNEL_STOCK_CONFIRMED=1 \
  bash -c 'source "$1"; require_root() { :; }; update_grub_runtime() { :; }; install_charcoal_kernel' _ "$SCRIPT" \
  > "$TMP/devmode-failure.out" 2> "$TMP/devmode-failure.err"; then
  printf 'falha do modo desenvolvedor foi ignorada\n' >&2
  exit 1
fi
grep -Fq 'modo desenvolvedor do SteamOS' "$TMP/devmode-failure.err"
! grep -Fq 'remove' "$PACMAN_LOG"

# A first installation must still display the dedicated confirmation even when
# no linux-neptune package appears in the pacman database.
confirmation_text_seen=""
ui_confirm_required() {
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

# A corrupt package must stop before the destructive removal transaction.
printf 'stock\n' > "$PACMAN_STATE"
: > "$PACMAN_LOG"
if PATH="$MOCK_BIN:$PATH" PACMAN_INVALID=1 \
  TURBODECKY_ROOTFS= \
  TURBODECKY_DRY_RUN=0 TURBODECKY_PROGRESS_PROTOCOL=1 \
  TURBODECKY_KERNEL_STOCK_CONFIRMED=1 \
  bash -c 'source "$1"; require_root() { :; }; update_grub_runtime() { :; }; install_charcoal_kernel' _ "$SCRIPT" \
  > "$TMP/invalid-kernel.out" 2> "$TMP/invalid-kernel.err"; then
  printf 'pacote inválido foi aceito\n' >&2
  exit 1
fi
! grep -Fq 'remove' "$PACMAN_LOG"

# Restoring the stock kernel must query the package database before removal and
# must choose the bootable package rather than its headers subpackage.
printf 'custom\n' > "$PACMAN_STATE"
: > "$PACMAN_LOG"
PATH="$MOCK_BIN:$PATH" PACMAN_STATE="$PACMAN_STATE" PACMAN_LOG="$PACMAN_LOG" \
  DEVMODE_LOG="$DEVMODE_LOG" \
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
grep -Fq 'pacman -R --noconfirm' "$REPO_ROOT/lib/20-actions.sh"

printf 'Turbo Decky progress and kernel-install validation passed\n'
