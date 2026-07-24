apply_runtime_profiles() {
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0
  sysctl --system
  if command -v systemd-tmpfiles >/dev/null 2>&1; then
    systemd-tmpfiles --create --boot "$(basename "$MEMORY_FILE")" 2>/dev/null || systemd-tmpfiles --create --boot || true
  fi
  udevadm control --reload-rules 2>/dev/null || true
  udevadm trigger --subsystem-match=block --action=change 2>/dev/null || true
}

set_service_policy() {
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0
  local service
  for service in "${MANAGED_SERVICES[@]}"; do
    systemctl stop "$service" 2>/dev/null || true
    systemctl mask "$service" 2>/dev/null || true
  done
  systemctl enable --now fstrim.timer 2>/dev/null || true
}

update_grub_file() {
  local mode="$1"
  [[ -f "$GRUB_FILE" ]] || return 0
  backup_file_once "$GRUB_FILE"
  python3 - "$GRUB_FILE" "$mode" <<'PY'
from pathlib import Path
import re
import shlex
import sys

path = Path(sys.argv[1])
mode = sys.argv[2]
text = path.read_text(encoding="utf-8")
match = re.search(r'^GRUB_CMDLINE_LINUX="([^"]*)"', text, flags=re.M)
current = shlex.split(match.group(1)) if match else []
keys = {
    "zswap.enabled", "zswap.compressor", "zswap.max_pool_percent",
    "zswap.zpool", "zswap.shrinker_enabled", "mitigations", "audit",
    "nmi_watchdog", "nowatchdog", "split_lock_detect",
}

def token_key(token: str) -> str:
    return token.split("=", 1)[0]

current = [token for token in current if token_key(token) not in keys]
common = ["mitigations=off", "audit=0", "nmi_watchdog=0", "nowatchdog", "split_lock_detect=off"]
if mode == "zswap":
    common[:0] = [
        "zswap.enabled=1", "zswap.compressor=lz4",
        "zswap.max_pool_percent=35", "zswap.zpool=zsmalloc",
        "zswap.shrinker_enabled=1",
    ]
elif mode == "zram":
    common.insert(0, "zswap.enabled=0")
new_line = 'GRUB_CMDLINE_LINUX="' + " ".join(current + common) + '"'
if match:
    text = text[:match.start()] + new_line + text[match.end():]
else:
    text += ("\n" if text and not text.endswith("\n") else "") + new_line + "\n"
path.write_text(text, encoding="utf-8")
PY
}

update_grub_runtime() {
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0
  if command -v steamos-update-grub >/dev/null 2>&1; then
    steamos-update-grub
  elif command -v update-grub >/dev/null 2>&1; then
    update-grub
  elif command -v grub-mkconfig >/dev/null 2>&1; then
    if [[ -d /efi/EFI/steamos ]]; then
      grub-mkconfig -o /efi/EFI/steamos/grub.cfg
    else
      grub-mkconfig -o /boot/grub/grub.cfg
    fi
  fi
  command -v mkinitcpio >/dev/null 2>&1 && mkinitcpio -P || true
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

activate_zram() {
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0
  systemctl daemon-reload
  systemctl unmask systemd-zram-setup@zram0.service 2>/dev/null || true
  systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || true
}

remove_managed_zram() {
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0
  systemctl stop systemd-zram-setup@zram0.service 2>/dev/null || true
}

ensure_swapfile() {
  [[ -n "$ROOTFS" ]] && { touch "$SWAPFILE"; return 0; }
  if [[ -e "$SWAPFILE" || -L "$SWAPFILE" ]]; then
    log "swapfile existente preservado: $SWAPFILE"
    return 0
  fi
  local free_gb fs actual
  free_gb="$(df -BG /home | awk 'NR==2 {gsub(/G/,"",$4); print $4+0}')"
  (( free_gb >= 9 )) || die "São necessários pelo menos 9 GiB livres em /home para o perfil ZSWAP."
  backup_file_once "$FSTAB_FILE"
  fs="$(findmnt -n -o FSTYPE --target /home 2>/dev/null || true)"
  if [[ "$fs" == btrfs ]]; then
    mkdir -p /home/.swap
    chattr +C /home/.swap 2>/dev/null || true
    actual=/home/.swap/turbodecky.swap
    if command -v btrfs >/dev/null 2>&1 && btrfs filesystem mkswapfile --size 8G "$actual" 2>/dev/null; then
      :
    else
      truncate -s 0 "$actual"
      chattr +C "$actual" 2>/dev/null || true
      fallocate -l 8G "$actual"
      chmod 600 "$actual"
      mkswap "$actual"
    fi
    ln -s "$actual" "$SWAPFILE"
  else
    fallocate -l 8G "$SWAPFILE" || dd if=/dev/zero of="$SWAPFILE" bs=1M count=8192 status=progress
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE"
  fi
  printf '1\n' > "$STATE_DIR/swapfile-created"
  sed -i "\\|$SWAPFILE|d" "$FSTAB_FILE" 2>/dev/null || true
  printf '%s none swap sw,pri=-2 0 0\n' "$SWAPFILE" >> "$FSTAB_FILE"
  swapon --priority -2 "$SWAPFILE"
}

remove_created_swapfile() {
  [[ -f "$STATE_DIR/swapfile-created" ]] || return 0
  [[ -n "$ROOTFS" ]] && { rm -f "$SWAPFILE"; return 0; }
  swapoff "$SWAPFILE" 2>/dev/null || true
  if [[ -L "$SWAPFILE" ]]; then
    local target
    target="$(readlink -f "$SWAPFILE" || true)"
    rm -f "$SWAPFILE"
    [[ "$target" == /home/.swap/turbodecky.swap ]] && rm -f "$target"
  else
    rm -f "$SWAPFILE"
  fi
}

prepare_apply() {
  require_root "$@"
  unlock_steamos
  trap restore_steamos_readonly EXIT
  mkdir -p "$STATE_DIR" "$BACKUP_DIR"
  snapshot_runtime_once
  snapshot_services_once
  cleanup_legacy_recompression
  write_charcoal_sysctl
  write_charcoal_memory
  write_common_files
  set_service_policy
}

apply_zram_profile() {
  prepare_apply zram
  remove_created_swapfile
  write_zram_config
  update_grub_file zram
  apply_runtime_profiles
  activate_zram
  update_grub_runtime
  printf 'zram\n' > "$PROFILE_STATE"
  log "perfil ZRAM aplicado"
  ui_info "Perfil ZRAM aplicado. LZ4/ZSTD permanecem somente como lista padrão do zram-generator; não há timer, serviço ou rotina de recompressão. Reinicie o sistema."
}

apply_zswap_profile() {
  prepare_apply zswap
  remove_managed_zram
  backup_file_once "$ZRAM_FILE"
  rm -f "$ZRAM_FILE"
  ensure_swapfile
  update_grub_file zswap
  apply_runtime_profiles
  update_grub_runtime
  printf 'zswap\n' > "$PROFILE_STATE"
  log "perfil ZSWAP aplicado"
  ui_info "Perfil ZSWAP aplicado com o mesmo sysctl/THP do linux-charcoal-vulcano. Reinicie o sistema."
}

status_report() {
  local profile="não aplicado" lines=()
  [[ -f "$PROFILE_STATE" ]] && profile="$(cat "$PROFILE_STATE")"
  lines+=("Turbo Decky: $TURBODECKY_VERSION" "Perfil gerenciado: $profile")
  if [[ -z "$ROOTFS" ]]; then
    lines+=("Kernel: $(uname -r)")
    if command -v zramctl >/dev/null 2>&1; then
      lines+=("ZRAM: $(zramctl --noheadings --output NAME,ALGORITHM,DISKSIZE,DATA,COMPR 2>/dev/null | xargs || echo inativo)")
    fi
    local pair key value
    for pair in "${CHARCOAL_SYSCTL[@]}"; do
      key="${pair%%=*}"
      value="$(sysctl -n "$key" 2>/dev/null || echo indisponível)"
      lines+=("$key=$value")
    done
    local file
    for file in enabled defrag shmem_enabled khugepaged/defrag khugepaged/max_ptes_none khugepaged/max_ptes_swap; do
      value="$(selector_value "/sys/kernel/mm/transparent_hugepage/$file" 2>/dev/null || echo indisponível)"
      lines+=("THP $file=$value")
    done
  else
    lines+=("Root de teste: $ROOTFS")
  fi
  printf '%s\n' "${lines[@]}"
}

show_status() {
  local report
  report="$(status_report)"
  detect_ui
  case "$UI_BACKEND" in
    yad) printf '%s\n' "$report" | yad --text-info --title="Diagnóstico Turbo Decky" --width=820 --height=600 --fontname="monospace 10" 2>/dev/null || true ;;
    zenity) printf '%s\n' "$report" | zenity --text-info --title="Diagnóstico Turbo Decky" --width=820 --height=600 2>/dev/null || true ;;
    kdialog) kdialog --title "Diagnóstico Turbo Decky" --textbox <(printf '%s\n' "$report") 820 600 2>/dev/null || true ;;
    dialog) printf '%s\n' "$report" > /tmp/turbodecky-status.$$; dialog --title "Diagnóstico Turbo Decky" --textbox /tmp/turbodecky-status.$$ 28 100 2>/dev/tty || true; rm -f /tmp/turbodecky-status.$$ ;;
    *) printf '%s\n' "$report" ;;
  esac
}

revert_all() {
  require_root revert
  ui_confirm "A reversão restaurará os arquivos e estados capturados antes da primeira aplicação. Continuar?" || return 0
  unlock_steamos
  trap restore_steamos_readonly EXIT
  cleanup_legacy_recompression
  remove_managed_zram
  remove_created_swapfile
  restore_files
  restore_runtime
  if [[ -z "$ROOTFS" && "$DRY_RUN" != 1 ]]; then
    systemctl daemon-reload 2>/dev/null || true
    restore_services
    sysctl --system 2>/dev/null || true
    udevadm control --reload-rules 2>/dev/null || true
    swapon -a 2>/dev/null || true
    update_grub_runtime
  fi
  rm -rf "$STATE_DIR"
  log "reversão concluída"
  ui_info "Reversão concluída. Os arquivos e estados anteriores foram restaurados quando havia snapshot disponível. Reinicie o sistema."
}
