apply_runtime_profiles() {
  [[ -n "$ROOTFS" || "$DRY_RUN" == 1 ]] && return 0
  sysctl --system
  if command -v systemd-tmpfiles >/dev/null 2>&1; then
    systemd-tmpfiles --create --boot "$MEMORY_FILE" 2>/dev/null || \
      systemd-tmpfiles --create --boot || true
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
  command -v python3 >/dev/null 2>&1 || die "python3 é necessário para atualizar o GRUB."
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
else:
    raise SystemExit(f"modo de GRUB inválido: {mode}")

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
  (( updated == 1 )) || log "Nenhum atualizador de GRUB foi encontrado; o arquivo foi alterado, mas o bootloader não foi regenerado."
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
