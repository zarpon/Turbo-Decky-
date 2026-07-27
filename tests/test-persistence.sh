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
printf '# pre-existing user zram configuration\n' > \
  "$ROOT/etc/systemd/zram-generator.conf.d/00-turbodecky.conf"

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

# Reproduz o caso do SteamOS: o arquivo existente é um swap válido, porém não
# tem os 8 GiB exigidos. Mesmo sem o marcador interno do Turbo Decky, ele deve
# ser desativado, removido e recriado automaticamente.
REAL_ROOT="$TMP/real-root"
REAL_SWAP_MOCK_BIN="$TMP/real-swap-mock-bin"
REAL_SWAPFILE="$REAL_ROOT/home/swapfile"
REAL_STATE_DIR="$REAL_ROOT/var/lib/turbodecky/state"
REAL_FSTAB_FILE="$REAL_ROOT/etc/fstab"
REAL_SWAP_LOG="$TMP/real-swap.log"
REAL_SWAPOFF_LOG="$TMP/real-swapoff.log"
REAL_ACTIVE_MARK="$TMP/real-swap.active"
mkdir -p "$REAL_ROOT/home" "$REAL_ROOT/etc" "$REAL_STATE_DIR" "$REAL_SWAP_MOCK_BIN"
printf '# real-path swapfile regression\n' > "$REAL_FSTAB_FILE"
truncate -s 1048576 "$REAL_SWAPFILE"
mkswap "$REAL_SWAPFILE" >/dev/null 2>&1
printf '%s\n' "$REAL_SWAPFILE" > "$REAL_ACTIVE_MARK"

cat > "$REAL_SWAP_MOCK_BIN/df" <<'EOF_DF'
#!/usr/bin/env bash
printf 'Avail\n1099511627776\n'
EOF_DF
cat > "$REAL_SWAP_MOCK_BIN/findmnt" <<'EOF_FINDMNT'
#!/usr/bin/env bash
printf 'ext4\n'
EOF_FINDMNT
cat > "$REAL_SWAP_MOCK_BIN/fallocate" <<'EOF_FALLOCATE'
#!/usr/bin/env bash
[[ "${1:-}" == -l && -n "${2:-}" && -n "${3:-}" ]] || exit 2
truncate -s "$2" "$3"
EOF_FALLOCATE
cat > "$REAL_SWAP_MOCK_BIN/swapon" <<'EOF_SWAPON'
#!/usr/bin/env bash
case "${1:-}" in
  --show=NAME)
    [[ -f "${REAL_ACTIVE_MARK:?}" ]] && cat "$REAL_ACTIVE_MARK"
    ;;
  --priority)
    printf '%s\n' "${@: -1}" >> "${REAL_SWAP_LOG:?}"
    printf '%s\n' "${@: -1}" > "$REAL_ACTIVE_MARK"
    ;;
  *) exit 2 ;;
esac
EOF_SWAPON
cat > "$REAL_SWAP_MOCK_BIN/swapoff" <<'EOF_SWAPOFF'
#!/usr/bin/env bash
printf '%s\n' "${*: -1}" >> "${REAL_SWAPOFF_LOG:?}"
rm -f -- "${REAL_ACTIVE_MARK:?}"
EOF_SWAPOFF
chmod +x "$REAL_SWAP_MOCK_BIN"/*

OLD_PATH="$PATH"
PATH="$REAL_SWAP_MOCK_BIN:$PATH"
ROOTFS=""
DRY_RUN=0
STATE_DIR="$REAL_STATE_DIR"
BACKUP_DIR="$REAL_STATE_DIR/backups"
FILE_MANIFEST="$REAL_STATE_DIR/files.tsv"
FSTAB_FILE="$REAL_FSTAB_FILE"
SWAPFILE="$REAL_SWAPFILE"
LOGFILE="$REAL_ROOT/var/log/turbodecky.log"
export REAL_ACTIVE_MARK REAL_SWAP_LOG REAL_SWAPOFF_LOG
ensure_swapfile
PATH="$OLD_PATH"

[[ "$(stat -Lc '%s' "$REAL_SWAPFILE")" == "$EXPECTED_SWAP_BYTES" ]]
[[ "$(blkid -p -s TYPE -o value -- "$REAL_SWAPFILE")" == swap ]]
[[ -f "$REAL_ACTIVE_MARK" ]]
grep -Fqx "$REAL_SWAPFILE" "$REAL_SWAP_LOG"
grep -Fqx "$REAL_SWAPFILE" "$REAL_SWAPOFF_LOG"
grep -Fqx "$REAL_SWAPFILE none swap sw,pri=-2 0 0" "$REAL_FSTAB_FILE"

ROOTFS="$ROOT"
DRY_RUN=1
init_paths

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

# A Btrfs-style managed symlink must remove both the link and its known target
# when switching back to ZRAM or reverting from an isolated root.
SYMLINK_ROOT="$TMP/symlink-root"
mkdir -p "$SYMLINK_ROOT/etc" "$SYMLINK_ROOT/home/.swap" \
  "$SYMLINK_ROOT/var/lib/turbodecky/state"
ROOTFS="$SYMLINK_ROOT"
init_paths
truncate -s "$EXPECTED_SWAP_BYTES" "$(p /home/.swap/turbodecky.swap)"
ln -s "$(p /home/.swap/turbodecky.swap)" "$SWAPFILE"
printf '1\n' > "$STATE_DIR/swapfile-created"
printf '%s.backup none swap sw 0 0\n' "$SWAPFILE" > "$FSTAB_FILE"
printf '%s none swap sw,pri=-2 0 0\n' "$SWAPFILE" >> "$FSTAB_FILE"
remove_created_swapfile
[[ ! -e "$SWAPFILE" && ! -e "$(p /home/.swap/turbodecky.swap)" ]]
[[ ! -e "$STATE_DIR/swapfile-created" ]]
! grep -Fq "$SWAPFILE none swap" "$FSTAB_FILE"
grep -Fqx "$SWAPFILE.backup none swap sw 0 0" "$FSTAB_FILE"

ROOTFS="$ROOT"
init_paths

# Snapshot restoration must also recover a broken symbolic link. A plain -e
# check misses that case because the link target intentionally does not exist.
SNAPSHOT_ROOT="$TMP/snapshot-root"
mkdir -p "$SNAPSHOT_ROOT/etc" "$SNAPSHOT_ROOT/var/lib/turbodecky/state"
ROOTFS="$SNAPSHOT_ROOT"
init_paths
SNAPSHOT_TARGET="$(p /etc/turbodecky-broken-link)"
ln -s /target-that-does-not-exist "$SNAPSHOT_TARGET"
backup_file_once "$SNAPSHOT_TARGET"
rm -f "$SNAPSHOT_TARGET"
printf 'managed replacement\n' > "$SNAPSHOT_TARGET"
restore_files
[[ -L "$SNAPSHOT_TARGET" ]]
[[ "$(readlink "$SNAPSHOT_TARGET")" == /target-that-does-not-exist ]]

ROOTFS="$ROOT"
init_paths

# A reversão deve remover os artefatos gerenciados e restaurar o baseline.
revert_all

grep -Fqx 'GRUB_CMDLINE_LINUX="quiet splash"' "$GRUB_FILE"
grep -Fqx 'baseline=1' "$SYSCTL_FILE"
grep -Fqx '# pre-existing user zram configuration' "$ZRAM_FILE"
for generated in "$MEMORY_FILE" "$LIMITS_FILE" "$ENV_FILE" "$UDEV_FILE"; do
  [[ ! -e "$generated" ]] || { printf 'resíduo após reversão: %s\n' "$generated" >&2; exit 1; }
done
grep -Fqx '# pre-existing user zram configuration' "$ZRAM_FILE"
[[ ! -e "$SWAPFILE" ]]
[[ ! -e "$STATE_DIR" ]]

printf 'Turbo Decky reboot persistence validation passed\n'
