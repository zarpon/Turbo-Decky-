#!/usr/bin/env bash
set -Eeuo pipefail

readonly TURBODECKY_VERSION="4.0.0-test"
readonly TURBODECKY_AUTHOR="Jorge Luis"
readonly TURBODECKY_REPOSITORY="zarpon/Turbo-Decky-"
readonly ZSWAP_COMPRESSOR="lz4kdr"

ROOTFS="${TURBODECKY_ROOTFS:-}"
DRY_RUN="${TURBODECKY_DRY_RUN:-0}"
UI_BACKEND="${TURBODECKY_UI:-auto}"
LOGFILE="${TURBODECKY_LOGFILE:-/var/log/turbodecky.log}"

# A dry run without an explicitly supplied root must never write to the live
# system. Use a disposable root so the normal file-generation paths are still
# exercised without special-casing every write and remove operation.
TURBODECKY_DRY_RUN_SANDBOX=0
TURBODECKY_DRY_RUN_ROOT=""
if [[ "$DRY_RUN" == 1 && -z "$ROOTFS" ]]; then
  TURBODECKY_DRY_RUN_SANDBOX=1
  TURBODECKY_DRY_RUN_ROOT="$(mktemp -d /tmp/turbodecky-dry-run.XXXXXX)"
  ROOTFS="$TURBODECKY_DRY_RUN_ROOT"
  if [[ "${TURBODECKY_LIBRARY:-0}" != 1 ]]; then
    trap 'rm -rf -- "$TURBODECKY_DRY_RUN_ROOT"' EXIT
  fi
fi

# The progress channel is deliberately separate from the regular log.  The
# AppImage launcher consumes these records while direct executions render the
# same updates in a terminal or a native progress dialog.
PROGRESS_ACTIVE=0
PROGRESS_CURRENT=0
PROGRESS_TOTAL=100
PROGRESS_TITLE=""
PROGRESS_PID=""
PROGRESS_FD=""
PROGRESS_DBUS_REF=""
PROGRESS_DBUS_TOOL=""
declare -a PROGRESS_DBUS_ARGS=()
PROGRESS_MODE="terminal"
PROGRESS_PROTOCOL="${TURBODECKY_PROGRESS_PROTOCOL:-0}"

# Perfil de runtime sincronizado com linux-charcoal-vulcano. Esta é a única
# fonte dos valores de sysctl usados pelo Turbo Decky; manter uma segunda lista
# em outro módulo permitia gerar arquivos diferentes do diagnóstico e do
# snapshot de reversão.
readonly CHARCOAL_SYSCTL=(
  "vm.page-cluster=0"
  "vm.min_free_kbytes=262144"
  "vm.compaction_proactiveness=15"
  "vm.dirty_expire_centisecs=3500"
  "vm.dirty_writeback_centisecs=500"
  "vm.watermark_boost_factor=0"
  "vm.watermark_scale_factor=125"
  "kernel.split_lock_mitigate=0"
  "vm.dirty_background_bytes=209715200"
  "vm.dirty_bytes=409430400"
  "vm.vfs_cache_pressure=125"
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
  if [[ "${PROGRESS_ACTIVE:-0}" == 1 && "$UI_BACKEND" == terminal && \
    "$PROGRESS_PROTOCOL" != 1 ]]; then
    printf '\n' >&2
  fi
  printf '%s - %s\n' "$(date '+%F %T')" "$message" | tee -a "$real_log" >&2
}

die() {
  ui_progress_fail "$*"
  ui_error "$*"
  cleanup_dry_run_sandbox 2>/dev/null || true
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

ui_confirm_required() {
  local text="$*"
  [[ "${TURBODECKY_ASSUME_YES:-0}" == 1 ]] && return 0
  detect_ui
  case "$UI_BACKEND" in
    yad) yad --question --title="Turbo Decky" --width=620 --text="$text" 2>/dev/null ;;
    zenity) zenity --question --title="Turbo Decky" --width=620 --text="$text" 2>/dev/null ;;
    kdialog) kdialog --title "Turbo Decky" --yesno "$text" 2>/dev/null ;;
    dialog) dialog --title "Turbo Decky" --yesno "$text" 12 76 2>/dev/tty ;;
    *)
      local answer
      read -r -p "$text [s/N]: " answer
      [[ "$answer" =~ ^[sSyY]$ ]]
      ;;
  esac
}

ui_progress_sanitize() {
  local text="$*"
  text="${text//$'\n'/ }"
  text="${text//$'\t'/ }"
  printf '%s' "$text"
}

ui_progress_close() {
  [[ "${PROGRESS_ACTIVE:-0}" == 1 ]] || return 0

  if [[ -n "${PROGRESS_FD:-}" ]]; then
    eval "exec ${PROGRESS_FD}>&-" 2>/dev/null || true
    PROGRESS_FD=""
  fi
  if [[ -n "${PROGRESS_DBUS_REF:-}" && -n "${PROGRESS_DBUS_TOOL:-}" ]]; then
    "$PROGRESS_DBUS_TOOL" "${PROGRESS_DBUS_ARGS[@]}" close >/dev/null 2>&1 || true
    PROGRESS_DBUS_REF=""
    PROGRESS_DBUS_TOOL=""
    PROGRESS_DBUS_ARGS=()
  fi
  if [[ -n "${PROGRESS_PID:-}" ]]; then
    kill "$PROGRESS_PID" 2>/dev/null || true
    wait "$PROGRESS_PID" 2>/dev/null || true
    PROGRESS_PID=""
  fi

  if [[ "$PROGRESS_MODE" == terminal ]]; then
    printf '\n' >&2
  fi

  PROGRESS_ACTIVE=0
  PROGRESS_CURRENT=0
  PROGRESS_TOTAL=100
  PROGRESS_TITLE=""
  PROGRESS_MODE="terminal"
}

ui_progress_qdbus() {
  local command
  for command in qdbus qdbus-qt5 qdbus6; do
    if command -v "$command" >/dev/null 2>&1; then
      command -v "$command"
      return 0
    fi
  done
  return 1
}

ui_progress_start() {
  local title="$1" total="${2:-100}"
  detect_ui
  PROGRESS_ACTIVE=1
  PROGRESS_CURRENT=0
  PROGRESS_TOTAL="$total"
  PROGRESS_TITLE="$title"
  PROGRESS_DBUS_REF=""
  PROGRESS_DBUS_TOOL=""
  PROGRESS_DBUS_ARGS=()

  if [[ "$PROGRESS_PROTOCOL" == 1 ]]; then
    PROGRESS_MODE="protocol"
    printf 'TURBODECKY_PROGRESS\t0\t%s\n' "$(ui_progress_sanitize "$title")"
    return 0
  fi

  case "$UI_BACKEND" in
    kdialog)
      PROGRESS_DBUS_TOOL="$(ui_progress_qdbus 2>/dev/null || true)"
      if [[ -n "$PROGRESS_DBUS_TOOL" ]]; then
        PROGRESS_DBUS_REF="$(kdialog --progressbar "$title" "$total" 2>/dev/null || true)"
        if [[ -n "$PROGRESS_DBUS_REF" ]]; then
          read -r -a PROGRESS_DBUS_ARGS <<< "$PROGRESS_DBUS_REF"
          PROGRESS_MODE="kdialog"
        else
          PROGRESS_DBUS_TOOL=""
        fi
      fi
      [[ "$PROGRESS_MODE" == kdialog ]] || printf '\n%s\n' "$title" >&2
      ;;
    yad|zenity|dialog)
      case "$UI_BACKEND" in
        yad)
          coproc TURBODECKY_PROGRESS_UI {
            yad --progress --title="Turbo Decky" --width=700 --height=180 \
            --percentage=0 --auto-close --no-buttons --text="$title" \
              >/dev/null 2>&1
          }
          ;;
        zenity)
          coproc TURBODECKY_PROGRESS_UI {
            zenity --progress --title="Turbo Decky" --width=700 --height=180 \
            --percentage=0 --auto-close --no-cancel --text="$title" \
              >/dev/null 2>&1
          }
          ;;
        dialog)
          coproc TURBODECKY_PROGRESS_UI {
            dialog --gauge "$title" 10 82 0 >/dev/tty 2>/dev/tty
          }
          ;;
      esac
      PROGRESS_PID="$TURBODECKY_PROGRESS_UI_PID"
      PROGRESS_FD="${TURBODECKY_PROGRESS_UI[1]}"
      PROGRESS_MODE="pipe"
      ;;
    *)
      printf '\n%s\n' "$title" >&2
      ;;
  esac
}

ui_progress_update() {
  local percent="$1" message="$2"
  [[ "${PROGRESS_ACTIVE:-0}" == 1 ]] || return 0
  (( percent < 0 )) && percent=0
  (( percent > 100 )) && percent=100
  PROGRESS_CURRENT="$percent"
  message="$(ui_progress_sanitize "$message")"

  if [[ "$PROGRESS_PROTOCOL" == 1 ]]; then
    printf 'TURBODECKY_PROGRESS\t%s\t%s\n' "$percent" "$message"
    return 0
  fi

  case "$UI_BACKEND" in
    yad|zenity)
      if [[ -n "${PROGRESS_FD:-}" ]]; then
        printf '%s\n#%s\n' "$percent" "$message" >&"$PROGRESS_FD" 2>/dev/null || true
      fi
      ;;
    kdialog)
      if [[ -n "${PROGRESS_DBUS_REF:-}" && -n "${PROGRESS_DBUS_TOOL:-}" ]]; then
        "$PROGRESS_DBUS_TOOL" "${PROGRESS_DBUS_ARGS[@]}" setLabelText "$message" >/dev/null 2>&1 || true
        "$PROGRESS_DBUS_TOOL" "${PROGRESS_DBUS_ARGS[@]}" Set "" value "$percent" >/dev/null 2>&1 || true
      else
        printf '\r[%3d%%] %s' "$percent" "$message" >&2
      fi
      ;;
    dialog)
      if [[ -n "${PROGRESS_FD:-}" ]]; then
        printf 'XXX\n%s\n%s\nXXX\n' "$message" "$percent" >&"$PROGRESS_FD" 2>/dev/null || true
      fi
      ;;
    *)
      printf '\r[%3d%%] %s' "$percent" "$message" >&2
      ;;
  esac
}

ui_progress_finish() {
  local message="${1:-Concluído}"
  [[ "${PROGRESS_ACTIVE:-0}" == 1 ]] || return 0
  ui_progress_update 100 "$message"
  ui_progress_close 0
}

ui_progress_fail() {
  local message="${1:-Falha na operação}"
  [[ "${PROGRESS_ACTIVE:-0}" == 1 ]] || return 0
  ui_progress_update "$PROGRESS_CURRENT" "Falha: $message"
  ui_progress_close 1
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
    case "$file" in
      "$(p /etc/)"*|"$(p /var/lib/turbodecky/)"*) ;;
      *)
        log "snapshot ignorado por caminho não gerenciado: $file"
        continue
        ;;
    esac
    rm -rf -- "$file"
    if [[ "$existed" == 1 && ( -e "$backup" || -L "$backup" ) ]]; then
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

cleanup_dry_run_sandbox() {
  [[ -n "${TURBODECKY_DRY_RUN_ROOT:-}" ]] || return 0
  rm -rf -- "$TURBODECKY_DRY_RUN_ROOT"
  TURBODECKY_DRY_RUN_ROOT=""
}

restore_steamos_readonly() {
  ui_progress_fail "A operação foi interrompida" 2>/dev/null || true
  if [[ "${STEAMOS_WAS_READONLY:-0}" == 1 ]]; then
    steamos-readonly enable 2>/dev/null || true
  fi
  STEAMOS_WAS_READONLY=0
  cleanup_dry_run_sandbox
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

write_charcoal_memory() {
  backup_file_once "$MEMORY_FILE"
  {
    printf '# Turbo Decky - perfil de memória sincronizado com linux-charcoal-vulcano\n'
    printf '%s\n' "${CHARCOAL_MEMORY_TMPFILES[@]}"
  } | atomic_write "$MEMORY_FILE" 0644
}

write_charcoal_sysctl() {
  backup_file_once "$SYSCTL_FILE"
  {
    printf '# Turbo Decky - perfil sincronizado com linux-charcoal-vulcano\n'
    printf '# vm.swappiness permanece sob controle do SteamOS ou do usuário.\n'
    printf '# Ajustes opcionais de recompressão não fazem parte deste perfil.\n'
    printf '%s\n' "${CHARCOAL_SYSCTL[@]}"
  } | atomic_write "$SYSCTL_FILE" 0644
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
# Turbo Decky: ajustes conservadores, sem substituir o scheduler do kernel.
ACTION=="add|change", KERNEL=="nvme*n*", ATTR{queue/read_ahead_kb}="512", ATTR{queue/rotational}="0", ATTR{queue/iostats}="0", ATTR{queue/add_random}="0"
ACTION=="add|change", KERNEL=="mmcblk*", ATTR{queue/read_ahead_kb}="1024", ATTR{queue/rotational}="0", ATTR{queue/iostats}="0", ATTR{queue/add_random}="0"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/iostats}="0", ATTR{queue/add_random}="0"
EOF_UDEV
}
