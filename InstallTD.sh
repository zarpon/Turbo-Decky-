#!/usr/bin/env bash
set -euo pipefail

# --- versão e autor do script ---
# Versão atualizada, corrigindo o erro de sintaxe '}' em 'if'
versao="1.2.7 - Kriptoniano" 
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
    "vm.swappiness=100"

    "vm.vfs_cache_pressure=50"

         "vm.dirty_background_bytes=209715200"


"vm.dirty_bytes=419430400"

    
    "vm.dirty_expire_centisecs=1500"

    "vm.dirty_writeback_centisecs=500"

    "vm.min_free_kbytes=65536"

    "vm.page-cluster=0"

    "vm.compaction_proactiveness=10"

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
    
    # TWEAK ANTI-STUTTER: Desativa otimização de HugePages que pode causar latência.
    "vm.hugetlb_optimize_vmemmap=0" 
    
    # TWEAK ANTI-STUTTER DE MEMÓRIA: Mantém um buffer de 128MB para evitar stalls do kcompactd.
    "vm.extra_free_kbytes=131072" 

    "fs.aio-max-nr=131072"

    "fs.epoll.max_user_watches=100000"

    "fs.inotify.max_user_watches=65536"

    "fs.pipe-max-size=2097152"

    "fs.pipe-user-pages-soft=65536"

    "fs.file-max=1000000"

    "kernel.nmi_watchdog=0"

    "kernel.soft_watchdog=0"

    "kernel.watchdog=0"

    "kernel.core_pattern=/dev/null"

    "kernel.core_pipe_limit=0"

    "kernel.printk_devkmsg=off"

    "net.core.default_qdisc=fq_codel"

   "net.ipv4.tcp_congestion_control=bbr"

    "net.core.netdev_max_backlog=16384"
)

# --- parâmetros específicos do agendador bore ---
readonly bore_params=(
    "kernel.sched_bore=1"
    "kernel.sched_burst_cache_lifetime=40000000"
    "kernel.sched_burst_fork_atavistic=2"
    "kernel.sched_burst_penalty_offset=26"
    "kernel.sched_burst_penalty_scale=1000"
    "kernel.sched_burst_smoothness_long=0"
    "kernel.sched_burst_smoothness_short=0"
    "kernel.sched_burst_exclude_kthreads=1"
    "kernel.sched_burst_parity_threshold=1"
)

# --- listas de serviços ---
readonly otimization_services=(
    "thp-config.service"
    "io-boost.service"
    "hugepages.service"
    "ksm-config.service"
    "kernel-tweaks.service"
)
readonly otimization_scripts=(
    "/usr/local/bin/thp-config.sh"
    "/usr/local/bin/io-boost.sh"
    "/usr/local/bin/hugepages.sh"
    "/usr/local/bin/ksm-config.sh"
    "/usr/local/bin/kernel-tweaks.sh"
)
readonly unnecessary_services=(
    "gpu-trace.service"
    "steamos-log-submitter.service"
    "cups.service"
)

# --- variáveis de ambiente ---
readonly game_env_vars=(
    "RADV_PERFTEST=aco"
    "WINEFSYNC=1"
    "MESA_SHADER_CACHE_MAX_SIZE=20G"
    "MESA_SHADER_CACHE_DIR=/home/deck/.cache/"

    "PROTON_FORCE_LARGE_ADDRESS_AWARE=1"
    "mesa_glthread=true"
)

# --- Funções ---
_ui_info() { echo -e "\n[info] $1: $2"; }
_ui_progress_exec() {
    local title="$1";
    local info="$2";
    local tmp
    tmp=$(mktemp) || { echo "erro: mktemp falhou"; return 1; }
    cat >"$tmp"
    echo -e "\n--- executando: $title ---\n$info\n--------------------------"
    bash "$tmp";
    local rc=$?;
    rm -f "$tmp"
    echo "--- concluÍdo: $title ---"
    return $rc
}
_log() {
    mkdir -p "$(dirname "$logfile")" 2>/dev/null || true
    touch "$logfile" 2>/dev/null || true
    echo "$(date '+%F %T') - $*" | tee -a "$logfile"
}

if [[ $EUID -ne 0 ]]; then
    echo "❌ erro: este script deve ser executado como root (sudo)." >&2;
    exit 1;
fi

steamos_readonly_cmd=""
if command -v steamos-readonly &>/dev/null; then
    steamos_readonly_cmd=$(command -v steamos-readonly)
fi

_backup_file_once() {
    local f="$1";
    local backup_path="${f}.${backup_suffix}"
    if [[ -f "$f" && ! -f "$backup_path" ]]; then
        cp -a --preserve=timestamps "$f" "$backup_path" 2>/dev/null || cp -a "$f" "$backup_path"
        _log "backup criado: $backup_path"
    fi # CORRIGIDO: Era '}' e foi trocado para 'fi'
}

_restore_file() {
    local f="$1";
    local backup_path="${f}.${backup_suffix}"
    if [[ -f "$backup_path" ]]; then
        mv "$backup_path" "$f"
        _log "arquivo '$f' restaurado a partir de $backup_path"
    else
        _log "backup para '$f' não encontrado."
        return 1
    fi # CORRIGIDO: Era '}' e foi trocado para 'fi'
}

_write_sysctl_file() {
    local file_path="$1";
    shift;
    local params=("$@")
    local tmp="${file_path}.tmp"
    if [ ${#params[@]} -eq 0 ]; then
        _log "erro: tentou escrever arquivo sysctl sem parâmetros.";
        return 1;
    fi
    touch "$tmp"
    if [[ -f "$file_path" ]]; then
        grep -vE '^(#.*|vm\.|kernel\.|fs\.|net\.)' "$file_path" >"$tmp" 2>/dev/null || true;
    fi
    printf "%s\n" "${params[@]}" >>"$tmp"
    mv "$tmp" "$file_path"
    _log "sysctl escrito: $file_path com ${#params[@]} parâmetros."
}

_steamos_readonly_disable_if_needed() {
    if [[ -n "$steamos_readonly_cmd" ]]; then
        if "$steamos_readonly_cmd" status 2>/dev/null | grep -qi "enabled"; then
            "$steamos_readonly_cmd" disable || true
            trap 'if [[ -n "$steamos_readonly_cmd" ]]; then "$steamos_readonly_cmd" enable || true; fi' EXIT
            _log "steamos-readonly desativado temporariamente"
        else
            _log "steamos-readonly já estava desativado";
            trap 'true' EXIT
        fi
    else
        trap 'true' EXIT
    fi
}

_optimize_gpu() {
    _log "aplicando otimizações amdgpu (com MES completo)..."
    mkdir -p /etc/modprobe.d
    echo "options amdgpu moverate=128 mes=1 lbpw=0 uni_mes=0 mes_kiq=1" > /etc/modprobe.d/99-amdgpu-tuning.conf
    _ui_info "gpu" "otimizações amdgpu (com MES completo) aplicadas."
    _log "arquivo /etc/modprobe.d/99-amdgpu-tuning.conf criado."
}

_configure_irqbalance() {
    _log "configurando irqbalance..."
    mkdir -p /etc/default
    _backup_file_once "/etc/default/irqbalance"
    cat << EOF > /etc/default/irqbalance
# Configurado pelo Turbo Decky
IRQBALANCE_BANNED_CPUS=0x03
EOF
    _log "configuração /etc/default/irqbalance criada."
    systemctl unmask irqbalance.service 2>/dev/null || true
    systemctl enable irqbalance.service 2>/dev/null || true
    systemctl restart irqbalance.service 2>/dev/null || true
    _log "irqbalance ativado e configurado."
}

create_persistent_configs() {
    _log "criando arquivos de configuração persistentes"
    mkdir -p /etc/tmpfiles.d /etc/modprobe.d
    cat << EOF > /etc/tmpfiles.d/mglru.conf
w /sys/kernel/mm/lru_gen/enabled - - - - 7
w /sys/kernel/mm/lru_gen/min_ttl_ms - - - - 200
EOF
    cat << EOF > /etc/tmpfiles.d/thp_shrinker.conf
w! /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_none - - - - 409
EOF
    _log "configurações persistentes para mglru e thp shrinker criadas."
}

# --- TWEAK PARA FIX DE STUTTER DE EMULAÇÃO (1024HZ) ---
create_timer_configs() {
    _log "configurando timers de alta frequência (1024Hz) para baixa latência emuladores"
    mkdir -p /etc/tmpfiles.d
    cat << EOF > /etc/tmpfiles.d/custom-timers.conf
# Configurado pelo Turbo Decky - Balanço: 1024Hz
# Aumenta a frequência máxima de timers para emuladores
w /sys/class/rtc/rtc0/max_user_freq - - - - 1024
w /sys/dev/hpet/max-user-freq - - - - 1024
EOF
    _log "configurações persistentes de timers criadas."
}

create_module_blacklist() {
    _log "criando blacklist para o módulo zram"
    mkdir -p /etc/modprobe.d
    echo "blacklist zram" > /etc/modprobe.d/blacklist-zram.conf
    _log "módulo zram adicionado à blacklist."
}

manage_unnecessary_services() {
    local action="$1"
    _log "gerenciando serviços desnecessários (ação: $action)"
    if [[ "$action" == "disable" ]]; then
        systemctl stop "${unnecessary_services[@]}" --quiet || true
        systemctl mask "${unnecessary_services[@]}" --quiet || true
        _log "serviços desnecessários parados e mascarados."
    elif [[ "$action" == "enable" ]]; then
        systemctl unmask "${unnecessary_services[@]}" --quiet || true
        _log "serviços desnecessários desmascarados."
    fi
}

create_common_scripts_and_services() {
    _log "criando/atualizando scripts e services comuns"
    mkdir -p /usr/local/bin /etc/systemd/system /etc/environment.d

    # MODIFICADO: Gerenciamento de energia do NVMe removido.
    # MODIFICADO: Lógica do agendador NVMe melhorada (none > kyber > mq-deadline).
    # MODIFICADO: NVMe read_ahead_kb aumentado para 512KB.
    cat <<'IOB' > /usr/local/bin/io-boost.sh
#!/usr/bin/env bash
sleep 5
for dev_path in /sys/block/sd* /sys/block/mmcblk* /sys/block/nvme*n* /sys/block/zram*; do
    [ -d "$dev_path" ] || continue
    dev_name=$(basename "$dev_path")
    queue_path="$dev_path/queue"
    echo 0 > "$queue_path/iostats" 2>/dev/null || true
    echo 0 > "$queue_path/add_random" 2>/dev/null || true
    case "$dev_name" in
    nvme*)
        # Bloco de gerenciamento de energia (autosuspend_delay_ms, control) REMOVIDO.
        
        # Otimização do Agendador (Scheduler): Tenta 'none', 'kyber', depois 'mq-deadline'.
        if echo "none" > "$queue_path/scheduler" 2>/dev/null; then
            : # 'none' foi aplicado com sucesso
        elif echo "kyber" > "$queue_path/scheduler" 2>/dev/null; then
            : # 'kyber' (baixa latência) foi aplicado
        else
            echo "mq-deadline" > "$queue_path/scheduler" 2>/dev/null || true
        fi
        
        # Otimização de Read-Ahead: Aumentado para 512KB (melhor para loading de jogos)
        echo 512 > "$queue_path/read_ahead_kb" 2>/dev/null || true
        
        echo 1024 > "$queue_path/nr_requests" 2>/dev/null || true
        echo 1 > "$queue_path/nomerges" 2>/dev/null || true
        echo 0 > "$queue_path/wbt_lat_usec" 2>/dev/null || true
        ;;
    mmcblk*|sd*)
        if [[ -w "$queue_path/scheduler" ]] && grep -q "bfq" "$queue_path/scheduler"; then
            echo "bfq" > "$queue_path/scheduler" 2>/dev/null || true
            echo 1 > "$queue_path/iosched/low_latency" 2>/dev/null || true
            echo 0 > "$queue_path/iosched/slice_idle_us" 2>/dev/null || true
        elif [ -w "$queue_path/scheduler" ]; then
            echo "mq-deadline" > "$queue_path/scheduler" 2>/dev/null || true
        fi
        echo 512 > "$queue_path/read_ahead_kb" 2>/dev/null || true
        echo 2 > "$queue_path/rq_affinity" 2>/dev/null || true
        ;;
    esac
done
IOB
    chmod +x /usr/local/bin/io-boost.sh

    # SCRIPT THP-CONFIG ATUALIZADO PARA "ALWAYS (LAZY)" COM MAX_PTES_SWAP 128
    cat <<'THP' > /usr/local/bin/thp-config.sh
#!/usr/bin/env bash
# 1. Mudar para 'always'
echo "always" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo "defer+madvise" > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
echo "advise" > /sys/kernel/mm/transparent_hugepage/shmem_enabled 2>/dev/null || true
# 3. Permitir que o 'khugepaged' (gari) trabalhe em segundo plano
echo 1 > /sys/kernel/mm/transparent_hugepage/khugepaged/defrag 2>/dev/null || true
# 4. Parâmetros para torná-lo "preguiçoso" e não causar stutter
echo 2048 > /sys/kernel/mm/transparent_hugepage/khugepaged/pages_to_scan 2>/dev/null || true
echo 5000 > /sys/kernel/mm/transparent_hugepage/khugepaged/scan_sleep_millisecs 2>/dev/null || true
echo 50000 > /sys/kernel/mm/transparent_hugepage/khugepaged/alloc_sleep_millisecs 2>/dev/null || true
# 5. Limite o número de páginas pequenas lidas do swap para colapso
echo 128 > /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_swap 2>/dev/null || true
THP
    chmod +x /usr/local/bin/thp-config.sh

    cat <<'HPS' > /usr/local/bin/hugepages.sh
#!/usr/bin/env bash
echo 0 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages 2>/dev/null || true
HPS
    chmod +x /usr/local/bin/hugepages.sh

    cat <<'KSM' > /usr/local/bin/ksm-config.sh
#!/usr/bin/env bash
echo 0 > /sys/kernel/mm/ksm/run 2>/dev/null || true
KSM
    chmod +x /usr/local/bin/ksm-config.sh

    cat <<'KRT' > /usr/local/bin/kernel-tweaks.sh
#!/usr/bin/env bash
echo 1 > /sys/module/multi_queue/parameters/multi_queue_alloc 2>/dev/null || true
echo 1 > /sys/module/multi_queue/parameters/multi_queue_reclaim 2>/dev/null || true
if [ -w /sys/module/rcu/parameters/rcu_normal_after_boot ]; then
    echo 0 > /sys/module/rcu/parameters/rcu_normal_after_boot 2>/dev/null || true
fi
KRT
    chmod +x /usr/local/bin/kernel-tweaks.sh

    for service_name in thp-config io-boost hugepages ksm-config kernel-tweaks; do
        description="";
        case "$service_name" in
        # Atualizando descrição do THP
        thp-config) description="configuracao otimizada de thp (always-lazy)";;
        io-boost) description="otimização de i/o e agendadores de disco";;
        hugepages) description="desativa pre-alocacao de huge pages";;
        ksm-config) description="desativa kernel samepage merging (ksm)";;
        kernel-tweaks) description="otimizacoes variadas de kernel (rcu, mq)";;
        esac
        cat <<UNIT > /etc/systemd/system/${service_name}.service
[Unit]
Description=${description}
[Service]
Type=oneshot
ExecStart=/usr/local/bin/${service_name}.sh
RemainAfterExit=true
[Install]
WantedBy=multi-user.target
UNIT
    done
    systemctl daemon-reload || true
    _log "scripts e services comuns criados/atualizados e instalados."
}

otimizar_sdcard_cache() {
    _log "iniciando otimização de cache do microsd (via rsync)..."
    local sdcard_mount_point
    sdcard_mount_point=$(findmnt -n -o TARGET "$sdcard_device" 2>/dev/null || echo "")
    if [[ -z "$sdcard_mount_point" ]]; then
        _ui_info "erro" "não foi possível encontrar o ponto de montagem para $sdcard_device."
        _log "falha: findmnt não encontrou o ponto de montagem para $sdcard_device."
        return 1
    fi
    _log "microsd detectado em: $sdcard_mount_point"
    local sdcard_steamapps_path="${sdcard_mount_point}/steamapps"
    local sdcard_shadercache_path="${sdcard_steamapps_path}/shadercache"
    if ! [ -d "$sdcard_steamapps_path" ]; then
        _ui_info "erro" "diretório 'steamapps' não encontrado em $sdcard_mount_point."
        _log "falha: $sdcard_steamapps_path não encontrado."
        return 1
    fi
    if [ -L "$sdcard_shadercache_path" ]; then
        _ui_info "info" "o cache do microsd já parece estar otimizado."
        _log "otimização do microsd já aplicada."
        return 0
    fi
    _log "criando diretório de destino no nvme: $nvme_shadercache_target_path"
    mkdir -p "$nvme_shadercache_target_path"
    local deck_user
    local deck_group
    deck_user=$(stat -c '%U' /home/deck 2>/dev/null || echo "deck")
    deck_group=$(stat -c '%G' /home/deck 2>/dev/null || echo "deck")
    _log "ajustando permissões de $nvme_shadercache_target_path"
    chown "${deck_user}:${deck_group}" "$nvme_shadercache_target_path" 2>/dev/null || true
    if [ -d "$sdcard_shadercache_path" ]; then
        _log "movendo shaders existentes do microsd para o nvme (usando rsync)..."
        if command -v rsync &>/dev/null; then
             rsync -a --remove-source-files "$sdcard_shadercache_path"/ "$nvme_shadercache_target_path"/ 2>/dev/null || true
             find "$sdcard_shadercache_path" -type d -empty -delete 2>/dev/null || true
        else
             mv "$sdcard_shadercache_path"/* "$nvme_shadercache_target_path"/ 2>/dev/null || true
             rmdir "$sdcard_shadercache_path" 2>/dev/null || true
        fi
    fi
    _log "criando link simbólico: $sdcard_shadercache_path -> $nvme_shadercache_target_path"
    ln -s "$nvme_shadercache_target_path" "$sdcard_shadercache_path"
    _ui_info "sucesso" "otimização do cache do microsd concluída!"
    _log "otimização do microsd concluída."
}

reverter_sdcard_cache() {
    _log "iniciando reversão do cache do microsd..."
    local sdcard_mount_point
    sdcard_mount_point=$(findmnt -n -o TARGET "$sdcard_device" 2>/dev/null || echo "")
    if [[ -z "$sdcard_mount_point" ]]; then
        _ui_info "erro" "não foi possível encontrar o ponto de montagem para $sdcard_device."
        _log "falha: findmnt não encontrou o ponto de montagem para $sdcard_device."
        return 1
    fi
    _log "microsd detectado em: $sdcard_mount_point"
    local sdcard_steamapps_path="${sdcard_mount_point}/steamapps"
    local sdcard_shadercache_path="${sdcard_steamapps_path}/shadercache"
    if ! [ -L "$sdcard_shadercache_path" ]; then
        _ui_info "erro" "otimização não encontrada."
        _log "falha: link $sdcard_shadercache_path não encontrado."
        return 1
    fi
    _log "removendo link simbólico: $sdcard_shadercache_path"
    rm "$sdcard_shadercache_path"
    _log "recriando diretório original no microsd: $sdcard_shadercache_path"
    mkdir -p "$sdcard_shadercache_path"
    _log "movendo shaders de volta do nvme para o microsd (rsync)..."
    if command -v rsync &>/dev/null; then
         rsync -a --remove-source-files "$nvme_shadercache_target_path"/ "$sdcard_shadercache_path"/ 2>/dev/null || true
         find "$nvme_shadercache_target_path" -type d -empty -delete 2>/dev/null || true
    else
         mv "$nvme_shadercache_target_path"/* "$sdcard_shadercache_path"/ 2>/dev/null || true
         rmdir "$nvme_shadercache_target_path" 2>/dev/null || true
    fi
    _ui_info "sucesso" "reversão do cache do microsd concluída."
    _log "reversão do microsd concluída."
}

_executar_reversao() {
    _steamos_readonly_disable_if_needed;
    _log "iniciando lógica de reversão (limpeza)"
    export otimization_services_str; otimization_services_str=$(declare -p otimization_services)
    export unnecessary_services_str; unnecessary_services_str=$(declare -p unnecessary_services)
    export otimization_scripts_str; otimization_scripts_str=$(declare -p otimization_scripts)
    export -f _restore_file _log manage_unnecessary_services
    export swapfile_path grub_config logfile
    _ui_progress_exec "revertendo alterações" "restaurando backups e limpando configs..." <<BASH
eval "\$otimization_services_str";
eval "\$unnecessary_services_str";
eval "\$otimization_scripts_str"
set -e
echo "parando e desativando serviços customizados..."
# Adicionar zram1 na parada
systemctl stop "\${otimization_services[@]}" zswap-config.service zram-config.service kernel-tweaks.service mem-tweaks.service 2>/dev/null || true
systemctl disable "\${otimization_services[@]}" zswap-config.service zram-config.service kernel-tweaks.service mem-tweaks.service 2>/dev/null || true
echo "removendo arquivos de serviço e scripts..."
for svc_file in "\${otimization_services[@]}"; do rm -f "/etc/systemd/system/\$svc_file"; done
rm -f /etc/systemd/system/zswap-config.service /etc/systemd/system/zram-config.service /etc/systemd/system/kernel-tweaks.service /etc/systemd/system/mem-tweaks.service
for script_file in "\${otimization_scripts[@]}"; do rm -f "\$script_file"; done
rm -f /usr/local/bin/zswap-config.sh /usr/local/bin/zram-config.sh /usr/local/bin/kernel-tweaks.sh /usr/local/bin/mem-tweaks.sh
systemctl stop swap-boost.service 2>/dev/null || true
systemctl disable swap-boost.service 2>/dev/null || true
rm -f /etc/systemd/system/swap-boost.service /usr/local/bin/swap-boost.sh
echo "removendo arquivos de configuração extra..."
rm -f /etc/tmpfiles.d/mglru.conf /etc/tmpfiles.d/thp_shrinker.conf
# NOVO: Remover custom-timers.conf
rm -f /etc/tmpfiles.d/custom-timers.conf
rm -f /etc/modprobe.d/usbhid.conf /etc/modprobe.d/blacklist-zram.conf /etc/modprobe.d/amdgpu.conf
rm -f /etc/modprobe.d/99-gpu-sched.conf /etc/modprobe.d/99-amdgpu-mes.conf /etc/modprobe.d/99-amdgpu-tuning.conf
rm -f /etc/security/limits.d/memlock.conf
echo "removendo swapfile customizado e restaurando /etc/fstab..."
swapoff "\$swapfile_path" 2>/dev/null || true;
rm -f "\$swapfile_path" || true
_restore_file /etc/fstab || true
swapon -a 2>/dev/null || true
echo "restaurando outros arquivos de configuração..."
_restore_file /etc/sysctl.d/99-sdweak-performance.conf || rm -f /etc/sysctl.d/99-sdweak-performance.conf
_restore_file /etc/security/limits.d/99-game-limits.conf || rm -f /etc/security/limits.d/99-game-limits.conf
_restore_file /etc/environment.d/99-game-vars.conf || rm -f /etc/environment.d/99-game-vars.conf
echo "restaurando configuração padrão do irqbalance..."
_restore_file /etc/default/irqbalance || rm -f /etc/default/irqbalance
echo "reativando serviços padrão do sistema..."
manage_unnecessary_services "enable"
systemctl unmask systemd-zram-setup@zram0.service 2>/dev/null || true
systemctl unmask systemd-zram-setup@.service 2>/dev/null || true
echo "reativando irqbalance com config padrão..."
systemctl unmask irqbalance.service 2>/dev/null || true
systemctl enable irqbalance.service 2>/dev/null || true
systemctl restart irqbalance.service 2>/dev/null || true
echo "reativando serviço steamos cfs-debugfs..."
systemctl unmask steamos-cfs-debugfs-tunings.service 2>/dev/null || true
systemctl enable --now steamos-cfs-debugfs-tunings.service 2>/dev/null || true
if command -v setenforce &>/dev/null; then setenforce 1 2>/dev/null || true; fi
echo "recarregando systemd e atualizando grub..."
systemctl daemon-reload || true
steamos-update-grub &>/dev/null || update-grub &>/dev/null || true
echo "atualizando initramfs (revertendo amdgpu)..."
mkinitcpio -P &>/dev/null || true
sysctl --system || true
sync
BASH
}

aplicar_zswap() {
    _log "garantindo aplicação limpa: executando reversão primeiro."
    _executar_reversao
    _log "reversão (limpeza) concluída. prosseguindo com a aplicação (zswap)."
    _steamos_readonly_disable_if_needed;
    _log "desativando selinux (se existir)..."
    if command -v setenforce &>/dev/null; then setenforce 0 2>/dev/null || true; fi
    _optimize_gpu
    _log "criando e ativando serviços de otimização (pré-etapa)..."
    create_common_scripts_and_services
    _configure_irqbalance
    _log "aplicando otimizações com zswap (etapa principal)..."
    local free_space_gb;
    free_space_gb=$(df -BG /home | awk 'NR==2 {print $4}' | tr -d 'G' || echo 0)
    if (( free_space_gb < zswap_swapfile_size_gb )); then
        _ui_info "erro crítico" "espaço em disco insuficiente."; _log "execução abortada."; exit 1;
    fi
    local final_sysctl_params=("${base_sysctl_params[@]}")
    if [[ -f "/proc/sys/kernel/sched_bore" ]]; then
        _log "bore scheduler detectado."; final_sysctl_params+=("${bore_params[@]}")
    fi
    _log "iniciando bloco principal de aplicação (zswap)..."
    (
    set -e
    systemctl stop zram-config.service 2>/dev/null || true
    systemctl disable zram-config.service 2>/dev/null || true
    rm -f /etc/systemd/system/zram-config.service 2>/dev/null || true
    rm -f /usr/local/bin/zram-setup.sh 2>/dev/null || true
    systemctl daemon-reload
    swapoff /dev/zram0 2>/dev/null || true
    rmmod zram 2>/dev/null || true
    create_module_blacklist
    systemctl stop systemd-zram-setup@zram0.service 2>/dev/null || true
    systemctl mask systemd-zram-setup@zram0.service 2>/dev/null || true
    systemctl mask systemd-zram-setup@.service 2>/dev/null || true
    manage_unnecessary_services "disable"
    _backup_file_once /etc/fstab
    if grep -q " /home " /etc/fstab 2>/dev/null; then
        sed -E -i 's|(^[^[:space:]]+[[:space:]]+/home[[:space:]]+[^[:space:]]+[[:space:]]+ext4[[:space:]]+)[^[:space:]]+|\1defaults,nofail,lazytime,commit=60,data=writeback,x-systemd.growfs|g' /etc/fstab || true
    fi
    swapoff "$swapfile_path" 2>/dev/null || true; rm -f "$swapfile_path" || true
    if command -v fallocate &>/dev/null; then
        fallocate -l "${zswap_swapfile_size_gb}G" "$swapfile_path" 2>/dev/null || dd if=/dev/zero of="$swapfile_path" bs=1G count="$zswap_swapfile_size_gb" status=progress
    else
        dd if=/dev/zero of="$swapfile_path" bs=1G count="$zswap_swapfile_size_gb" status=progress
    fi
    chmod 600 "$swapfile_path" || true; mkswap "$swapfile_path" || true
    sed -i "\|${swapfile_path}|d" /etc/fstab 2>/dev/null || true;
    echo "$swapfile_path none swap sw,pri=-2 0 0" >> /etc/fstab
    swapon --priority -2 "$swapfile_path" || true
    _write_sysctl_file /etc/sysctl.d/99-sdweak-performance.conf "${final_sysctl_params[@]}";
    sysctl --system || true
    # <<<<<<<<< CORREÇÃO PARA FORÇAR APLICAÇÃO DO EXTRA_FREE_KBYTES >>>>>>>>>>>
    sysctl -w vm.extra_free_kbytes=131072 2>/dev/null || true
    # <<<<<<<<< FIM DA CORREÇÃO DE APLICAÇÃO >>>>>>>>>>>>>
    _backup_file_once /etc/security/limits.d/99-game-limits.conf
    cat <<'EOF' > /etc/security/limits.d/99-game-limits.conf
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    _log "aplicando limites de memlock..."
    cat << EOF | tee /etc/security/limits.d/memlock.conf &>/dev/null
* hard memlock 2147484
* soft memlock 2147484
EOF
    _backup_file_once "$grub_config"
    # Mantendo zstd conforme v1.2.2
    local kernel_params=(
        "zswap.enabled=1"
        "zswap.compressor=zstd"
        "zswap.max_pool_percent=30"
        "zswap.zpool=zsmalloc"
        "zswap.shrinker_enabled=1"
        "mitigations=off"
        "psi=1"
        "rcutree.enable_rcu_lazy=1"
    )
    local current_cmdline; current_cmdline=$(grep -E '^GRUB_CMDLINE_LINUX=' "$grub_config" | sed -E 's/^GRUB_CMDLINE_LINUX="([^"]*)"(.*)/\1/' || true)
    local new_cmdline="$current_cmdline"
    for param in "${kernel_params[@]}"; do local key="${param%%=*}"; new_cmdline=$(echo "$new_cmdline" | sed -E "s/ ?${key}(=[^ ]*)?//g"); done
    for param in "${kernel_params[@]}"; do new_cmdline="$new_cmdline $param"; done
    new_cmdline=$(echo "$new_cmdline" | tr -s ' ' | sed -E 's/^ //; s/ $//')
    sed -i -E "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$new_cmdline\"|" "$grub_config" || true
    steamos-update-grub &>/dev/null || update-grub &>/dev/null || true
    mkinitcpio -P &>/dev/null || true
    create_timer_configs # <-- CHAMADA DA FUNÇÃO DE TIMER
    create_persistent_configs
    _backup_file_once /etc/environment.d/99-game-vars.conf;
    printf "%s\n" "${game_env_vars[@]}" > /etc/environment.d/99-game-vars.conf
    # Mantendo zstd conforme v1.2.2
    cat <<'ZSWAP_SCRIPT' > /usr/local/bin/zswap-config.sh
#!/usr/bin/env bash
echo 1 > /sys/module/zswap/parameters/enabled 2>/dev/null || true
echo zstd > /sys/module/zswap/parameters/compressor 2>/dev/null || true
echo 30 > /sys/module/zswap/parameters/max_pool_percent 2>/dev/null || true
echo zsmalloc > /sys/module/zswap/parameters/zpool 2>/dev/null || true
echo 1 > /sys/module/zswap/parameters/shrinker_enabled 2>/dev/null || true
ZSWAP_SCRIPT
    chmod +x /usr/local/bin/zswap-config.sh
    cat <<UNIT > /etc/systemd/system/zswap-config.service
[Unit]
Description=aplicar configuracoes zswap (zstd)
[Service]
Type=oneshot
ExecStart=/usr/local/bin/zswap-config.sh
RemainAfterExit=true
[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload || true;
    systemctl enable --now "${otimization_services[@]}" zswap-config.service || true;
    systemctl enable --now fstrim.timer 2>/dev/null || true
    sync
    )
    if [ $? -ne 0 ]; then _ui_info "erro" "falha na aplicação (zswap). log: $logfile"; return 1; fi
    _ui_info "sucesso" "otimacoes (zswap zstd) aplicadas com sucesso. reinicie o sistema."; return 0
}

aplicar_zram() {
    _log "garantindo aplicação limpa: executando reversão primeiro."
    _executar_reversao
    _log "reversão (limpeza) concluída. prosseguindo com a aplicação (zram)."
    _steamos_readonly_disable_if_needed;
    _log "desativando selinux (se existir)..."
    if command -v setenforce &>/dev/null; then setenforce 0 2>/dev/null || true; fi
    _optimize_gpu
    _log "criando e ativando serviços de otimização (pré-etapa)..."
    create_common_scripts_and_services
    _configure_irqbalance
    _log "aplicando otimizações com ZRAM em camadas (etapa principal)..."
    local free_space_gb;
    free_space_gb=$(df -BG /home | awk 'NR==2 {print $4}' | tr -d 'G' || echo 0)
    # Requer que o espaço seja suficiente apenas para o swapfile de disco de backup, se mantido.
    # O ZRAM é virtual, mas manter a verificação mínima por segurança.
    if (( free_space_gb < zram_swapfile_size_gb )); then
        _ui_info "aviso" "espaço em disco baixo, mas suficiente para ZRAM virtual. Prosseguindo."
    fi
    local final_sysctl_params=("${base_sysctl_params[@]}")
    if [[ -f "/proc/sys/kernel/sched_bore" ]]; then
        _log "bore scheduler detectado."; final_sysctl_params+=("${bore_params[@]}")
    fi
    _log "iniciando bloco principal de aplicação (Dual ZRAM)..."
    (
    set -e
    systemctl stop zram-config.service 2>/dev/null || true
    systemctl disable zram-config.service 2>/dev/null || true
    rm -f /etc/systemd/system/zram-config.service 2>/dev/null || true
    rm -f /usr/local/bin/zram-setup.sh 2>/dev/null || true
    systemctl daemon-reload
    # Parar e descarregar ZRAM existente
    swapoff /dev/zram0 2>/dev/null || true
    swapoff /dev/zram1 2>/dev/null || true # Adicionado zram1
    rmmod zram 2>/dev/null || true
    rm -f /etc/modprobe.d/blacklist-zram.conf # Removendo blacklist para permitir ZRAM
    systemctl stop systemd-zram-setup@zram0.service 2>/dev/null || true
    systemctl mask systemd-zram-setup@zram0.service 2>/dev/null || true
    systemctl mask systemd-zram-setup@.service 2>/dev/null || true
    manage_unnecessary_services "disable"
    _backup_file_once /etc/fstab
    if grep -q " /home " /etc/fstab 2>/dev/null; then
        sed -E -i 's|(^[^[:space:]]+[[:space:]]+/home[[:space:]]+[^[:space:]]+[[:space:]]+ext4[[:space:]]+)[^[:space:]]+|\1defaults,nofail,lazytime,commit=60,data=writeback,x-systemd.growfs|g' /etc/fstab || true
    fi
    # Mantenho o código que cria um pequeno swapfile de disco de baixa prioridade (-2) como um "último recurso".
    swapoff "$swapfile_path" 2>/dev/null || true; rm -f "$swapfile_path" || true
    if command -v fallocate &>/dev/null; then
        # Mantendo o tamanho pequeno (2G) para o swapfile de backup em disco
        fallocate -l "${zram_swapfile_size_gb}G" "$swapfile_path" 2>/dev/null || dd if=/dev/zero of="$swapfile_path" bs=1G count="$zram_swapfile_size_gb" status=progress
    else
        dd if=/dev/zero of="$swapfile_path" bs=1G count="$zram_swapfile_size_gb" status=progress
    fi
    chmod 600 "$swapfile_path" || true; mkswap "$swapfile_path" || true
    sed -i "\|${swapfile_path}|d" /etc/fstab 2>/dev/null || true;
    # Swapfile de disco com prioridade muito baixa para ser o último a ser usado
    echo "$swapfile_path none swap sw,pri=-2 0 0" >> /etc/fstab
    swapon --priority -2 "$swapfile_path" || true
    _write_sysctl_file /etc/sysctl.d/99-sdweak-performance.conf "${final_sysctl_params[@]}";
    sysctl --system || true
    # <<<<<<<<< CORREÇÃO PARA FORÇAR APLICAÇÃO DO EXTRA_FREE_KBYTES >>>>>>>>>>>
    sysctl -w vm.extra_free_kbytes=131072 2>/dev/null || true
    # <<<<<<<<< FIM DA CORREÇÃO DE APLICAÇÃO >>>>>>>>>>>>>
    _backup_file_once /etc/security/limits.d/99-game-limits.conf
    cat <<'EOF' > /etc/security/limits.d/99-game-limits.conf
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    _log "aplicando limites de memlock..."
    cat << EOF | tee /etc/security/limits.d/memlock.conf &>/dev/null
* hard memlock 2147484
* soft memlock 2147484
EOF
    _backup_file_once "$grub_config"
    local kernel_params=("mitigations=off" "psi=1" "rcutree.enable_rcu_lazy=1")
    local current_cmdline; current_cmdline=$(grep -E '^GRUB_CMDLINE_LINUX=' "$grub_config" | sed -E 's/^GRUB_CMDLINE_LINUX="([^"]*)"(.*)/\1/' || true)
    local new_cmdline="$current_cmdline"
    for param in "${kernel_params[@]}"; do local key="${param%%=*}"; new_cmdline=$(echo "$new_cmdline" | sed -E "s/ ?${key}(=[^ ]*)?//g" | sed -E "s/ ?zswap\.[^ =]+(=[^ ]*)?//g"); done
    for param in "${kernel_params[@]}"; do new_cmdline="$new_cmdline $param"; done
    new_cmdline=$(echo "$new_cmdline" | tr -s ' ' | sed -E 's/^ //; s/ $//')
    sed -i -E "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$new_cmdline\"|" "$grub_config" || true
    steamos-update-grub &>/dev/null || update-grub &>/dev/null || true
    mkinitcpio -P &>/dev/null || true
    create_timer_configs # <-- CHAMADA DA FUNÇÃO DE TIMER
    create_persistent_configs
    _backup_file_once /etc/environment.d/99-game-vars.conf;
    printf "%s\n" "${game_env_vars[@]}" > /etc/environment.d/99-game-vars.conf

    # NOVO SCRIPT PARA DUAL ZRAM COM CORREÇÃO DE RMMOD
    cat <<'ZRAM_SCRIPT' > /usr/local/bin/zram-config.sh
#!/usr/bin/env bash
# CORREÇÃO: Força o descarregamento do módulo para que o 'num_devices=2' seja aplicado no próximo carregamento.
swapoff /dev/zram0 2>/dev/null || true
swapoff /dev/zram1 2>/dev/null || true
rmmod zram 2>/dev/null || true

# 1. Carregar módulo ZRAM com 2 dispositivos (necessita do rmmod acima para funcionar)
modprobe zram num_devices=2 2>/dev/null || true

# --- ZRAM 0: Rápido (Prioridade 3000) ---
# Tamanho: 4GB, Compressor: lz4, Pool: zsmalloc
if [ -b /dev/zram0 ]; then
    echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
    echo zsmalloc > /sys/block/zram0/zpool 2>/dev/null || true
    echo 4G > /sys/block/zram0/disksize 2>/dev/null || true
    mkswap /dev/zram0 2>/dev/null || true
    swapon /dev/zram0 -p 3000 2>/dev/null || true
    echo "ZRAM0 (4G, lz4, prio 3000) configurado."
fi

# --- ZRAM 1: Mais Compressão (Prioridade 10) ---
# Tamanho: 8GB, Compressor: zstd, Pool: zsmalloc
if [ -b /dev/zram1 ]; then
    echo zstd > /sys/block/zram1/comp_algorithm 2>/dev/null || true
    echo zsmalloc > /sys/block/zram1/zpool 2>/dev/null || true
    echo 8G > /sys/block/zram1/disksize 2>/dev/null || true
    mkswap /dev/zram1 2>/dev/null || true
    swapon /dev/zram1 -p 10 2>/dev/null || true
    echo "ZRAM1 (8G, zstd, prio 10) configurado."
fi

ZRAM_SCRIPT
    chmod +x /usr/local/bin/zram-config.sh
    cat <<UNIT > /etc/systemd/system/zram-config.service
[Unit]
Description=configuracao otimizada de ZRAM em Camadas (Dual ZRAM)
After=local-fs.target
Requires=local-fs.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/zram-config.sh
RemainAfterExit=true
[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload || true;
    systemctl enable --now "${otimization_services[@]}" zram-config.service || true;
    systemctl enable --now fstrim.timer 2>/dev/null || true
    sync
    )
    if [ $? -ne 0 ]; then _ui_info "erro" "falha na aplicação (Dual ZRAM). log: $logfile"; return 1; fi
    _ui_info "sucesso" "otimacoes (Dual ZRAM) aplicadas com sucesso. reinicie o sistema."; return 0
}

reverter_alteracoes() {
    _log "iniciando reversão completa das alterações (via menu)"
    _executar_reversao
    _ui_info "reversão" "reversão completa concluída. reinicie o sistema.";
    _log "reversão completa executada"
}

main() {
    local texto_inicial="autor: $autor\n\ndoações (pix): $pix_doacao\n\nEste programa aplica um conjunto abrangente de otimizações de memória, i/o e sistema no steamos. todas as alterações podem ser revertidas."
    echo -e "\n======================================================="
    echo -e " Bem-vindo(a) ao utilitário Turbo Decky (v$versao)"
    echo -e "=======================================================\n$texto_inicial\n\n-------------------------------------------------------\n"
    echo "opções de otimização principal:"
    echo "1) Aplicar Otimizações Recomendadas (ZSwap + Swapfile)"
    echo "2) Aplicar Otimizações para deck com pouco espaço livre. ZRAM em Camadas"
    echo ""
    echo "opções de microsd:"
    echo "3) Otimizar cache de jogos do MicroSD (Mover shaders para o NVMe)"
    echo ""
    echo "reversão:"
    echo "4) Reverter otimizações principais do SteamOs"
    echo "5) Reverter otimização do cache do MicroSD"
    echo ""
    echo "6) Sair"
    read -rp "escolha uma opção: " escolha
    case "$escolha" in
    1) aplicar_zswap ;;
    2) aplicar_zram ;;
    3) otimizar_sdcard_cache ;;
    4) reverter_alteracoes ;;
    5) reverter_sdcard_cache ;;
    6) _ui_info "saindo" "nenhuma alteração foi feita."; exit 0 ;;
    *) _ui_info "erro" "opção inválida."; exit 1 ;;
    esac
}

main "$@"

