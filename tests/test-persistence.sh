#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT="${1:-./InstallTD.sh}"
REPO_ROOT="$(cd "$(dirname "$SCRIPT")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
ROOT="$TMP/root"
readonly EXPECTED_SWAP_BYTES=$((8 * 1024 * 1024 * 1024))

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

assert_swapfile_8g() {
  [[ -f "$SWAPFILE" ]]
  [[ "$(stat -Lc '%s' "$SWAPFILE")" == "$EXPECTED_SWAP_BYTES" ]]
  [[ -f "$STATE_DIR/swapfile-created" ]]
  [[ "$(awk -v path="$SWAPFILE" '$1 == path {count++} END {print count+0}' "$FSTAB_FILE")" == 1 ]]
  grep -Fqx "$SWAPFILE none swap sw,pri=-2 0 0" "$FSTAB_FILE"
}

# Aplicar um perfil não pode chamar a reversão completa. A troca de modo usa
# somente a limpeza específica do recurso incompatível.
! declare -f apply_zram_profile | grep -Fq 'revert_all'
! declare -f apply_zswap_profile | grep -Fq 'revert_all'

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

! grep -Eq '^[[:space:]]*vm\.swappiness[[:space:]]*=' "$SYSCTL_FILE"
grep -Fqx 'zswap.enabled=0' <(tr ' ' '\n' < "$GRUB_FILE")
grep -Fqx 'compression-algorithm = lz4 zstd' "$ZRAM_FILE"
grep -Fqx 'w! /sys/kernel/mm/transparent_hugepage/enabled - - - - madvise' "$MEMORY_FILE"
grep -Fqx 'w! /sys/kernel/mm/transparent_hugepage/defrag - - - - defer+madvise' "$MEMORY_FILE"
grep -Fqx 'w! /sys/kernel/mm/transparent_hugepage/shmem_enabled - - - - advise' "$MEMORY_FILE"
grep -Fqx 'w! /sys/kernel/mm/transparent_hugepage/khugepaged/defrag - - - - 0' "$MEMORY_FILE"
grep -Fqx 'w! /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_none - - - - 384' "$MEMORY_FILE"
grep -Fqx 'w! /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_swap - - - - 16' "$MEMORY_FILE"
grep -Fqx 'w! /sys/kernel/mm/lru_gen/enabled - - - - 7' "$MEMORY_FILE"
grep -Fqx 'zram' "$PROFILE_STATE"
! grep -RniE 'OnUnitActiveSec=|OnCalendar=|recomp_algorithm|recompress=' \
  "$SYSCTL_FILE" "$MEMORY_FILE" "$ZRAM_FILE"

# Reproduz o defeito anterior: um arquivo vazio existente era aceito como swap.
# A nova implementação deve substituí-lo por um arquivo aparente de 8 GiB.
: > "$SWAPFILE"
apply_zswap_profile

[[ ! -e "$ZRAM_FILE" ]]
! grep -Eq '^[[:space:]]*vm\.swappiness[[:space:]]*=' "$SYSCTL_FILE"
assert_swapfile_8g
grep -Fqx 'zswap' "$PROFILE_STATE"
for token in \
  zswap.enabled=1 \
  zswap.compressor=lz4 \
  zswap.max_pool_percent=35 \
  zswap.zpool=zsmalloc \
  zswap.shrinker_enabled=1; do
  grep -Fqx "$token" <(tr ' ' '\n' < "$GRUB_FILE")
done

# Trocar para ZRAM remove somente o swapfile criado pelo Turbo Decky. Voltar ao
# ZSWAP precisa recriar exatamente 8 GiB, sem executar a reversão geral.
apply_zram_profile
[[ ! -e "$SWAPFILE" ]]
! grep -Fq "$SWAPFILE none swap" "$FSTAB_FILE"
apply_zswap_profile
assert_swapfile_8g

# Âncoras de persistência executadas no sistema real.
grep -Fq 'systemctl mask --now systemd-zram-setup@zram0.service' \
  "$REPO_ROOT/lib/50-memory-mode-safety.sh"
grep -Fq 'swapfile_size_is_8g' "$REPO_ROOT/lib/60-swapfile-safety.sh"
grep -Fq 'swapfile_has_swap_signature' "$REPO_ROOT/lib/60-swapfile-safety.sh"
grep -Fq 'swapfile_is_active' "$REPO_ROOT/lib/60-swapfile-safety.sh"
grep -Fq 'swapon --priority -2' "$REPO_ROOT/lib/60-swapfile-safety.sh"
grep -Fq 'systemctl enable --now fstrim.timer' "$REPO_ROOT/lib/10-profiles.sh"
grep -Fq 'systemctl enable --now scx_lavd.service' "$REPO_ROOT/lib/20-actions.sh"
grep -Fq "printf '%s none swap sw,pri=-2 0 0" "$REPO_ROOT/lib/60-swapfile-safety.sh"
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
