#!/usr/bin/env bash
apply_runtime_profiles() {
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0
  sysctl -p "$SYSCTL_FILE"
  if command -v systemd-tmpfiles >/dev/null 2>&1; then
    systemd-tmpfiles --create --boot "$MEMORY_FILE"
  fi
  udevadm control --reload-rules
  udevadm trigger --subsystem-match=block --action=change
  verify_runtime_profiles
}

set_service_policy() {
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0
  local service
  for service in "${MANAGED_SERVICES[@]}"; do
    [[ "$(systemctl show -p LoadState --value "$service")" != not-found ]] || continue
    systemctl stop "$service"
    systemctl mask "$service"
  done
  [[ "$(systemctl show -p LoadState --value fstrim.timer)" == not-found ]] || systemctl enable --now fstrim.timer
}

validate_grub_format() {
  [[ -f "$GRUB_FILE" ]] || return 0
  python3 "$SCRIPT_DIR/lib/grub_config.py" "$GRUB_FILE" validate || die "GRUB incompatível; arquivo preservado."
}

update_grub_file() {
  local mode="$1" content
  [[ -f "$GRUB_FILE" ]] || { [[ -n "$ROOTFS" ]] && return 0; die "Arquivo GRUB não encontrado."; }
  validate_grub_format
  content="$(python3 "$SCRIPT_DIR/lib/grub_config.py" "$GRUB_FILE" "$mode")" || die "Falha ao preparar o GRUB."
  backup_file_once "$GRUB_FILE"
  printf '%s\n' "$content" | atomic_write "$GRUB_FILE" 0644
}

update_grub_runtime() {
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0
  local updated=0
  if command -v steamos-update-grub >/dev/null 2>&1; then
    steamos-update-grub
    updated=1
  elif command -v update-grub >/dev/null 2>&1; then
    update-grub
    updated=1
  elif command -v grub-mkconfig >/dev/null 2>&1; then
    if [[ -d /efi/EFI/steamos ]]; then
      grub-mkconfig -o /efi/EFI/steamos/grub.cfg
    else
      grub-mkconfig -o /boot/grub/grub.cfg
    fi
    updated=1
  fi

  # A system without a GRUB updater may use another bootloader, but if an
  # updater is present its failure must abort the operation. mkinitcpio is
  # optional because SteamOS kernels can ship their own initramfs hooks.
  (( updated == 1 )) || return 1
  if command -v mkinitcpio >/dev/null 2>&1; then
    mkinitcpio -P
  fi
}

write_zram_config() {
  backup_file_once "$ZRAM_FILE"
  cat <<'EOF_ZRAM' | atomic_write "$ZRAM_FILE" 0644
[zram0]
zram-size = ram * 1.5
compression-algorithm = lz4 zstd
swap-priority = 3000
options = discard
fs-type = swap
EOF_ZRAM
}

show_status() {
  local report status_file
  report="$(status_report)"
  detect_ui
  case "$UI_BACKEND" in
    yad)
      printf '%s\n' "$report" | yad --text-info --title="Diagnóstico Turbo Decky" \
        --width=820 --height=600 --fontname="monospace 10" 2>/dev/null || true
      ;;
    zenity)
      printf '%s\n' "$report" | zenity --text-info --title="Diagnóstico Turbo Decky" \
        --width=820 --height=600 2>/dev/null || true
      ;;
    kdialog)
      kdialog --title "Diagnóstico Turbo Decky" --textbox <(printf '%s\n' "$report") \
        820 600 2>/dev/null || true
      ;;
    dialog)
      status_file="$(mktemp /tmp/turbodecky-status.XXXXXX)"
      printf '%s\n' "$report" > "$status_file"
      dialog --title "Diagnóstico Turbo Decky" --textbox "$status_file" 28 100 \
        2>/dev/tty || true
      rm -f -- "$status_file"
      ;;
    *)
      printf '%s\n' "$report"
      ;;
  esac
}

verify_runtime_profiles() {
  local line key expected actual type path _mode _uid _gid _age value
  while IFS= read -r line; do
    [[ "$line" != \#* && "$line" == *=* ]] || continue
    key="${line%%=*}" expected="${line#*=}"
    actual="$(sysctl -n "$key")"
    [[ "$actual" == "$expected" ]] || die "Parâmetro não confirmado: $key (esperado $expected; atual $actual)."
  done < "$SYSCTL_FILE"
  while read -r type path _mode _uid _gid _age value; do
    [[ "$type" == w! ]] || continue
    actual="$(selector_value "$path")"
    # sysfs prints MGLRU's numeric bitmask as hexadecimal.
    if [[ "$value" =~ ^[0-9]+$ && "$actual" =~ ^0x[0-9a-fA-F]+$ ]]; then
      (( actual == value )) || die "Ajuste de memória não confirmado: $path"
    else
      [[ "$actual" == "$value" ]] || die "Ajuste de memória não confirmado: $path"
    fi
  done < "$MEMORY_FILE"
}
