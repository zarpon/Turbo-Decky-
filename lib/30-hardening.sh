#!/usr/bin/env bash
# Compatibility cleanup and safety layer. Sourced last so upgrades from older
# Turbo Decky releases are normalized before a new profile is applied.

: "${KERNEL_TMP_DIR:=}"

if ! declare -p LEGACY_GENERATED_FILES >/dev/null 2>&1; then
LEGACY_GENERATED_FILES=(
  "/etc/systemd/system/zswap-config.service"
  "/etc/systemd/system/zram-config.service"
  "/etc/systemd/system/mglru-tune.service"
  "/etc/systemd/system/thp-config.service"
  "/etc/systemd/system/io-boost@.service"
  "/etc/systemd/system/turbodecky-power-monitor.service"
  "/etc/tmpfiles.d/TdMemoryTweak.conf"
  "/etc/tmpfiles.d/mglru.conf"
  "/etc/tmpfiles.d/thp_shrinker.conf"
  "/etc/tmpfiles.d/custom-timers.conf"
  "/etc/security/limits.d/99-game-limits.conf"
  "/etc/modprobe.d/amdgpu.conf"
  "/etc/modprobe.d/99-amdgpu-tuning.conf"
  "/etc/modules-load.d/ntsync.conf"
  "/etc/udev/rules.d/99-turbodecky-power.rules"
  "/etc/udev/rules.d/99-io-boost.rules"
  "/etc/systemd/zram-generator.conf.d/00-turbodecky.conf"
  "/var/lib/turbodecky/bin/zswap-config.sh"
  "/var/lib/turbodecky/bin/zram-config.sh"
  "/var/lib/turbodecky/bin/io-boost.sh"
  "/var/lib/turbodecky/bin/turbodecky-power-monitor.sh"
  "/var/lib/turbodecky/bin/thp-config.sh"
  "/usr/local/bin/zswap-config.sh"
  "/usr/local/bin/zram-config.sh"
  "/usr/local/bin/io-boost.sh"
  "/usr/local/bin/turbodecky-power-monitor.sh"
)
readonly LEGACY_GENERATED_FILES
fi

restore_files () 
{ 
    [[ -f "$FILE_MANIFEST" ]] || return 0;
    local file backup existed;
    while IFS='	' read -r file backup existed; do
        [[ -n "$file" ]] || continue;
        case "$file" in 
            "$(p /etc/)"* | "$(p /var/lib/turbodecky/)"*)

            ;;
            *)
                log "snapshot ignorado por caminho não gerenciado: $file";
                continue
            ;;
        esac;
        rm -rf -- "$file";
        if [[ "$existed" == 1 && -e "$backup" ]]; then
            mkdir -p "$(dirname "$file")";
            cp -a "$backup" "$file";
        fi;
    done < "$FILE_MANIFEST"
}

restore_legacy_backup () 
{ 
    local target="$1" backup="${1}.bak-turbodecky";
    if [[ -e "$backup" || -L "$backup" ]]; then
        rm -rf -- "$target";
        mv -- "$backup" "$target";
        log "backup legado restaurado: $target";
        return 0;
    fi;
    return 1
}

cleanup_legacy_installation () 
{ 
    local file;
    cleanup_legacy_recompression;
    if [[ -z "$ROOTFS" && "$DRY_RUN" != 1 ]] && command -v systemctl > /dev/null 2>&1; then
        systemctl disable --now zswap-config.service zram-config.service mglru-tune.service thp-config.service turbodecky-power-monitor.service 2> /dev/null || true;
    fi;
    restore_legacy_backup "$(p /etc/fstab)" || true;
    restore_legacy_backup "$(p /etc/default/grub)" || true;
    restore_legacy_backup "$(p /etc/sysctl.d/99-sdweak-performance.conf)" || rm -f -- "$(p /etc/sysctl.d/99-sdweak-performance.conf)";
    restore_legacy_backup "$(p /usr/lib/systemd/zram-generator.conf)" || true;
    for file in "${LEGACY_GENERATED_FILES[@]}";
    do
        rm -rf -- "$(p "$file")";
    done;
    rm -f -- "$(p /etc/environment.d/)"turbodecky*.conf 2> /dev/null || true;
    if [[ -z "$ROOTFS" && "$DRY_RUN" != 1 ]] && command -v systemctl > /dev/null 2>&1; then
        systemctl daemon-reload 2> /dev/null || true;
        systemctl unmask systemd-zram-setup@zram0.service 2> /dev/null || true;
    fi
}

write_common_files () 
{ 
    backup_file_once "$LIMITS_FILE";
    cat <<'EOF_LIMITS' |
* soft nofile 524288
* hard nofile 524288
root soft nofile 524288
root hard nofile 524288
EOF_LIMITS
  atomic_write "$LIMITS_FILE" 0644
    backup_file_once "$ENV_FILE";
    cat <<'EOF_ENV' |
MESA_SHADER_CACHE_MAX_SIZE=10G
MESA_DISK_CACHE_DATABASE=1
EOF_ENV
  atomic_write "$ENV_FILE" 0644
    backup_file_once "$UDEV_FILE";
    cat <<'EOF_UDEV' |
# Turbo Decky: ajustes conservadores, sem substituir o scheduler do kernel.
ACTION=="add|change", KERNEL=="nvme*n*", ATTR{queue/read_ahead_kb}="512", ATTR{queue/rotational}="0", ATTR{queue/iostats}="0", ATTR{queue/add_random}="0"
ACTION=="add|change", KERNEL=="mmcblk*", ATTR{queue/read_ahead_kb}="1024", ATTR{queue/rotational}="0", ATTR{queue/iostats}="0", ATTR{queue/add_random}="0"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/iostats}="0", ATTR{queue/add_random}="0"
EOF_UDEV
  atomic_write "$UDEV_FILE" 0644
}

ensure_swapfile () 
{ 
    if [[ -n "$ROOTFS" ]]; then
        mkdir -p "$(dirname "$SWAPFILE")";
        touch "$SWAPFILE";
        printf '1\n' > "$STATE_DIR/swapfile-created";
        return 0;
    fi;
    if [[ -e "$SWAPFILE" || -L "$SWAPFILE" ]]; then
        log "swapfile existente preservado: $SWAPFILE";
        backup_file_once "$FSTAB_FILE";
        grep -Fq "$SWAPFILE" "$FSTAB_FILE" 2> /dev/null || printf '%s none swap sw,pri=-2 0 0\n' "$SWAPFILE" >> "$FSTAB_FILE";
        swapon --show=NAME 2> /dev/null | grep -Fqx "$SWAPFILE" || swapon --priority -2 "$SWAPFILE" 2> /dev/null || true;
        return 0;
    fi;
    local free_gb fs actual;
    free_gb="$(df -BG /home | awk 'NR==2 {gsub(/G/,"",$4); print $4+0}')";
    (( free_gb >= 9 )) || die "São necessários pelo menos 9 GiB livres em /home para o perfil ZSWAP.";
    backup_file_once "$FSTAB_FILE";
    fs="$(findmnt -n -o FSTYPE --target /home 2> /dev/null || true)";
    if [[ "$fs" == btrfs ]]; then
        mkdir -p /home/.swap;
        chattr +C /home/.swap 2> /dev/null || true;
        actual=/home/.swap/turbodecky.swap;
        if command -v btrfs > /dev/null 2>&1 && btrfs filesystem mkswapfile --size 8G "$actual" 2> /dev/null; then
            :;
        else
            truncate -s 0 "$actual";
            chattr +C "$actual" 2> /dev/null || true;
            fallocate -l 8G "$actual";
            chmod 600 "$actual";
            mkswap "$actual";
        fi;
        ln -s "$actual" "$SWAPFILE";
    else
        fallocate -l 8G "$SWAPFILE" || dd if=/dev/zero of="$SWAPFILE" bs=1M count=8192 status=progress;
        chmod 600 "$SWAPFILE";
        mkswap "$SWAPFILE";
    fi;
    printf '1\n' > "$STATE_DIR/swapfile-created";
    sed -i "\\|$SWAPFILE|d" "$FSTAB_FILE" 2> /dev/null || true;
    printf '%s none swap sw,pri=-2 0 0\n' "$SWAPFILE" >> "$FSTAB_FILE";
    swapon --priority -2 "$SWAPFILE"
}

remove_created_swapfile () 
{ 
    [[ -f "$STATE_DIR/swapfile-created" ]] || return 0;
    if [[ -f "$FSTAB_FILE" ]]; then
        sed -i "\|$SWAPFILE|d" "$FSTAB_FILE" 2> /dev/null || true;
    fi;
    if [[ -n "$ROOTFS" ]]; then
        rm -f "$SWAPFILE" "$STATE_DIR/swapfile-created";
        return 0;
    fi;
    swapoff "$SWAPFILE" 2> /dev/null || true;
    if [[ -L "$SWAPFILE" ]]; then
        local target;
        target="$(readlink -f "$SWAPFILE" || true)";
        rm -f "$SWAPFILE";
        [[ "$target" == /home/.swap/turbodecky.swap ]] && rm -f "$target";
    else
        rm -f "$SWAPFILE";
    fi;
    rm -f "$STATE_DIR/swapfile-created"
}

prepare_apply () 
{ 
    require_root "$@";
    unlock_steamos;
    trap restore_steamos_readonly EXIT;
    cleanup_legacy_installation;
    mkdir -p "$STATE_DIR" "$BACKUP_DIR";
    snapshot_runtime_once;
    snapshot_services_once;
    cleanup_legacy_recompression;
    write_charcoal_sysctl;
    write_charcoal_memory;
    write_common_files;
    set_service_policy
}

revert_all () 
{ 
    require_root revert;
    ui_confirm "A reversão restaurará os arquivos e estados capturados antes da primeira aplicação. Continuar?" || return 0;
    unlock_steamos;
    trap restore_steamos_readonly EXIT;
    cleanup_legacy_installation;
    remove_managed_zram;
    remove_created_swapfile;
    restore_files;
    if [[ -z "$ROOTFS" && "$DRY_RUN" != 1 ]]; then
        systemctl daemon-reload 2> /dev/null || true;
        restore_services;
        sysctl --system 2> /dev/null || true;
        udevadm control --reload-rules 2> /dev/null || true;
        swapon -a 2> /dev/null || true;
        update_grub_runtime;
    fi;
    restore_runtime;
    rm -rf "$STATE_DIR";
    log "reversão concluída";
    ui_info "Reversão concluída. Os arquivos e estados anteriores foram restaurados quando havia snapshot disponível. Reinicie o sistema."
}

setup_lavd () 
{ 
    require_root lavd;
    command -v pacman > /dev/null 2>&1 || die "pacman não encontrado.";
    unlock_steamos;
    trap restore_steamos_readonly EXIT;
    mkdir -p "$STATE_DIR" "$BACKUP_DIR";
    snapshot_services_once;
    command -v steamos-devmode > /dev/null 2>&1 && steamos-devmode enable --no-prompt || true;
    [[ ! -e /var/lib/pacman/db.lck ]] || die "O pacman está ocupado.";
    pacman-key --init 2> /dev/null || true;
    pacman-key --populate archlinux holo 2> /dev/null || true;
    pacman -Sy --noconfirm --needed scx-scheds;
    [[ -x /usr/bin/scx_lavd ]] || die "scx_lavd não foi instalado.";
    backup_file_once "$(p /etc/systemd/system/scx_lavd.service)";
    cat <<'EOF_LAVD' |
[Unit]
Description=Turbo Decky SCX LAVD
After=multi-user.target
Conflicts=scx.service
[Service]
Type=simple
ExecStart=/usr/bin/scx_lavd --performance
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF_LAVD
  atomic_write "$(p /etc/systemd/system/scx_lavd.service)" 0644
    systemctl daemon-reload;
    systemctl enable --now scx_lavd.service;
    ui_info "SCX LAVD instalado e ativo."
}

install_charcoal_kernel () 
{ 
    require_root kernel;
    command -v pacman > /dev/null 2>&1 || die "pacman não encontrado.";
    for command in curl python3 unzip;
    do
        command -v "$command" > /dev/null 2>&1 || die "Comando obrigatório ausente: $command";
    done;
    ui_confirm "Instalar os pacotes da última Release de zarpon/linux-charcoal-TD?" || return 0;
    local tmp json url zip;
    tmp="$(mktemp -d)";
    KERNEL_TMP_DIR="$tmp";
    trap 'rm -rf -- "${KERNEL_TMP_DIR:-}"; restore_steamos_readonly' EXIT;
    json="$tmp/release.json";
    curl --fail --location --retry 3 https://api.github.com/repos/zarpon/linux-charcoal-TD/releases/latest -o "$json";
    url="$(python3 - "$json" <<'PY'
import json, sys
release=json.load(open(sys.argv[1], encoding='utf-8'))
assets=[a for a in release.get('assets',[]) if a.get('name','').endswith('.zip')]
if not assets: raise SystemExit(1)
print(assets[0]['browser_download_url'])
PY
)" || die "Release sem ZIP instalável.";
    zip="$tmp/kernel.zip";
    curl --fail --location --retry 3 "$url" -o "$zip";
    unzip -tq "$zip";
    unzip -q "$zip" -d "$tmp/packages";
    mapfile -d '' -t packages < <(find "$tmp/packages" -type f -name '*.pkg.tar.zst' -print0);
    ((${#packages[@]} > 0)) || die "Nenhum pacote .pkg.tar.zst encontrado.";
    unlock_steamos;
    command -v steamos-devmode > /dev/null 2>&1 && steamos-devmode enable --no-prompt || true;
    pacman -U --needed "${packages[@]}";
    update_grub_runtime;
    rm -rf -- "$tmp";
    KERNEL_TMP_DIR="";
    ui_info "Kernel Charcoal instalado. Reinicie o sistema."
}
