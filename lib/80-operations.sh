#!/usr/bin/env bash
# Transaction journal, preflight and recovery. No system changes at source time.
OPERATION_ACTIVE=0
OPERATION_DIR=""
OPERATION_LOCK_FD=""
OPERATION_COMMITTED=0

managed_files() {
  printf '%s\n' "$SYSCTL_FILE" "$MEMORY_FILE" "$LIMITS_FILE" "$ENV_FILE" \
    "$UDEV_FILE" "$ZRAM_FILE" "$FSTAB_FILE" "$GRUB_FILE" \
    "$ZSWAP_RUNTIME_HELPER" "$ZSWAP_RUNTIME_SERVICE" "$PROFILE_STATE" \
    "$STATE_DIR/swapfile-created" \
    "$(p /etc/systemd/system/systemd-zram-setup@zram0.service)" \
    "$(p /etc/systemd/system/timers.target.wants/fstrim.timer)" \
    "$(p /etc/systemd/system/multi-user.target.wants/turbodecky-zswap-runtime.service)"
  local service
  for service in "${MANAGED_SERVICES[@]}"; do printf '%s\n' "$(p "/etc/systemd/system/$service")"; done
}

operation_lock() {
  local lock
  lock="$(p /run/lock/turbodecky.lock)"
  command -v flock >/dev/null 2>&1 || die "flock é necessário para impedir operações simultâneas."
  mkdir -p "$(dirname "$lock")"
  exec {OPERATION_LOCK_FD}>"$lock"
  flock -n "$OPERATION_LOCK_FD" || die "Outra operação do Turbo Decky está em andamento."
}

check_file_conflicts() {
  [[ -f "$STATE_DIR/applied-files.tsv" ]] || return 0
  local file expected actual
  while IFS=$'\t' read -r file expected; do
    actual="$(file_fingerprint "$file")" || return 1
    [[ "$actual" == "$expected" ]] || {
      ui_error "Alteração externa detectada em $file. Nada foi sobrescrito. Preserve sua configuração e resolva o conflito antes de continuar."
      return 1
    }
  done < "$STATE_DIR/applied-files.tsv"
}

record_applied_files() {
  local file
  {
    while IFS= read -r file; do
      [[ "$file" == "$PROFILE_STATE" || "$file" == "$STATE_DIR/swapfile-created" ]] && continue
      printf '%s\t%s\n' "$file" "$(file_fingerprint "$file")"
    done < <(awk -F '\t' '{print $1}' "$FILE_MANIFEST")
  } | atomic_write "$STATE_DIR/applied-files.tsv" 0600
}

preflight_profile() {
  local mode="$1" command params
  if [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]]; then
    return 0
  fi
  for command in python3 systemctl sysctl systemd-tmpfiles udevadm swapon swapoff; do
    command -v "$command" >/dev/null 2>&1 || die "Requisito ausente: $command"
  done
  [[ -f "$GRUB_FILE" ]] || die "Bootloader sem GRUB suportado. Nenhuma alteração foi aplicada."
  if ! command -v steamos-update-grub >/dev/null 2>&1 && \
     ! command -v update-grub >/dev/null 2>&1 && \
     ! command -v grub-mkconfig >/dev/null 2>&1; then
    die "Atualizador de GRUB ausente. Nenhuma alteração foi aplicada."
  fi
  # A swap transition needs enough RAM to fault swapped-out pages back in.
  local available used
  available="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
  used="$(awk '/^SwapTotal:/ {total=$2} /^SwapFree:/ {free=$2} END {print total-free}' /proc/meminfo)"
  (( available > used + 524288 )) || die "Memória insuficiente para trocar o perfil com segurança. Feche os jogos e tente novamente."
  if [[ "$mode" == zswap ]]; then
    for params in enabled compressor max_pool_percent shrinker_enabled; do
      [[ -w "$ZSWAP_SYSFS_DIR/$params" ]] || die "Kernel sem parâmetro ZSWAP compatível: $params"
    done
    preflight_swapfile
  else
    [[ -x /usr/lib/systemd/system-generators/zram-generator || -x /lib/systemd/system-generators/zram-generator ]] || \
      die "zram-generator não está instalado. Nenhuma alteração foi aplicada."
  fi
  validate_grub_format
}

operation_begin() {
  local kind="$1" file baseline_manifest="$FILE_MANIFEST" baseline_backup="$BACKUP_DIR"
  require_root "$kind"
  operation_lock
  if [[ -d "$STATE_DIR/transaction" ]]; then
    die "Uma operação anterior foi interrompida. Use --recover para restaurar a transação antes de continuar."
  fi
  check_file_conflicts || die "Conflito com configuração externa."
  [[ "$kind" == revert ]] || preflight_profile "$kind"
  if [[ -s "$FILE_MANIFEST" ]]; then
    validate_snapshot || die "Snapshot inválido; nenhuma alteração foi iniciada."
  fi
  unlock_steamos
  mkdir -p "$STATE_DIR" "$BACKUP_DIR"
  chmod 0700 "$STATE_DIR"
  OPERATION_DIR="$STATE_DIR/transaction"
  mkdir -p "$OPERATION_DIR/backups"
  FILE_MANIFEST="$OPERATION_DIR/files.tsv"
  BACKUP_DIR="$OPERATION_DIR/backups"
  while IFS= read -r file; do backup_file_once "$file"; done < <(managed_files)
  FILE_MANIFEST="$baseline_manifest"
  BACKUP_DIR="$baseline_backup"
  local runtime_snapshot="$RUNTIME_SNAPSHOT" service_snapshot="$SERVICE_SNAPSHOT"
  RUNTIME_SNAPSHOT="$OPERATION_DIR/runtime.tsv"
  SERVICE_SNAPSHOT="$OPERATION_DIR/services.tsv"
  snapshot_runtime_once
  snapshot_services_once
  RUNTIME_SNAPSHOT="$runtime_snapshot"
  SERVICE_SNAPSHOT="$service_snapshot"
  printf '%s\n' "$kind" > "$OPERATION_DIR/kind"
  printf 'applying\n' > "$STATE_DIR/operation-state"
  OPERATION_ACTIVE=1
  OPERATION_COMMITTED=0
    trap 'operation_exit "$?"' EXIT
  trap 'die "Operação interrompida pelo usuário."' INT TERM
  trap 'operation_error "$?" "$LINENO"' ERR
}

operation_error() {
  local status="$1" line="$2"
  trap - ERR
  ui_error "Falha na etapa: ${PROGRESS_MESSAGE:-preparação} (linha $line, código $status)."
  exit "$status"
}

restore_swap_activity() {
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0
  swapon -a || return 1
}

operation_rollback() {
  local baseline_manifest="$FILE_MANIFEST" baseline_backup="$BACKUP_DIR"
  local runtime_snapshot="$RUNTIME_SNAPSHOT" service_snapshot="$SERVICE_SNAPSHOT" failed=0
  FILE_MANIFEST="$OPERATION_DIR/files.tsv"
  BACKUP_DIR="$OPERATION_DIR/backups"
  validate_snapshot || failed=1
  if (( failed == 0 )); then
    unlock_steamos || failed=1
    if [[ -f "$OPERATION_DIR/swap-created" ]]; then
      remove_existing_swapfile || failed=1
    fi
    restore_files || failed=1
    if [[ -z "$ROOTFS" && "$DRY_RUN" != 1 ]]; then
      systemctl daemon-reload || failed=1
      SERVICE_SNAPSHOT="$OPERATION_DIR/services.tsv"
      RUNTIME_SNAPSHOT="$OPERATION_DIR/runtime.tsv"
      restore_services || failed=1
      restore_swap_activity || failed=1
      restore_runtime || failed=1
      udevadm control --reload-rules || failed=1
      update_grub_runtime || failed=1
    fi
  fi
  FILE_MANIFEST="$baseline_manifest"
  BACKUP_DIR="$baseline_backup"
  RUNTIME_SNAPSHOT="$runtime_snapshot"
  SERVICE_SNAPSHOT="$service_snapshot"
  (( failed == 0 ))
}

operation_exit() {
  local status="$1"
  trap - ERR INT TERM EXIT
  if [[ "$OPERATION_ACTIVE" == 1 && "$OPERATION_COMMITTED" != 1 ]]; then
    ui_progress_update "$PROGRESS_CURRENT" "Recuperando a configuração anterior"
    if operation_rollback; then
      printf 'failed-restored\n' > "$STATE_DIR/operation-state"
      rm -rf -- "$OPERATION_DIR"
      ui_error "A operação falhou. A configuração anterior foi restaurada; os snapshots foram preservados."
    else
      printf 'partial\n' > "$STATE_DIR/operation-state"
      ui_error "Recuperação parcial. Os backups foram preservados. Use --recover e consulte /var/log/turbodecky.log."
    fi
  fi
  ui_progress_fail "Operação interrompida; consulte o resultado da recuperação" || true
  restore_steamos_readonly || status=1
  [[ -z "$OPERATION_LOCK_FD" ]] || eval "exec ${OPERATION_LOCK_FD}>&-"
  exit "$status"
}

operation_commit() {
  local kind="$1"
  if [[ "$kind" == revert ]]; then
    # Deletion is the last step, after files, services and runtime validate.
    : # Swapfile deletion is deferred until readonly restoration succeeds.
  else
    record_applied_files
    printf 'applied\n' > "$STATE_DIR/operation-state"
  fi
  restore_steamos_readonly || die "Não foi possível restaurar o modo readonly."
  if [[ "$kind" == revert || "$kind" == zram ]]; then finalize_swapfile_removal; fi
  if [[ "$kind" == revert ]]; then rm -rf -- "$STATE_DIR"; else rm -rf -- "$OPERATION_DIR"; fi
  OPERATION_COMMITTED=1
  OPERATION_ACTIVE=0
  trap - ERR INT TERM EXIT
  [[ -z "$OPERATION_LOCK_FD" ]] || eval "exec ${OPERATION_LOCK_FD}>&-"
  OPERATION_LOCK_FD=""
  ui_progress_finish "Operação concluída e verificada"
  cleanup_dry_run_sandbox
}

recover_operation() {
  require_root recover
  operation_lock
  OPERATION_DIR="$STATE_DIR/transaction"
  [[ -d "$OPERATION_DIR" ]] || { eval "exec ${OPERATION_LOCK_FD}>&-"; OPERATION_LOCK_FD=""; ui_info "Não há operação interrompida para recuperar."; return 0; }
  ui_progress_start "Recuperando a última operação" 100
  unlock_steamos
  trap restore_steamos_readonly EXIT
  operation_rollback || die "A recuperação continua parcial. Backups preservados."
  rm -rf -- "$OPERATION_DIR"
  printf 'failed-restored\n' > "$STATE_DIR/operation-state"
  restore_steamos_readonly || die "Falha ao restaurar readonly."
  ui_progress_finish "Configuração anterior recuperada"
  ui_info "Recuperação concluída. Reinicie o sistema."
}
