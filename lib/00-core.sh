#!/usr/bin/env bash
set -Eeuo pipefail

readonly TURBODECKY_VERSION="4.0.0-test"
readonly TURBODECKY_AUTHOR="Jorge Luis"
readonly TURBODECKY_REPOSITORY="zarpon/Turbo-Decky-"

ROOTFS="${TURBODECKY_ROOTFS:-}"
DRY_RUN="${TURBODECKY_DRY_RUN:-0}"
UI_BACKEND="${TURBODECKY_UI:-auto}"
LOGFILE="${TURBODECKY_LOGFILE:-/var/log/turbodecky.log}"

# Perfil copiado do linux-charcoal-vulcano. Estes valores são deliberadamente
# fixos para impedir divergência entre o kernel e o utilitário de instalação.
readonly CHARCOAL_SYSCTL=(
  "vm.compaction_proactiveness=10"
  "vm.swappiness=200"
  "vm.page-cluster=0"
  "vm.vfs_cache_pressure=50"
  "vm.dirty_background_bytes=268435456"
  "vm.dirty_bytes=1073741824"
  "vm.dirty_expire_centisecs=3000"
  "vm.dirty_writeback_centisecs=500"
  "vm.max_map_count=2147483642"
  "kernel.sched_autogroup_enabled=0"
  "fs.inotify.max_user_watches=1048576"
  "fs.inotify.max_user_instances=8192"
  "fs.file-max=2097152"
  "net.core.default_qdisc=fq"
)

readonly CHARCOAL_MEMORY_TMPFILES=(
  "w! /sys/kernel/mm/transparent_hugepage/enabled - - - - madvise"
  "w! /sys/kernel/mm/transparent_hugepage/defrag - - - - defer+madvise"
  "w! /sys/kernel/mm/transparent_hugepage/shmem_enabled - - - - advise"
  "w! /sys/kernel/mm/transparent_hugepage/khugepaged/defrag - - - - 0"
  "w! /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_none - - - - 384"
  "w! /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_swap - - - - 16"
  "w! /sys/kernel/mm/ksm/run - - - - 0"
  "w! /sys/kernel/mm/lru_gen/enabled - - - - 7"
  "w! /sys/kernel/mm/lru_gen/min_ttl_ms - - - - 0"
)

readonly MANAGED_SERVICES=(
  "gpu-trace.service"
  "steamos-log-submitter.service"
  "cups.service"
)

readonly MANAGED_GRUB_KEYS=(
  zswap.enabled zswap.compressor zswap.max_pool_percent zswap.zpool
  zswap.shrinker_enabled mitigations audit nmi_watchdog nowatchdog
  split_lock_detect
)

readonly LEGACY_RECOMPRESSION_FILES=(
  "/etc/systemd/system/zram-recompress.timer"
  "/etc/systemd/system/zram-recompress.service"
  "/etc/systemd/system/charcoaltd-zram-recompress.timer"
  "/etc/systemd/system/charcoaltd-zram-recompress.service"
  "/etc/systemd/system/zram-preconfig.service"
  "/usr/local/bin/zram-recompress.sh"
  "/usr/local/bin/zram-preconfig.sh"
  "/var/lib/turbodecky/bin/zram-recompress.sh"
)

p() {
  local path="$1"
  if [[ -n "$ROOTFS" ]]; then
    printf '%s%s\n' "${ROOTFS%/}" "$path"
  else
    printf '%s\n' "$path"
  fi
}

init_paths() {
  STATE_DIR="$(p /var/lib/turbodecky/state)"
  BACKUP_DIR="$STATE_DIR/backups"
  FILE_MANIFEST="$STATE_DIR/files.tsv"
  RUNTIME_SNAPSHOT="$STATE_DIR/runtime.tsv"
  SERVICE_SNAPSHOT="$STATE_DIR/services.tsv"
  PROFILE_STATE="$STATE_DIR/profile"
  SYSCTL_FILE="$(p /etc/sysctl.d/99-turbodecky.conf)"
  MEMORY_FILE="$(p /etc/tmpfiles.d/99-turbodecky-memory.conf)"
  LIMITS_FILE="$(p /etc/security/limits.d/99-turbodecky.conf)"
  ENV_FILE="$(p /etc/environment.d/99-turbodecky.conf)"
  UDEV_FILE="$(p /etc/udev/rules.d/99-turbodecky-io.rules)"
  ZRAM_FILE="$(p /etc/systemd/zram-generator.conf.d/00-turbodecky.conf)"
  FSTAB_FILE="$(p /etc/fstab)"
  GRUB_FILE="$(p /etc/default/grub)"
  SWAPFILE="$(p /home/swapfile)"
}
init_paths

log() {
  local message="$*" real_log="$LOGFILE"
  [[ -n "$ROOTFS" ]] && real_log="$(p "$LOGFILE")"
  mkdir -p "$(dirname "$real_log")" 2>/dev/null || true
  printf '%s - %s\n' "$(date '+%F %T')" "$message" | tee -a "$real_log" >&2
}

die() {
  ui_error "$*"
  exit 1
}

have_graphical_session() {
  [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]
}

detect_ui() {
  [[ "$UI_BACKEND" != auto ]] && return 0
  if have_graphical_session && command -v yad >/dev/null 2>&1; then
    UI_BACKEND=yad
  elif have_graphical_session && command -v zenity >/dev/null 2>&1; then
    UI_BACKEND=zenity
  elif have_graphical_session && command -v kdialog >/dev/null 2>&1; then
    UI_BACKEND=kdialog
  elif command -v dialog >/dev/null 2>&1 && [[ -t 1 ]]; then
    UI_BACKEND=dialog
  else
    UI_BACKEND=terminal
  fi
}

ui_info() {
  local text="$*"
  detect_ui
  case "$UI_BACKEND" in
    yad) yad --info --title="Turbo Decky" --width=520 --text="$text" 2>/dev/null || true ;;
    zenity) zenity --info --title="Turbo Decky" --width=520 --text="$text" 2>/dev/null || true ;;
    kdialog) kdialog --title "Turbo Decky" --msgbox "$text" 2>/dev/null || true ;;
    dialog) dialog --title "Turbo Decky" --msgbox "$text" 12 72 2>/dev/tty || true ;;
    *) printf '\n%s\n' "$text" ;;
  esac
}

ui_error() {
  local text="$*"
  detect_ui
  case "$UI_BACKEND" in
    yad) yad --error --title="Turbo Decky" --width=560 --text="$text" 2>/dev/null || true ;;
    zenity) zenity --error --title="Turbo Decky" --width=560 --text="$text" 2>/dev/null || true ;;
    kdialog) kdialog --title "Turbo Decky" --error "$text" 2>/dev/null || true ;;
    dialog) dialog --title "Erro" --msgbox "$text" 12 72 2>/dev/tty || true ;;
    *) printf '\nERRO: %s\n' "$text" >&2 ;;
  esac
}

ui_confirm() {
  local text="$*"
  [[ "${TURBODECKY_ASSUME_YES:-0}" == 1 ]] && return 0
  detect_ui
  case "$UI_BACKEND" in
    yad) yad --question --title="Turbo Decky" --width=560 --text="$text" 2>/dev/null ;;
    zenity) zenity --question --title="Turbo Decky" --width=560 --text="$text" 2>/dev/null ;;
    kdialog) kdialog --title "Turbo Decky" --yesno "$text" 2>/dev/null ;;
    dialog) dialog --title "Turbo Decky" --yesno "$text" 12 72 2>/dev/tty ;;
    *)
      local answer
      read -r -p "$text [s/N]: " answer
      [[ "$answer" =~ ^[sSyY]$ ]]
      ;;
  esac
}

ui_menu() {
  detect_ui
  case "$UI_BACKEND" in
    yad)
      yad --list --title="Turbo Decky $TURBODECKY_VERSION" --width=760 --height=500 \
        --text="Selecione uma ação. As alterações são registradas e reversíveis." \
        --column="Ação" --column="Descrição" --print-column=1 --hide-column=1 \
        zswap "Aplicar perfil Charcoal com ZSWAP e swapfile" \
        zram "Aplicar perfil Charcoal com ZRAM padrão" \
        status "Exibir diagnóstico e parâmetros efetivos" \
        kernel "Instalar o kernel Charcoal mais recente" \
        stock-kernel "Restaurar o kernel padrão do SteamOS" \
        lavd "Instalar/ativar o scheduler SCX LAVD" \
        revert "Reverter somente alterações gerenciadas pelo Turbo Decky" \
        exit "Sair" 2>/dev/null || printf 'exit\n'
      ;;
    zenity)
      zenity --list --title="Turbo Decky $TURBODECKY_VERSION" --width=760 --height=500 \
        --text="Selecione uma ação. As alterações são registradas e reversíveis." \
        --column="Ação" --column="Descrição" --print-column=1 --hide-column=1 \
        zswap "Aplicar perfil Charcoal com ZSWAP e swapfile" \
        zram "Aplicar perfil Charcoal com ZRAM padrão" \
        status "Exibir diagnóstico e parâmetros efetivos" \
        kernel "Instalar o kernel Charcoal mais recente" \
        stock-kernel "Restaurar o kernel padrão do SteamOS" \
        lavd "Instalar/ativar o scheduler SCX LAVD" \
        revert "Reverter somente alterações gerenciadas pelo Turbo Decky" \
        exit "Sair" 2>/dev/null || printf 'exit\n'
      ;;
    kdialog)
      kdialog --title "Turbo Decky $TURBODECKY_VERSION" --menu "Selecione uma ação" \
        zswap "Perfil Charcoal + ZSWAP" zram "Perfil Charcoal + ZRAM" \
        status "Diagnóstico" kernel "Instalar kernel Charcoal" \
        stock-kernel "Restaurar kernel padrão" lavd "Ativar SCX LAVD" \
        revert "Reverter alterações" exit "Sair" 2>/dev/null || printf 'exit\n'
      ;;
    dialog)
      dialog --stdout --title "Turbo Decky $TURBODECKY_VERSION" --menu "Selecione uma ação" 20 80 10 \
        zswap "Perfil Charcoal + ZSWAP" zram "Perfil Charcoal + ZRAM" \
        status "Diagnóstico" kernel "Instalar kernel Charcoal" \
        stock-kernel "Restaurar kernel padrão" lavd "Ativar SCX LAVD" \
        revert "Reverter alterações" exit "Sair" 2>/dev/tty || printf 'exit\n'
      ;;
    *)
      cat <<'MENU'
1) Aplicar perfil Charcoal com ZSWAP
2) Aplicar perfil Charcoal com ZRAM padrão
3) Exibir diagnóstico
4) Instalar kernel Charcoal
5) Restaurar kernel padrão
6) Instalar/ativar SCX LAVD
7) Reverter alterações
8) Sair
MENU
      local answer
      read -r -p "Opção: " answer
      case "$answer" in
        1) printf 'zswap\n';; 2) printf 'zram\n';; 3) printf 'status\n';;
        4) printf 'kernel\n';; 5) printf 'stock-kernel\n';; 6) printf 'lavd\n';;
        7) printf 'revert\n';; *) printf 'exit\n';;
      esac
      ;;
  esac
}

require_root() {
  if [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]]; then
    return 0
  fi
  (( EUID == 0 )) || die "Execute esta ação como root: sudo $0 $*"
}

run() {
  if [[ "$DRY_RUN" == 1 ]]; then
    log "DRY-RUN: $*"
    return 0
  fi
  "$@"
}

atomic_write() {
  local destination="$1" mode="${2:-0644}" directory temporary
  directory="$(dirname "$destination")"
  mkdir -p "$directory"
  temporary="$(mktemp "$directory/.turbodecky.XXXXXX")"
  cat > "$temporary"
  chmod "$mode" "$temporary"
  mv -f "$temporary" "$destination"
}

backup_file_once() {
  local file="$1" digest backup existed=0
  mkdir -p "$BACKUP_DIR"
  touch "$FILE_MANIFEST"
  grep -Fq "${file}"$'\t' "$FILE_MANIFEST" 2>/dev/null && return 0
  digest="$(printf '%s' "$file" | sha256sum | awk '{print $1}')"
  backup="$BACKUP_DIR/$digest"
  if [[ -e "$file" || -L "$file" ]]; then
    cp -a "$file" "$backup"
    existed=1
  fi
  printf '%s\t%s\t%s\n' "$file" "$backup" "$existed" >> "$FILE_MANIFEST"
}

restore_files() {
  [[ -f "$FILE_MANIFEST" ]] || return 0
  local file backup existed
  while IFS=$'\t' read -r file backup existed; do
    [[ -n "$file" ]] || continue
    rm -rf -- "$file"
    if [[ "$existed" == 1 && -e "$backup" ]]; then
      mkdir -p "$(dirname "$file")"
      cp -a "$backup" "$file"
    fi
  done < "$FILE_MANIFEST"
}

selector_value() {
  local file="$1" text
  [[ -r "$file" ]] || return 1
  text="$(cat "$file")"
  if [[ "$text" =~ \[([^]]+)\] ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '%s\n' "${text%% *}"
  fi
}

snapshot_runtime_once() {
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0
  [[ -f "$RUNTIME_SNAPSHOT" ]] && return 0
  mkdir -p "$STATE_DIR"
  : > "$RUNTIME_SNAPSHOT"
  local pair key value relative file
  for pair in "${CHARCOAL_SYSCTL[@]}"; do
    key="${pair%%=*}"
    value="$(sysctl -n "$key" 2>/dev/null || true)"
    [[ -n "$value" ]] && printf 'sysctl\t%s\t%s\n' "$key" "$value" >> "$RUNTIME_SNAPSHOT"
  done
  for relative in \
    transparent_hugepage/enabled transparent_hugepage/defrag \
    transparent_hugepage/shmem_enabled transparent_hugepage/khugepaged/defrag \
    transparent_hugepage/khugepaged/max_ptes_none \
    transparent_hugepage/khugepaged/max_ptes_swap ksm/run \
    lru_gen/enabled lru_gen/min_ttl_ms; do
    file="/sys/kernel/mm/$relative"
    value="$(selector_value "$file" 2>/dev/null || true)"
    [[ -n "$value" ]] && printf 'sysfs\t%s\t%s\n' "$file" "$value" >> "$RUNTIME_SNAPSHOT"
  done
}

snapshot_services_once() {
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0
  [[ -f "$SERVICE_SNAPSHOT" ]] && return 0
  mkdir -p "$STATE_DIR"
  : > "$SERVICE_SNAPSHOT"
  local service enabled active
  for service in "${MANAGED_SERVICES[@]}" fstrim.timer scx_lavd.service systemd-zram-setup@zram0.service; do
    enabled="$(systemctl is-enabled "$service" 2>/dev/null || true)"
    active="$(systemctl is-active "$service" 2>/dev/null || true)"
    printf '%s\t%s\t%s\n' "$service" "${enabled:-not-found}" "${active:-inactive}" >> "$SERVICE_SNAPSHOT"
  done
}

restore_runtime() {
  [[ -f "$RUNTIME_SNAPSHOT" ]] || return 0
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0
  local type key value
  while IFS=$'\t' read -r type key value; do
    case "$type" in
      sysctl) sysctl -q -w "$key=$value" 2>/dev/null || true ;;
      sysfs) [[ -w "$key" ]] && printf '%s' "$value" > "$key" || true ;;
    esac
  done < "$RUNTIME_SNAPSHOT"
}

restore_services() {
  [[ -f "$SERVICE_SNAPSHOT" ]] || return 0
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0
  local service enabled active
  while IFS=$'\t' read -r service enabled active; do
    case "$enabled" in
      enabled|enabled-runtime|linked|linked-runtime|alias) systemctl unmask "$service" 2>/dev/null || true; systemctl enable "$service" 2>/dev/null || true ;;
      masked|masked-runtime) systemctl mask "$service" 2>/dev/null || true ;;
      disabled) systemctl unmask "$service" 2>/dev/null || true; systemctl disable "$service" 2>/dev/null || true ;;
    esac
    if [[ "$active" == active ]]; then
      systemctl start "$service" 2>/dev/null || true
    else
      systemctl stop "$service" 2>/dev/null || true
    fi
  done < "$SERVICE_SNAPSHOT"
}

unlock_steamos() {
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0
  command -v steamos-readonly >/dev/null 2>&1 || return 0
  if steamos-readonly status 2>/dev/null | grep -qi enabled; then
    steamos-readonly disable
    STEAMOS_WAS_READONLY=1
  else
    STEAMOS_WAS_READONLY=0
  fi
}

restore_steamos_readonly() {
  [[ "${STEAMOS_WAS_READONLY:-0}" == 1 ]] || return 0
  steamos-readonly enable 2>/dev/null || true
}

cleanup_legacy_recompression() {
  local file
  if [[ -z "$ROOTFS" && "$DRY_RUN" != 1 ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now zram-recompress.timer charcoaltd-zram-recompress.timer zram-preconfig.service 2>/dev/null || true
  fi
  for file in "${LEGACY_RECOMPRESSION_FILES[@]}"; do
    rm -f -- "$(p "$file")"
  done
}

write_charcoal_sysctl() {
  backup_file_once "$SYSCTL_FILE"
  {
    printf '# Turbo Decky - perfil sincronizado com linux-charcoal-vulcano\n'
    printf '%s\n' "${CHARCOAL_SYSCTL[@]}"
  } | atomic_write "$SYSCTL_FILE" 0644
}

write_charcoal_memory() {
  backup_file_once "$MEMORY_FILE"
  {
    printf '# Turbo Decky - perfil de memória sincronizado com linux-charcoal-vulcano\n'
    printf '%s\n' "${CHARCOAL_MEMORY_TMPFILES[@]}"
  } | atomic_write "$MEMORY_FILE" 0644
}

write_common_files() {
  backup_file_once "$LIMITS_FILE"
  cat <<'EOF_LIMITS' | atomic_write "$LIMITS_FILE" 0644
* soft nofile 524288
* hard nofile 524288
root soft nofile 524288
root hard nofile 524288
EOF_LIMITS

  backup_file_once "$ENV_FILE"
  cat <<'EOF_ENV' | atomic_write "$ENV_FILE" 0644
MESA_SHADER_CACHE_MAX_SIZE=10G
MESA_DISK_CACHE_DATABASE=1
EOF_ENV

  backup_file_once "$UDEV_FILE"
  cat <<'EOF_UDEV' | atomic_write "$UDEV_FILE" 0644
# Turbo Decky: ajustes conservadores, sem substituir ADIOS quando ele está ativo.
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/read_ahead_kb}="512", ATTR{queue/rotational}="0"
ACTION=="add|change", KERNEL=="mmcblk[0-9]*", ATTR{queue/read_ahead_kb}="1024", ATTR{queue/rotational}="0"
ACTION=="add|change", KERNEL=="nvme[0-9]*|sd[a-z]|mmcblk[0-9]*", ATTR{queue/iostats}="0", ATTR{queue/add_random}="0"
EOF_UDEV
}
