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

[[ ! -e "$REPO_ROOT/lib/25-kernel-install-atomic.sh" ]]
! declare -F install_charcoal_kernel >/dev/null
! declare -F restore_stock_kernel >/dev/null
! grep -RniE 'install_charcoal_kernel|restore_stock_kernel|--install-kernel|--restore-kernel' \
  "$REPO_ROOT/InstallTD.sh" "$REPO_ROOT/lib" "$REPO_ROOT/packaging/appimage" >/dev/null

if TURBODECKY_LIBRARY=0 TURBODECKY_ROOTFS="$ROOT" TURBODECKY_DRY_RUN=1 \
  bash "$SCRIPT" --install-kernel > "$TMP/kernel.out" 2> "$TMP/kernel.err"; then
  printf 'a ação removida --install-kernel ainda foi aceita\n' >&2
  exit 1
fi

printf 'Turbo Decky progress UI validation passed\n'
