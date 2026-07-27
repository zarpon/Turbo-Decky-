#!/usr/bin/env bash
# Final swapfile safety layer. The older implementation accepted any existing
# /home/swapfile, including empty files and broken links, and ignored swapon
# failures. This override guarantees a real, active 8 GiB backing swap.

readonly TURBODECKY_SWAPFILE_BYTES=$((8 * 1024 * 1024 * 1024))
readonly TURBODECKY_SWAPFILE_MIN_FREE_BYTES=$((9 * 1024 * 1024 * 1024))

swapfile_resolved_path() {
  local path="$1"
  if [[ -L "$path" ]]; then
    readlink -f -- "$path" 2>/dev/null
  else
    printf '%s\n' "$path"
  fi
}

managed_swapfile_target() {
  p /home/.swap/turbodecky.swap
}

swapfile_size_is_8g() {
  local path="$1" size
  [[ -f "$path" ]] || return 1
  size="$(stat -Lc '%s' -- "$path" 2>/dev/null || printf '0')"
  [[ "$size" == "$TURBODECKY_SWAPFILE_BYTES" ]]
}

swapfile_has_swap_signature() {
  local path="$1"
  command -v blkid >/dev/null 2>&1 || return 1
  [[ "$(blkid -p -s TYPE -o value -- "$path" 2>/dev/null || true)" == swap ]]
}

swapfile_is_active() {
  local path="$1" expected active resolved
  expected="$(swapfile_resolved_path "$path" 2>/dev/null || printf '%s' "$path")"
  while IFS= read -r active; do
    [[ -n "$active" ]] || continue
    resolved="$(readlink -f -- "$active" 2>/dev/null || printf '%s' "$active")"
    [[ "$resolved" == "$expected" ]] && return 0
  done < <(swapon --show=NAME --noheadings --raw 2>/dev/null || true)
  return 1
}

write_swapfile_fstab_entry() {
  backup_file_once "$FSTAB_FILE"
  mkdir -p "$(dirname "$FSTAB_FILE")"
  {
    if [[ -f "$FSTAB_FILE" ]]; then
      awk -v path="$SWAPFILE" 'NF > 0 && $1 == path { next } { print }' "$FSTAB_FILE"
    fi
    printf '%s none swap sw,pri=-2 0 0\n' "$SWAPFILE"
  } | atomic_write "$FSTAB_FILE" 0644
}

remove_swapfile_fstab_entry() {
  [[ -f "$FSTAB_FILE" ]] || return 0
  backup_file_once "$FSTAB_FILE"
  awk -v path="$SWAPFILE" 'NF == 0 || $1 != path { print }' "$FSTAB_FILE" |
    atomic_write "$FSTAB_FILE" 0644
}

remove_existing_swapfile() {
  local actual=""
  actual="$(swapfile_resolved_path "$SWAPFILE" 2>/dev/null || true)"

  # An existing swapfile may be active even when its size or signature is
  # wrong for this profile. Never unlink an active swapfile until swapoff has
  # succeeded and the kernel no longer reports it in swapon --show.
  if [[ -z "$ROOTFS" && "$DRY_RUN" != 1 ]] &&
     command -v swapon >/dev/null 2>&1 && command -v swapoff >/dev/null 2>&1; then
    if swapfile_is_active "$SWAPFILE"; then
      swapoff "$SWAPFILE" 2>/dev/null || true
      if swapfile_is_active "$SWAPFILE" &&
         [[ -n "$actual" && "$actual" != "$SWAPFILE" ]]; then
        swapoff "$actual" 2>/dev/null || true
      fi
      swapfile_is_active "$SWAPFILE" &&
        die "Não foi possível desativar o swapfile existente em $SWAPFILE."
    fi
  fi

  # Do not leave a boot-time entry pointing to the file while it is being
  # replaced. A fresh entry is written only after the new swapfile validates.
  remove_swapfile_fstab_entry
  rm -f -- "$SWAPFILE"
  if [[ "$actual" == "$(managed_swapfile_target)" ]]; then
    rm -f -- "$actual"
  fi
}

remove_created_swapfile() {
  [[ -f "$STATE_DIR/swapfile-created" ]] || return 0
  remove_existing_swapfile
  rm -f -- "$STATE_DIR/swapfile-created"
}

activate_verified_swapfile() {
  write_swapfile_fstab_entry
  if ! swapfile_is_active "$SWAPFILE"; then
    swapon --priority -2 "$SWAPFILE" || die "Não foi possível ativar o swapfile de 8 GiB em $SWAPFILE."
  fi
  swapfile_is_active "$SWAPFILE" || die "O swapfile foi criado, mas não aparece como ativo."
}

create_real_swapfile() {
  local fs actual available
  available="$(df -B1 --output=avail /home 2>/dev/null | awk 'NR == 2 {print $1+0}')"
  [[ "$available" =~ ^[0-9]+$ ]] || die "Não foi possível verificar o espaço livre em /home."
  (( available >= TURBODECKY_SWAPFILE_MIN_FREE_BYTES )) || \
    die "São necessários pelo menos 9 GiB livres em /home para criar o swapfile de 8 GiB."

  fs="$(findmnt -n -o FSTYPE --target /home 2>/dev/null || true)"
  if [[ "$fs" == btrfs ]]; then
    actual=/home/.swap/turbodecky.swap
    mkdir -p /home/.swap
    chattr +C /home/.swap 2>/dev/null || true
    rm -f -- "$actual" "$SWAPFILE"
    if command -v btrfs >/dev/null 2>&1 && \
       btrfs filesystem mkswapfile --size 8G "$actual" >/dev/null 2>&1; then
      :
    else
      touch "$actual"
      chattr +C "$actual" 2>/dev/null || true
      truncate -s 0 "$actual"
      fallocate -l "$TURBODECKY_SWAPFILE_BYTES" "$actual" || \
        dd if=/dev/zero of="$actual" bs=1M count=8192 status=progress
    fi
    chmod 600 "$actual"
    mkswap "$actual" >/dev/null
    ln -s "$actual" "$SWAPFILE"
  else
    actual="$SWAPFILE"
    rm -f -- "$actual"
    fallocate -l "$TURBODECKY_SWAPFILE_BYTES" "$actual" || \
      dd if=/dev/zero of="$actual" bs=1M count=8192 status=progress
    chmod 600 "$actual"
    mkswap "$actual" >/dev/null
  fi

  swapfile_size_is_8g "$SWAPFILE" || {
    remove_existing_swapfile
    die "O arquivo criado não possui exatamente 8 GiB."
  }
  swapfile_has_swap_signature "$SWAPFILE" || {
    remove_existing_swapfile
    die "O arquivo criado não possui uma assinatura swap válida."
  }
  activate_verified_swapfile
  printf '1\n' > "$STATE_DIR/swapfile-created"
  log "swapfile de 8 GiB criado e ativo em $SWAPFILE"
}

ensure_swapfile() {
  mkdir -p "$STATE_DIR" "$BACKUP_DIR" "$(dirname "$SWAPFILE")"

  # Isolated-root tests model persistence without allocating physical blocks or
  # calling swapon. The apparent file size must still be exactly 8 GiB.
  if [[ -n "$ROOTFS" ]]; then
    truncate -s "$TURBODECKY_SWAPFILE_BYTES" "$SWAPFILE"
    chmod 600 "$SWAPFILE"
    write_swapfile_fstab_entry
    printf '1\n' > "$STATE_DIR/swapfile-created"
    return 0
  fi

  [[ "$DRY_RUN" != 1 ]] || {
    log "DRY-RUN: criaria e validaria um swapfile de 8 GiB em $SWAPFILE"
    return 0
  }

  for command in stat blkid findmnt mkswap swapon swapoff; do
    command -v "$command" >/dev/null 2>&1 || die "Comando obrigatório ausente para criar o swapfile: $command"
  done

  if [[ -e "$SWAPFILE" || -L "$SWAPFILE" ]]; then
    if swapfile_size_is_8g "$SWAPFILE" && swapfile_has_swap_signature "$SWAPFILE"; then
      chmod 600 "$SWAPFILE" 2>/dev/null || true
      activate_verified_swapfile
      log "swapfile existente de 8 GiB validado e ativo: $SWAPFILE"
      return 0
    fi

    log "swapfile existente inválido ou com tamanho diferente; removendo e recriando com 8 GiB"
    remove_existing_swapfile
  fi

  create_real_swapfile
}
