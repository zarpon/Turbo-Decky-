#!/usr/bin/env bash
# Final memory-mode safety layer. This file is sourced after every compatibility
# and source-sync layer so ZRAM and ZSWAP remain mutually exclusive at runtime
# and across boots, while reversal restores the state captured before Turbo Decky.

ZSWAP_SYSFS_DIR="${TURBODECKY_ZSWAP_SYSFS_DIR:-/sys/module/zswap/parameters}"

write_runtime_value() {
  local file="$1" value="$2"
  [[ -w "$file" ]] || return 1
  printf '%s\n' "$value" > "$file"
}

disable_zswap_runtime() {
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0
  local enabled="$ZSWAP_SYSFS_DIR/enabled"
  [[ -e "$enabled" ]] || return 0
  write_runtime_value "$enabled" 0 || die "Não foi possível desativar o ZSWAP em runtime."
  case "$(cat "$enabled" 2>/dev/null || true)" in
    N|0) ;;
    *) die "O ZSWAP permaneceu ativo depois da tentativa de desativação." ;;
  esac
}


snapshot_runtime_once() {
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0
  [[ -f "$RUNTIME_SNAPSHOT" ]] && return 0
  mkdir -p "$STATE_DIR"
  local final_snapshot="$RUNTIME_SNAPSHOT"
  RUNTIME_SNAPSHOT="$(mktemp "$STATE_DIR/.runtime.XXXXXX")"

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

  # Preserve the block attributes actually changed by our udev rules.
  local device attribute
  for device in /sys/class/block/nvme*n* /sys/class/block/mmcblk* /sys/class/block/sd[a-z]; do
    [[ -d "$device/queue" ]] || continue
    for attribute in read_ahead_kb rotational add_random; do
      file="$device/queue/$attribute"
      [[ -r "$file" ]] || continue
      value="$(cat "$file")"
      printf 'sysfs\t%s\t%s\n' "$file" "$value" >> "$RUNTIME_SNAPSHOT"
    done
  done

  # Keep enabled last. During restore, ZSWAP is disabled first, parameters are
  # restored, and its original enabled state is written only at the end.
  # Keep zpool only for restoring snapshots made by older releases. It is not
  # part of the current apply path because modern kernels do not expose it.
  for relative in compressor max_pool_percent zpool shrinker_enabled enabled; do
    file="$ZSWAP_SYSFS_DIR/$relative"
    [[ -r "$file" ]] || continue
    value="$(cat "$file" 2>/dev/null || true)"
    [[ -n "$value" ]] && printf 'sysfs\t%s\t%s\n' "$file" "$value" >> "$RUNTIME_SNAPSHOT"
  done
  mv -f -- "$RUNTIME_SNAPSHOT" "$final_snapshot"
  RUNTIME_SNAPSHOT="$final_snapshot"
}

restore_runtime() {
  [[ -f "$RUNTIME_SNAPSHOT" ]] || return 0
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0

  # If ZSWAP parameters were captured, turn it off before restoring mutable
  # compressor/pool-limit values. Its saved enabled value is the final snapshot row.
  if grep -Fq $'sysfs\t'"$ZSWAP_SYSFS_DIR/" "$RUNTIME_SNAPSHOT" 2>/dev/null; then
    write_runtime_value "$ZSWAP_SYSFS_DIR/enabled" 0 || true
  fi

  local type key value
  while IFS=$'\t' read -r type key value; do
    case "$type" in
      sysctl) sysctl -q -w "$key=$value" || return 1 ;;
      sysfs) write_runtime_value "$key" "$value" || return 1 ;;
    esac
  done < "$RUNTIME_SNAPSHOT"
}

restore_services() {
  [[ -f "$SERVICE_SNAPSHOT" ]] || return 0
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0

  local service enabled active
  while IFS=$'\t' read -r service enabled active; do
    if [[ "$enabled" == masked-runtime ]]; then
      systemctl mask --runtime "$service" || return 1
    elif [[ "$enabled" == masked ]]; then
      systemctl mask "$service" || return 1
    else
      # static/generated/indirect units cannot be enabled, but they still must
      # be unmasked because Turbo Decky may have masked them for ZSWAP.
      systemctl unmask "$service" || return 1
      systemctl unmask --runtime "$service" || return 1
      case "$enabled" in
        enabled|linked|alias)
          systemctl enable "$service" || return 1
          ;;
        enabled-runtime|linked-runtime)
          systemctl disable "$service" || return 1
          systemctl enable --runtime "$service" || return 1
          ;;
        disabled|not-found)
          [[ "$enabled" == not-found ]] || systemctl disable "$service" || return 1
          ;;
      esac
    fi

    if [[ "$active" == active ]]; then
      systemctl start "$service" || return 1
    else
      [[ "$enabled" == not-found ]] || systemctl stop "$service" || return 1
    fi
  done < "$SERVICE_SNAPSHOT"
}

legacy_file_owned() {
  local file="$1"
  [[ "$file" == "$(p /var/lib/turbodecky/)"* ]] ||
    { [[ -f "$file" ]] && grep -Eiq 'Turbo[ -]?Decky|Turbo Decky|charcoaltd' "$file"; }
}

cleanup_legacy_installation() {
  local file service
  # Generic filenames are never evidence of ownership. Snapshot first.
  for file in "${LEGACY_GENERATED_FILES[@]}" "${LEGACY_RECOMPRESSION_FILES[@]}"; do
    file="$(p "$file")"
    [[ "$file" != "$ZRAM_FILE" ]] || continue
    [[ -e "$file" || -L "$file" ]] || continue
    legacy_file_owned "$file" || { log "arquivo externo preservado: $file"; continue; }
    backup_file_once "$file"
    if [[ -n "${OPERATION_DIR:-}" ]]; then
      local old_manifest="$FILE_MANIFEST" old_backup="$BACKUP_DIR"
      FILE_MANIFEST="$OPERATION_DIR/files.tsv" BACKUP_DIR="$OPERATION_DIR/backups"
      backup_file_once "$file"
      FILE_MANIFEST="$old_manifest" BACKUP_DIR="$old_backup"
    fi
    if [[ -z "$ROOTFS" && "$DRY_RUN" != 1 && "$file" == /etc/systemd/system/* ]]; then
      service="${file##*/}"
      systemctl disable --now "$service" || die "Não foi possível desativar o serviço legado: $service"
    fi
    rm -f -- "$file"
  done
  if [[ -z "$ROOTFS" && "$DRY_RUN" != 1 ]]; then systemctl daemon-reload; fi
}

zram_runtime_devices() {
  local device
  if command -v swapon >/dev/null 2>&1; then
    if swapon --show=NAME --noheadings --raw 2>/dev/null | while IFS= read -r device; do
      if [[ "$device" =~ (^|/)zram[0-9]+$ ]]; then
        printf '%s\n' "$device"
      fi
    done; then
      return 0
    fi
  fi
  if command -v zramctl >/dev/null 2>&1; then
    zramctl --noheadings --output NAME 2>/dev/null | while IFS= read -r device; do
      if [[ "$device" =~ (^|/)zram[0-9]+$ ]]; then
        printf '%s\n' "$device"
      fi
    done
  fi
}

zram_runtime_active() {
  [[ -n "$(zram_runtime_devices)" ]]
}

remove_managed_zram() {
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0
  # Masking is required: stopping alone allows the generator-created unit to
  # return on the next boot when a vendor ZRAM configuration still exists.
  systemctl mask --now systemd-zram-setup@zram0.service 2>/dev/null || \
    die "Não foi possível mascarar e parar a ZRAM antes de ativar o ZSWAP."
  if zram_runtime_active; then
    while IFS= read -r device; do
      [[ -n "$device" ]] || continue
      swapoff "$device" 2>/dev/null || true
    done < <(zram_runtime_devices)
    zram_runtime_active && die "A ZRAM permaneceu ativa depois da tentativa de desativação."
  fi
}

activate_zram() {
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0
  disable_zswap_runtime
  systemctl daemon-reload || die "Não foi possível recarregar as unidades da ZRAM."
  systemctl unmask systemd-zram-setup@zram0.service || \
    die "Não foi possível liberar a unidade da ZRAM."
  systemctl restart systemd-zram-setup@zram0.service || \
    die "Não foi possível ativar a ZRAM em runtime."
  systemctl is-active --quiet systemd-zram-setup@zram0.service || \
    die "A unidade da ZRAM não ficou ativa após a reinicialização."
  swapon --show=NAME --noheadings --raw | grep -Fxq /dev/zram0 || \
    die "A unidade ZRAM está ativa, mas /dev/zram0 não aparece como swap."
}
