#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT="${1:-./InstallTD.sh}"
REPO_ROOT="$(cd "$(dirname "$SCRIPT")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
ROOT="$TMP/root"

mkdir -p \
  "$ROOT/etc/default" \
  "$ROOT/etc/sysctl.d" \
  "$ROOT/etc/tmpfiles.d" \
  "$ROOT/etc/systemd/zram-generator.conf.d" \
  "$ROOT/etc/security/limits.d" \
  "$ROOT/etc/environment.d" \
  "$ROOT/etc/udev/rules.d" \
  "$ROOT/etc/systemd/system" \
  "$ROOT/usr/local/bin" \
  "$ROOT/var/lib/turbodecky/state" \
  "$ROOT/var/log" \
  "$ROOT/home"

printf 'GRUB_CMDLINE_LINUX="quiet splash"\n' > "$ROOT/etc/default/grub"
printf '# baseline fstab\n' > "$ROOT/etc/fstab"
printf 'baseline=1\n' > "$ROOT/etc/sysctl.d/99-turbodecky.conf"

export TURBODECKY_ROOTFS="$ROOT"
export TURBODECKY_DRY_RUN=1
export TURBODECKY_LIBRARY=1
export TURBODECKY_UI=terminal
export TURBODECKY_ASSUME_YES=1
# shellcheck source=/dev/null
source "$SCRIPT"

# ZRAM: tudo que precisa sobreviver ao reboot deve estar em configuração
# persistente, e o GRUB deve impedir que o ZSWAP volte no próximo boot.
apply_zram_profile

for file in \
  "$SYSCTL_FILE" \
  "$MEMORY_FILE" \
  "$LIMITS_FILE" \
  "$ENV_FILE" \
  "$UDEV_FILE" \
  "$ZRAM_FILE"; do
  [[ -s "$file" ]] || { printf 'arquivo persistente ausente: %s\n' "$file" >&2; exit 1; }
done

grep -Fqx 'zswap.enabled=0' <(tr ' ' '\n' < "$GRUB_FILE")
grep -Fqx 'compression-algorithm = lz4 zstd' "$ZRAM_FILE"
grep -Fqx 'w! /sys/kernel/mm/transparent_hugepage/enabled - - - - madvise' "$MEMORY_FILE"
grep -Fqx 'w! /sys/kernel/mm/transparent_hugepage/defrag - - - - defer' "$MEMORY_FILE"
grep -Fqx 'w! /sys/kernel/mm/lru_gen/enabled - - - - 7' "$MEMORY_FILE"
grep -Fqx 'zram' "$PROFILE_STATE"
! grep -RniE 'OnUnitActiveSec=|OnCalendar=|recomp_algorithm|recompress=' \
  "$SYSCTL_FILE" "$MEMORY_FILE" "$ZRAM_FILE"

# ZSWAP: parâmetros de boot ficam no GRUB, o ZRAM gerenciado é removido e um
# backing swap persistente é preparado. No sistema real, a entrada é gravada
# no fstab; a âncora é conferida abaixo porque o root isolado não executa swap.
apply_zswap_profile

[[ ! -e "$ZRAM_FILE" ]]
[[ -e "$SWAPFILE" ]]
grep -Fqx 'zswap' "$PROFILE_STATE"
for token in \
  zswap.enabled=1 \
  zswap.compressor=lz4 \
  zswap.max_pool_percent=35 \
  zswap.zpool=zsmalloc \
  zswap.shrinker_enabled=1; do
  grep -Fqx "$token" <(tr ' ' '\n' < "$GRUB_FILE")
done

# Âncoras de persistência executadas no sistema real.
grep -Fq 'systemctl mask --now systemd-zram-setup@zram0.service' \
  "$REPO_ROOT/lib/50-memory-mode-safety.sh"
grep -Fq 'systemctl enable --now fstrim.timer' "$REPO_ROOT/lib/10-profiles.sh"
grep -Fq 'systemctl enable --now scx_lavd.service' "$REPO_ROOT/lib/20-actions.sh"
grep -Fq "printf '%s none swap sw,pri=-2 0 0" "$REPO_ROOT/lib/30-hardening.sh"
grep -Fq 'steamos-update-grub' "$REPO_ROOT/lib/10-profiles.sh"
grep -Fq 'mkinitcpio -P' "$REPO_ROOT/lib/10-profiles.sh"
grep -Fq '/etc/systemd/zram-generator.conf.d/00-turbodecky.conf' "$REPO_ROOT/lib/00-core.sh"
grep -Fq '/etc/tmpfiles.d/99-turbodecky-memory.conf' "$REPO_ROOT/lib/00-core.sh"
grep -Fq '/etc/sysctl.d/99-turbodecky.conf' "$REPO_ROOT/lib/00-core.sh"

# A reversão deve remover os artefatos gerenciados e restaurar o baseline.
revert_all

grep -Fqx 'GRUB_CMDLINE_LINUX="quiet splash"' "$GRUB_FILE"
grep -Fqx 'baseline=1' "$SYSCTL_FILE"
for generated in "$MEMORY_FILE" "$LIMITS_FILE" "$ENV_FILE" "$UDEV_FILE" "$ZRAM_FILE"; do
  [[ ! -e "$generated" ]] || { printf 'resíduo após reversão: %s\n' "$generated" >&2; exit 1; }
done
[[ ! -e "$SWAPFILE" ]]
[[ ! -e "$STATE_DIR" ]]

printf 'Turbo Decky reboot persistence validation passed\n'
