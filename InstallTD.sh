#!/usr/bin/env bash
set -euo pipefail

# --- versão e autor do script ---
# Versão: 1.4 rev03- JUSTICE LEAGUE (Limits & Radeonsi Precompile)
versao="1.4 rev03 - JUSTICE LEAGUE"
autor="Jorge Luis"
pix_doacao="jorgezarpon@msn.com"

# --- constantes e variáveis ---
readonly swapfile_path="/home/swapfile"
readonly grub_config="/etc/default/grub"
readonly zswap_swapfile_size_gb="8"
readonly zram_swapfile_size_gb="2"
readonly backup_suffix="bak-turbodecky"
readonly logfile="/var/log/turbodecky.log"

# --- Constantes para otimização do MicroSD ---
readonly sdcard_device="/dev/mmcblk0p1"
readonly nvme_shadercache_target_path="/home/deck/sd_shadercache"

# --- parâmetros sysctl base ---
readonly base_sysctl_params=(
    "vm.swappiness=150"
    "vm.vfs_cache_pressure=66"
    "vm.dirty_background_bytes=209715200"
    "vm.dirty_bytes=419430400"
    "vm.dirty_expire_centisecs=1500"
    "vm.dirty_writeback_centisecs=1000"
    "vm.min_free_kbytes=131072"
    "vm.page-cluster=0"
    "vm.compaction_proactiveness=15"
    "vm.page_lock_unfairness=8"
    "kernel.numa_balancing=0"
    "kernel.sched_autogroup_enabled=0"
    "kernel.sched_tunable_scaling=0"
    "vm.watermark_scale_factor=125"
    "vm.stat_interval=15"
    "vm.compact_unevictable_allowed=0"
    "vm.watermark_boost_factor=0"
    "vm.zone_reclaim_mode=0"
    "vm.max_map_count=2147483642"
    "vm.mmap_rnd_compat_bits=16"
    "vm.unprivileged_userfaultfd=1"
    "vm.hugetlb_optimize_vmemmap=0"
    
    "fs.aio-max-nr=1048576"
    "fs.epoll.max_user_watches=100000"
    "fs.inotify.max_user_watches=524288"
    "fs.pipe-max-size=2097152"
    "fs.pipe-user-pages-soft=65536"
    "fs.file-max=1000000"
    "kernel.nmi_watchdog=0"
    "kernel.soft_watchdog=0"
    "kernel.watchdog=0"
    "kernel.core_pattern=/dev/null"
    "kernel.core_pipe_limit=0"
    "kernel.printk_devkmsg=off"
    "net.core.default_qdisc=fq"
    "net.ipv4.tcp_congestion_control=bbr"
    "net.core.netdev_max_backlog=16384"
)

# --- listas de serviços para ativar/monitorar ---
readonly otimization_services=(
    "thp-config.service"
    "io-boost.service"
    "hugepages.service"
    "ksm-config.service"
    "kernel-tweaks.service"
)

readonly unnecessary_services=(
    "gpu-trace.service"
    "steamos-log-submitter.service"
    "cups.service"
)

# --- variáveis de ambiente (Configuração de Jogos) ---
readonly game_env_vars=(
    "RADV_PERFTEST=gpl,aco,sam" 
    "WINEFSYNC=1"
    "MESA_SHADER_CACHE_MAX_SIZE=10G"
    "PROTON_FORCE_LARGE_ADDRESS_AWARE=1"
    # Adicionado RADEONSI_SHADER_PRECOMPILE=true para reduzir stuttering
    "RADEONSI_SHADER_PRECOMPILE=true" 
)

# --- Funções Utilitárias ---
_ui_info() { echo -e "\n[info] $1: $2"; }
_log() {
    mkdir -p "$(dirname "$logfile")" 2>/dev/null || true
    touch "$logfile" 2>/dev/null || true
    echo "$(date '+%F %T') - $*" | tee -a "$logfile"
}

if [[ $EUID -ne 0 ]]; then
    echo "❌ erro: este script deve ser executado como root (sudo)." >&2; exit 1;
fi

steamos_readonly_cmd=""
if command -v steamos-readonly &>/dev/null; then
    steamos_readonly_cmd=$(command -v steamos-readonly)
fi

_backup_file_once() {
    local f="$1"; local backup_path="${f}.${backup_suffix}"
    if [[ -f "$f" && ! -f "$backup_path" ]]; then
        cp -a --preserve=timestamps "$f" "$backup_path" 2>/dev/null || cp -a "$f" "$backup_path"
        _log "backup criado: $backup_path"
    fi
}

_restore_file() {
    local f="$1"; local backup_path="${f}.${backup_suffix}"
    if [[ -f "$backup_path" ]]; then
        mv "$backup_path" "$f"
        _log "arquivo '$f' restaurado a partir de $backup_path"
    else
        _log "backup para '$f' não encontrado."
        return 1
    fi
}

_write_sysctl_file() {
    local file_path="$1"; shift; local params=("$@"); local tmp="${file_path}.tmp"
    if [ ${#params[@]} -eq 0 ]; then _log "erro: sem parâmetros."; return 1; fi
    touch "$tmp"
    if [[ -f "$file_path" ]]; then
        grep -vE '^(#.*|vm\.|kernel\.|fs\.|net\.)' "$file_path" >"$tmp" 2>/dev/null || true;
    fi
    printf "%s\n" "${params[@]}" >>"$tmp"
    mv "$tmp" "$file_path"
    sync # Força escrita no disco
    _log "sysctl escrito: $file_path"
}

_steamos_readonly_disable_if_needed() {
    if [[ -n "$steamos_readonly_cmd" ]]; then
        if "$steamos_readonly_cmd" status 2>/dev/null | grep -qi "enabled"; then
            "$steamos_readonly_cmd" disable || true
            trap 'if [[ -n "$steamos_readonly_cmd" ]]; then "$steamos_readonly_cmd" enable || true; fi' EXIT
            _log "steamos-readonly desativado temporariamente"
        else
            _log "steamos-readonly já estava desativado"; trap 'true' EXIT
        fi
    else
        trap 'true' EXIT
    fi
}

_optimize_gpu() {
    _log "aplicando otimizações amdgpu..."
    mkdir -p /etc/modprobe.d
    echo "options amdgpu moverate=128 mes=1 lbpw=0 uni_mes=0 mes_kiq=1" > /etc/modprobe.d/99-amdgpu-tuning.conf
    _log "arquivo /etc/modprobe.d/99-amdgpu-tuning.conf criado."
}

# --- NOVA FUNÇÃO: CONFIGURA ULIMITS ---
_configure_ulimits() {
    _log "aplicando limite de arquivo aberto (ulimit) alto (1048576)"
    mkdir -p /etc/security/limits.d
    cat <<'EOF' > /etc/security/limits.d/99-game-limits.conf
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    _log "/etc/security/limits.d/99-game-limits.conf criado/atualizado."
}
    
_configure_irqbalance() {
    _log "configurando irqbalance..."
    mkdir -p /etc/default
    _backup_file_once "/etc/default/irqbalance"
    echo "IRQBALANCE_BANNED_CPUS=0x01" > /etc/default/irqbalance
    systemctl unmask irqbalance.service 2>/dev/null || true
    systemctl enable irqbalance.service 2>/dev/null || true
    systemctl restart irqbalance.service 2>/dev/null || true
    _log "irqbalance configurado."
}

create_persistent_configs() {
    _log "criando arquivos de configuração persistentes"
    mkdir -p /etc/tmpfiles.d /etc/modprobe.d
    # MGLRU
    cat << EOF > /etc/tmpfiles.d/mglru.conf
w /sys/kernel/mm/lru_gen/enabled - - - - 7
w /sys/kernel/mm/lru_gen/min_ttl_ms - - - - 200
EOF
    # THP Shrinker
    cat << EOF > /etc/tmpfiles.d/thp_shrinker.conf
w! /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_none - - - - 409
EOF
    _log "configurações mglru e thp_shrinker criadas."
}

create_timer_configs() {
    _log "configurando timers de alta frequência"
    mkdir -p /etc/tmpfiles.d
    cat << EOF > /etc/tmpfiles.d/custom-timers.conf
w /sys/class/rtc/rtc0/max_user_freq - - - - 1024
w /sys/dev/hpet/max-user-freq - - - - 1024
EOF
}

manage_unnecessary_services() {
    local action="$1"
    if [[ "$action" == "disable" ]]; then
        systemctl stop "${unnecessary_services[@]}" --quiet || true
        systemctl mask "${unnecessary_services[@]}" --quiet || true
    elif [[ "$action" == "enable" ]]; then
        systemctl unmask "${unnecessary_services[@]}" --quiet || true
    fi
}

create_common_scripts_and_services() {
    _log "criando scripts e services comuns"
    mkdir -p /usr/local/bin /etc/systemd/system /etc/environment.d

    # --- 1. APLICAÇÃO DE VARIÁVEIS DE AMBIENTE ---
    # Garante que o arquivo existe e tem conteúdo. Inclui RADEONSI_SHADER_PRECOMPILE=true
    if [ ${#game_env_vars[@]} -gt 0 ]; then
        printf "%s\n" "${game_env_vars[@]}" > /etc/environment.d/turbodecky-game.conf
        chmod 644 /etc/environment.d/turbodecky-game.conf
        _log "variáveis de ambiente configuradas em /etc/environment.d/turbodecky-game.conf"
    fi

    # --- 2. SCRIPT IO-BOOST (Otimizado para MicroSD/NVMe/ZRAM) ---
    cat <<'IOB' > /usr/local/bin/io-boost.sh
#!/usr/bin/env bash
# Script IO-BOOST - Revisao Persistente
sleep 5
for dev_path in /sys/block/sd* /sys/block/mmcblk* /sys/block/nvme*n* /sys/block/zram*; do
    [ -d "$dev_path" ] || continue
    dev_name=$(basename "$dev_path")
    queue_path="$dev_path/queue"
    
    # Configurações Gerais
    echo 0 > "$queue_path/iostats" 2>/dev/null || true
    echo 0 > "$queue_path/add_random" 2>/dev/null || true

    case "$dev_name" in
    nvme*)
        # NVMe Tuning
        if echo "kyber" > "$queue_path/scheduler" 2>/dev/null; then :;
        elif echo "none" > "$queue_path/scheduler" 2>/dev/null; then :;
        else echo "mq-deadline" > "$queue_path/scheduler" 2>/dev/null || true; fi
        echo 1024 > "$queue_path/read_ahead_kb" 2>/dev/null || true
        echo 1024 > "$queue_path/nr_requests" 2>/dev/null || true
        echo 0 > "$queue_path/nomerges" 2>/dev/null || true
        echo 0 > "$queue_path/wbt_lat_usec" 2>/dev/null || true
        ;;
    
    mmcblk*|sd*)
        # MicroSD Tuning (Latência e Scheduler)
        if grep -q "bfq" "$queue_path/scheduler" 2>/dev/null; then
            echo "bfq" > "$queue_path/scheduler" 2>/dev/null || true
        else
            echo "mq-deadline" > "$queue_path/scheduler" 2>/dev/null || true
        fi

        echo 2048 > "$queue_path/read_ahead_kb" 2>/dev/null || true
        echo 1 > "$queue_path/rq_affinity" 2>/dev/null || true
        echo 2000 > "$queue_path/wbt_lat_usec" 2>/dev/null || true
        
        # Loop para aplicar parâmetros em qualquer variação de caminho do kernel (Legacy/Modern)
        for sched_path in "$queue_path/iosched" "$queue_path/mq-deadline" "$queue_path/bfq"; do
            if [ -d "$sched_path" ]; then
                # Common Deadline/Async params
                echo 1 > "$sched_path/back_seek_penalty" 2>/dev/null || true
                echo 200 > "$sched_path/fifo_expire_async" 2>/dev/null || true
                echo 100 > "$sched_path/fifo_expire_sync" 2>/dev/null || true
                echo 100 > "$sched_path/timeout_sync" 2>/dev/null || true
                # BFQ params
                echo 0 > "$sched_path/slice_idle" 2>/dev/null || true
                echo 0 > "$sched_path/slice_idle_us" 2>/dev/null || true
            fi
        done
        ;;
    esac
done
IOB
    chmod +x /usr/local/bin/io-boost.sh

    # --- 3. SCRIPT THP ---
    cat <<'THP' > /usr/local/bin/thp-config.sh
#!/usr/bin/env bash
echo "always" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo "defer+madvise" > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
echo "advise" > /sys/kernel/mm/transparent_hugepage/shmem_enabled 2>/dev/null || true
echo 1 > /sys/kernel/mm/transparent_hugepage/khugepaged/defrag 2>/dev/null || true
echo 2048 > /sys/kernel/mm/transparent_hugepage/khugepaged/pages_to_scan 2>/dev/null || true
echo 5000 > /sys/kernel/mm/transparent_hugepage/khugepaged/scan_sleep_millisecs 2>/dev/null || true
echo 128 > /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_swap 2>/dev/null || true
THP
    chmod +x /usr/local/bin/thp-config.sh

    # --- 4. SCRIPT HUGEPAGES ---
    cat <<'HPS' > /usr/local/bin/hugepages.sh
#!/usr/bin/env bash
echo 0 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages 2>/dev/null || true
HPS
    chmod +x /usr/local/bin/hugepages.sh

    # --- 5. SCRIPT KSM ---
    cat <<'KSM' > /usr/local/bin/ksm-config.sh
#!/usr/bin/env bash
echo 0 > /sys/kernel/mm/ksm/run 2>/dev/null || true
KSM
    chmod +x /usr/local/bin/ksm-config.sh

    # --- 6. SCRIPT KERNEL TWEAKS ---
    cat <<'KRT' > /usr/local/bin/kernel-tweaks.sh
#!/usr/bin/env bash
echo 1 > /sys/module/multi_queue/parameters/multi_queue_alloc 2>/dev/null || true
echo 1 > /sys/module/multi_queue/parameters/multi_queue_reclaim 2>/dev/null || true
if [ -w /sys/module/rcu/parameters/rcu_normal_after_boot ]; then
    echo 0 > /sys/module/rcu/parameters/rcu_normal_after_boot 2>/dev/null || true
fi
KRT
    chmod +x /usr/local/bin/kernel-tweaks.sh

    # --- 7. CRIAÇÃO DOS SERVICES SYSTEMD ---
    for service_name in thp-config io-boost hugepages ksm-config kernel-tweaks; do
        cat <<UNIT > /etc/systemd/system/${service_name}.service
[Unit]
Description=TurboDecky ${service_name} persistence
After=local-fs.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/${service_name}.sh
RemainAfterExit=true
[Install]
WantedBy=multi-user.target
UNIT
    done
    systemctl daemon-reload || true
}

otimizar_sdcard_cache() {
    _log "otimizando microsd..."
    local sdcard_mount_point; sdcard_mount_point=$(findmnt -n -o TARGET "$sdcard_device" 2>/dev/null || echo "")
    if [[ -z "$sdcard_mount_point" ]]; then _ui_info "erro" "microsd não montado"; return 1; fi
    local sdcard_steamapps_path="${sdcard_mount_point}/steamapps"
    local sdcard_shadercache_path="${sdcard_steamapps_path}/shadercache"
    if ! [ -d "$sdcard_steamapps_path" ]; then _ui_info "erro" "steamapps não encontrado"; return 1; fi
    if [ -L "$sdcard_shadercache_path" ]; then _ui_info "info" "já otimizado"; return 0; fi
    mkdir -p "$nvme_shadercache_target_path"
    local deck_user; deck_user=$(stat -c '%U' /home/deck 2>/dev/null || echo "deck")
    local deck_group; deck_group=$(stat -c '%G' /home/deck 2>/dev/null || echo "deck")
    chown "${deck_user}:${deck_group}" "$nvme_shadercache_target_path" 2>/dev/null || true
    if [ -d "$sdcard_shadercache_path" ]; then
        if command -v rsync &>/dev/null; then
             rsync -a --remove-source-files "$sdcard_shadercache_path"/ "$nvme_shadercache_target_path"/ 2>/dev/null || true
             find "$sdcard_shadercache_path" -type d -empty -delete 2>/dev/null || true
        else
             mv "$sdcard_shadercache_path"/* "$nvme_shadercache_target_path"/ 2>/dev/null || true
             rmdir "$sdcard_shadercache_path" 2>/dev/null || true
        fi
    fi
    ln -s "$nvme_shadercache_target_path" "$sdcard_shadercache_path"
    _ui_info "sucesso" "otimização do microsd concluída!"
}

reverter_sdcard_cache() {
    _log "revertendo microsd..."
    local sdcard_mount_point; sdcard_mount_point=$(findmnt -n -o TARGET "$sdcard_device" 2>/dev/null || echo "")
    if [[ -z "$sdcard_mount_point" ]]; then _ui_info "erro" "microsd não montado"; return 1; fi
    local sdcard_steamapps_path="${sdcard_mount_point}/steamapps"
    local sdcard_shadercache_path="${sdcard_steamapps_path}/shadercache"
    if ! [ -L "$sdcard_shadercache_path" ]; then _ui_info "erro" "link não encontrado"; return 1; fi
    rm "$sdcard_shadercache_path"
    mkdir -p "$sdcard_shadercache_path"
    if command -v rsync &>/dev/null; then
         rsync -a --remove-source-files "$nvme_shadercache_target_path"/ "$sdcard_shadercache_path"/ 2>/dev/null || true
         find "$nvme_shadercache_target_path" -type d -empty -delete 2>/dev/null || true
    else
         mv "$nvme_shadercache_target_path"/* "$sdcard_shadercache_path"/ 2>/dev/null || true
         rmdir "$nvme_shadercache_target_path" 2>/dev/null || true
    fi
    _ui_info "sucesso" "reversão microsd concluída."
}

_executar_reversao() {
    _steamos_readonly_disable_if_needed;
    _log "executando reversão geral"

    # --- REMOÇÃO LIMPA DE ARQUIVOS DE AMBIENTE (Inclui RADEONSI_SHADER_PRECOMPILE) ---
    # Remove tanto o padrão novo quanto o legado específico "99-game-vars.conf"
    rm -f /etc/environment.d/turbodecky*.conf /etc/environment.d/99-game-vars.conf

    # --- REMOÇÃO DO LIMITE DE ARQUIVO ABERTO (ULIMIT) ---
    rm -f /etc/security/limits.d/99-game-limits.conf

    # --- PARADA E REMOÇÃO DE SERVIÇOS ---
    systemctl stop "${otimization_services[@]}" zswap-config.service zram-config.service 2>/dev/null || true
    systemctl disable "${otimization_services[@]}" zswap-config.service zram-config.service 2>/dev/null || true
    
    # Remove arquivos de unidade
    for svc in "${otimization_services[@]}" zswap-config.service zram-config.service; do
        rm -f "/etc/systemd/system/$svc"
    done
    
    # Remove scripts binários
    rm -f /usr/local/bin/zswap-config.sh /usr/local/bin/zram-config.sh
    # Reutilizando a lista otimization_services para remover scripts
    for script_svc in "${otimization_services[@]}"; do
        rm -f "/usr/local/bin/${script_svc%%.service}.sh"
    done

    swapoff "$swapfile_path" 2>/dev/null || true; rm -f "$swapfile_path" || true
    _restore_file /etc/fstab || true
    swapon -a 2>/dev/null || true

    _restore_file /etc/sysctl.d/99-sdweak-performance.conf || rm -f /etc/sysctl.d/99-sdweak-performance.conf
    _restore_file "$grub_config" || true

    if command -v update-grub &>/dev/null; then update-grub; else steamos-update-grub &>/dev/null || true; fi
    mkinitcpio -P &>/dev/null || true

    sysctl --system || true
    systemctl daemon-reload || true
    manage_unnecessary_services "enable"
    _log "reversão concluída."
}

aplicar_zswap() {
    _log "Aplicando ZSWAP (Persistente)"
    _executar_reversao
    _steamos_readonly_disable_if_needed;
    _optimize_gpu
    _configure_ulimits # Aplica o ulimit
    create_common_scripts_and_services
    _configure_irqbalance
    local free_space_gb; free_space_gb=$(df -BG /home | awk 'NR==2 {print $4}' | tr -d 'G' || echo 0)
    if (( free_space_gb < zswap_swapfile_size_gb )); then _ui_info "erro" "espaço insuficiente"; exit 1; fi

    fallocate -l "${zswap_swapfile_size_gb}G" "$swapfile_path" 2>/dev/null || dd if=/dev/zero of="$swapfile_path" bs=1G count="$zswap_swapfile_size_gb" status=progress
    chmod 600 "$swapfile_path" || true; mkswap "$swapfile_path" || true
    sed -i "\|${swapfile_path}|d" /etc/fstab 2>/dev/null || true; echo "$swapfile_path none swap sw,pri=-2 0 0" >> /etc/fstab
    swapon --priority -2 "$swapfile_path" || true

    _write_sysctl_file /etc/sysctl.d/99-sdweak-performance.conf "${base_sysctl_params[@]}"
    sysctl --system || true

    _backup_file_once "$grub_config"
    local kernel_params=("zswap.enabled=1" "zswap.compressor=zstd" "zswap.max_pool_percent=30" "zswap.zpool=zsmalloc" "zswap.shrinker_enabled=1" "mitigations=off" "psi=1" "rcutree.enable_rcu_lazy=1" "split_lock_detect=off")
    local current_cmdline; current_cmdline=$(grep -E '^GRUB_CMDLINE_LINUX=' "$grub_config" | sed -E 's/^GRUB_CMDLINE_LINUX="([^"]*)"(.*)/\1/' || true)
    local new_cmdline="$current_cmdline"
    for param in "${kernel_params[@]}"; do local key="${param%%=*}"; new_cmdline=$(echo "$new_cmdline" | sed -E "s/ ?${key}(=[^ ]*)?//g"); done
    for param in "${kernel_params[@]}"; do new_cmdline="$new_cmdline $param"; done
    new_cmdline=$(echo "$new_cmdline" | tr -s ' ' | sed -E 's/^ //; s/ $//')
    sed -i -E "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$new_cmdline\"|" "$grub_config" || true

    steamos-update-grub &>/dev/null || update-grub &>/dev/null || true
    mkinitcpio -P &>/dev/null || true

    create_timer_configs
    create_persistent_configs

    cat <<'ZSWAP_SCRIPT' > /usr/local/bin/zswap-config.sh
#!/usr/bin/env bash
echo 1 > /sys/module/zswap/parameters/enabled 2>/dev/null || true
echo zstd > /sys/module/zswap/parameters/compressor 2>/dev/null || true
echo 30 > /sys/module/zswap/parameters/max_pool_percent 2>/dev/null || true
echo zsmalloc > /sys/module/zswap/parameters/zpool 2>/dev/null || true
echo 1 > /sys/module/zswap/parameters/shrinker_enabled 2>/dev/null || true
echo 1 > /sys/kernel/mm/page_idle/enable 2>/dev/null || true
sysctl -w vm.fault_around_bytes=32 2>/dev/null || true
ZSWAP_SCRIPT
    chmod +x /usr/local/bin/zswap-config.sh

    cat <<UNIT > /etc/systemd/system/zswap-config.service
[Unit]
Description=Configuracao ZSWAP Persistent
After=local-fs.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/zswap-config.sh
RemainAfterExit=true
[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload || true
    # Ativação explícita de persistência para todos os serviços
    systemctl enable --now "${otimization_services[@]}" zswap-config.service || true
    
    # Força releitura de regras udev (para aplicar I/O rules imediatamente sem reboot)
    if command -v udevadm &>/dev/null; then udevadm trigger; fi
    
    _ui_info "sucesso" "ZSWAP aplicado. Reinicie para efeito total (GRUB e EnvVars)."
}

aplicar_zram() {
    _log "Aplicando ZRAM (Persistente - Manual Reorder Fix)"
    _executar_reversao
    _steamos_readonly_disable_if_needed;
    _optimize_gpu
    _configure_ulimits # Aplica o ulimit
    create_common_scripts_and_services
    _configure_irqbalance

    _write_sysctl_file /etc/sysctl.d/99-sdweak-performance.conf "${base_sysctl_params[@]}"
    sysctl --system || true

    _backup_file_once "$grub_config"
    local kernel_params=("zswap.enabled=0" "mitigations=off" "psi=1" "rcutree.enable_rcu_lazy=1" "split_lock_detect=off")
    local current_cmdline; current_cmdline=$(grep -E '^GRUB_CMDLINE_LINUX=' "$grub_config" | sed -E 's/^GRUB_CMDLINE_LINUX="([^"]*)"(.*)/\1/' || true)
    local new_cmdline="$current_cmdline"
    for param in "${kernel_params[@]}"; do local key="${param%%=*}"; new_cmdline=$(echo "$new_cmdline" | sed -E "s/ ?${key}(=[^ ]*)?//g" | sed -E "s/ ?zswap\.[^ =]+(=[^ ]*)?//g"); done
    for param in "${kernel_params[@]}"; do new_cmdline="$new_cmdline $param"; done
    new_cmdline=$(echo "$new_cmdline" | tr -s ' ' | sed -E 's/^ //; s/ $//')
    sed -i -E "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$new_cmdline\"|" "$grub_config" || true
    steamos-update-grub &>/dev/null || update-grub &>/dev/null || true
    mkinitcpio -P &>/dev/null || true

    create_timer_configs
    create_persistent_configs

    cat <<'ZRAM_SCRIPT' > /usr/local/bin/zram-config.sh
#!/usr/bin/env bash
CPU_CORES=$(nproc)
if [[ -z "$CPU_CORES" ]]; then CPU_CORES=4; fi

# 1. Kill and Wait Loop
MAX_RETRY=10
count=0
while lsmod | grep -q "zram" && [ $count -lt $MAX_RETRY ]; do
    swapoff /dev/zram* 2>/dev/null || true
    echo 1 > /sys/block/zram0/reset 2>/dev/null || true
    echo 1 > /sys/block/zram1/reset 2>/dev/null || true
    modprobe -r zram 2>/dev/null || true
    sleep 1
    ((count++))
done

# 2. Load Module
modprobe zram num_devices=2 2>/dev/null || true
if command -v udevadm &>/dev/null; then udevadm settle; else sleep 3; fi

# 3. ZRAM0 (LZ4 / 2G)
if [ -d "/sys/block/zram0" ]; then
    # ORDEM CRÍTICA KERNEL 6.1+: Reset -> ALGO -> STREAMS -> SIZE
    echo 1 > /sys/block/zram0/reset 2>/dev/null || true
    if command -v udevadm &>/dev/null; then udevadm settle; else sleep 0.5; fi

    # Algoritmo PRIMEIRO (pois isso reseta streams para 1)
    echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true

    # Streams DEPOIS
    echo "$CPU_CORES" > /sys/block/zram0/max_comp_streams 2>/dev/null || true

    echo zsmalloc > /sys/block/zram0/zpool 2>/dev/null || true
    echo 2G > /sys/block/zram0/disksize 2>/dev/null || true
    mkswap /dev/zram0 2>/dev/null || true
    swapon /dev/zram0 -p 3000 2>/dev/null || true
fi

# 4. ZRAM1 (ZSTD / 6G)
if [ -d "/sys/block/zram1" ]; then
    echo 1 > /sys/block/zram1/reset 2>/dev/null || true
    if command -v udevadm &>/dev/null; then udevadm settle; else sleep 0.5; fi

    # Algoritmo PRIMEIRO
    echo zstd > /sys/block/zram1/comp_algorithm 2>/dev/null || true

    # Streams DEPOIS
    echo "$CPU_CORES" > /sys/block/zram1/max_comp_streams 2>/dev/null || true

    echo zsmalloc > /sys/block/zram1/zpool 2>/dev/null || true
    echo 6G > /sys/block/zram1/disksize 2>/dev/null || true
    mkswap /dev/zram1 2>/dev/null || true
    swapon /dev/zram1 -p 10 2>/dev/null || true
fi

# 5. Tweaks
echo 1 > /sys/kernel/mm/page_idle/enable 2>/dev/null || true
sysctl -w vm.fault_around_bytes=32 2>/dev/null || true

# DEBUG
echo "=== ZRAM STATUS ===" >> /var/log/turbodecky.log
zramctl >> /var/log/turbodecky.log
ZRAM_SCRIPT

    chmod +x /usr/local/bin/zram-config.sh
    cat <<UNIT > /etc/systemd/system/zram-config.service
[Unit]
Description=ZRAM Dual Layer Setup Persistent
After=local-fs.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/zram-config.sh
RemainAfterExit=true
[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload || true
    # Ativação explícita de persistência para todos os serviços
    systemctl enable --now "${otimization_services[@]}" zram-config.service || true
    
    # Força releitura de regras udev
    if command -v udevadm &>/dev/null; then udevadm trigger; fi

    _ui_info "sucesso" "ZRAM Dual Layer aplicado. Reinicie o sistema para efeito total."
}

reverter_alteracoes() {
    _executar_reversao
    _ui_info "sucesso" "Reversão completa. Reinicie."
}

main() {
    echo -e "\n=== Turbo Decky $versao ==="
    echo "1) ZSwap + Swapfile (Recomendado)"
    echo "2) Dual ZRAM (Alternativa para pouco espaço livre)"
    echo "3) Otimizar MicroSD"
    echo "4) Reverter Tudo"
    echo "5) Reverter MicroSD"
    echo "6) Sair"
    read -rp "Opção: " escolha
    case "$escolha" in
        1) aplicar_zswap ;;
        2) aplicar_zram ;;
        3) otimizar_sdcard_cache ;;
        4) reverter_alteracoes ;;
        5) reverter_sdcard_cache ;;
        6) exit 0 ;;
        *) echo "Inválido" ;;
    esac
}

main "$@"
