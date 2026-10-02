#!/usr/bin/env bash
# Dedicated backing swap. Never replace SteamOS/user /home/swapfile.
readonly TURBODECKY_SWAPFILE_BYTES=$((8 * 1024 * 1024 * 1024))
readonly TURBODECKY_SWAPFILE_MIN_FREE_BYTES=$((9 * 1024 * 1024 * 1024))

swapfile_resolved_path() {
  readlink -f -- "$1" 2>/dev/null || printf '%s\n' "$1"
}

managed_swapfile_target() { p /home/.swap/turbodecky.swap; }

swapfile_size_is_8g() {
  [[ -f "$1" ]] && [[ "$(stat -Lc '%s' -- "$1")" == "$TURBODECKY_SWAPFILE_BYTES" ]]
}

swapfile_has_swap_signature() {
  [[ "$(blkid -p -s TYPE -o value -- "$1" 2>/dev/null || true)" == swap ]]
}

swapfile_is_active() {
  local expected active
  expected="$(swapfile_resolved_path "$1")"
  while IFS= read -r active; do
    [[ "$(swapfile_resolved_path "$active")" == "$expected" ]] && return 0
  done < <(swapon --show=NAME --noheadings --raw 2>/dev/null)
  return 1
}

write_swapfile_fstab_entry() {
  backup_file_once "$FSTAB_FILE"
  {
    [[ ! -f "$FSTAB_FILE" ]] || awk -v path="$SWAPFILE" 'NF == 0 || $1 != path {print}' "$FSTAB_FILE"
    printf '%s none swap sw,pri=-2 0 0 # Turbo Decky\n' "$SWAPFILE"
  } | atomic_write "$FSTAB_FILE" 0644
}

remove_swapfile_fstab_entry() {
  [[ -f "$FSTAB_FILE" ]] || return 0
  backup_file_once "$FSTAB_FILE"
  awk -v path="$SWAPFILE" 'NF == 0 || $1 != path {print}' "$FSTAB_FILE" | atomic_write "$FSTAB_FILE" 0644
}

remove_existing_swapfile() {
  if [[ -z "$ROOTFS" && "$DRY_RUN" != 1 ]] && swapfile_is_active "$SWAPFILE"; then
    swapoff "$SWAPFILE" || return 1
    swapfile_is_active "$SWAPFILE" && return 1
  fi
  remove_swapfile_fstab_entry || return 1
  rm -f -- "$SWAPFILE"
}

# Keep the file until commit so failure recovery can reactivate it.
remove_created_swapfile() {
  [[ -f "$STATE_DIR/swapfile-created" ]] || return 0
  if [[ -z "$ROOTFS" && "$DRY_RUN" != 1 ]] && swapfile_is_active "$SWAPFILE"; then
    swapoff "$SWAPFILE" || die "Não foi possível desativar o swap gerenciado."
  fi
  remove_swapfile_fstab_entry
}

finalize_swapfile_removal() {
  [[ -f "$STATE_DIR/swapfile-created" || -f "$OPERATION_DIR/backups/$(printf '%s' "$STATE_DIR/swapfile-created" | sha256sum | awk '{print $1}')" ]] || return 0
  [[ -z "$ROOTFS" && "$DRY_RUN" != 1 ]] && swapfile_is_active "$SWAPFILE" && return 1
  rm -f -- "$SWAPFILE" "$STATE_DIR/swapfile-created"
}

activate_verified_swapfile() {
  if ! swapfile_is_active "$SWAPFILE"; then
    swapon --priority -2 "$SWAPFILE" || die "Não foi possível ativar o swap exclusivo do Turbo Decky."
  fi
  swapfile_is_active "$SWAPFILE" || die "O swap gerenciado não aparece como ativo."
  write_swapfile_fstab_entry
}

preflight_swapfile() {
  local command available
  for command in stat blkid findmnt mkswap swapon swapoff df fallocate; do
    command -v "$command" >/dev/null 2>&1 || die "Requisito para swap ausente: $command"
  done
  if [[ -e "$SWAPFILE" || -L "$SWAPFILE" ]]; then
    [[ ! -L "$SWAPFILE" && -f "$STATE_DIR/swapfile-created" ]] || die "Arquivo existente sem ownership em $SWAPFILE. Ele foi preservado."
    swapfile_size_is_8g "$SWAPFILE" && swapfile_has_swap_signature "$SWAPFILE" || die "Swap gerenciado inválido. Recupere a operação anterior antes de continuar."
  else
    available="$(df -B1 --output=avail /home | awk 'NR == 2 {print $1}')"
    [[ "$available" =~ ^[0-9]+$ ]] && (( available >= TURBODECKY_SWAPFILE_MIN_FREE_BYTES )) || \
      die "São necessários pelo menos 9 GiB livres em /home. Nenhum swap existente foi removido."
  fi
}

create_real_swapfile() {
  local fs
  mkdir -p "$(dirname "$SWAPFILE")"
  chmod 0700 "$(dirname "$SWAPFILE")"
  printf '1\n' > "$OPERATION_DIR/swap-created"
  fs="$(findmnt -n -o FSTYPE --target "$(dirname "$SWAPFILE")")"
  if [[ "$fs" == btrfs ]]; then
    command -v btrfs >/dev/null 2>&1 || die "btrfs é necessário para criar swap sem holes/CoW."
    btrfs filesystem mkswapfile --size 8G "$SWAPFILE"
  else
    # fallocate has no measurable byte progress; expose the current step.
    ui_progress_update 48 "Alocando 8 GiB para o swap; aguarde a conclusão desta etapa"
    fallocate -l "$TURBODECKY_SWAPFILE_BYTES" "$SWAPFILE"
    chmod 0600 "$SWAPFILE"
    mkswap "$SWAPFILE" >/dev/null
  fi
  chmod 0600 "$SWAPFILE"
  swapfile_size_is_8g "$SWAPFILE" || die "Tamanho do swap gerenciado incorreto."
  swapfile_has_swap_signature "$SWAPFILE" || die "Assinatura do swap gerenciado inválida."
  activate_verified_swapfile
  printf '1\n' > "$STATE_DIR/swapfile-created"
}

ensure_swapfile() {
  mkdir -p "$STATE_DIR" "$BACKUP_DIR" "$(dirname "$SWAPFILE")"
  if [[ -n "$ROOTFS" ]]; then
    if [[ -e "$SWAPFILE" && ! -f "$STATE_DIR/swapfile-created" ]]; then
      die "Arquivo de teste existente sem ownership; preservado."
    fi
    if [[ ! -e "$SWAPFILE" ]]; then
      [[ -z "$OPERATION_DIR" ]] || printf '1\n' > "$OPERATION_DIR/swap-created"
      truncate -s "$TURBODECKY_SWAPFILE_BYTES" "$SWAPFILE"
    fi
    chmod 0600 "$SWAPFILE"
    write_swapfile_fstab_entry
    printf '1\n' > "$STATE_DIR/swapfile-created"
    return 0
  fi
  preflight_swapfile
  if [[ -e "$SWAPFILE" ]]; then
    activate_verified_swapfile
  else
    create_real_swapfile
  fi
}
