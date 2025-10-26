#!/usr/bin/env bash
set -euo pipefail

# --- versão e autor do script ---
versao="1.0.17 Flash"
autor="Jorge Luis"
pix_doacao="jorgezarpon@msn.com"

# --- constantes e variáveis ---
readonly swapfile_path="/home/swapfile"
readonly grub_config="/etc/default/grub"
readonly zswap_swapfile_size_gb="8"
readonly backup_suffix="bak-turbodecky"
readonly logfile="/var/log/turbodecky.log"

# --- Constantes para otimização do MicroSD ---
# O dispositivo do microsd
readonly sdcard_device="/dev/mmcblk0p1"
# O diretório de destino no NVMe (SSD interno)
readonly nvme_shadercache_target_path="/home/deck/sd_shadercache"

# --- parâmetros sysctl base ---
readonly base_sysctl_params=(
    "vm.swappiness=40"
    "vm.vfs_cache_pressure=66"
   "vm.dirty_background_bytes=209715200"
    "vm.dirty_bytes=419430400"
    "vm.dirty_expire_centisecs=1500"
    "vm.dirty_writeback_centisecs=1500"
    "vm.min_free_kbytes=121634"
    "vm.page-cluster=0"
    "vm.page_lock_unfairness=8"
    "vm.watermark_scale_factor=125"
    "vm.stat_interval=15"
    "vm.compact_unevictable_allowed=0"
    "vm.compaction_proactiveness=10"
    "vm.hugetlb_optimize_vmemmap=0"
    "vm.watermark_boost_factor=0"
    "vm.overcommit_memory=1"
    "vm.overcommit_ratio=100"
    "vm.zone_reclaim_mode=0"
    "fs.aio-max-nr=131072"
    "fs.epoll.max_user_watches=100000"
    "fs.inotify.max_user_watches=65536"
    "fs.pipe-max-size=2097152"
    "fs.pipe-user-pages-soft=65536"
    "fs.file-max=1000000"
    "kernel.nmi_watchdog=0"
    "kernel.soft_watchdog=0"
    "kernel.watchdog=0"
    "kernel.sched_autogroup_enabled=0"
    "kernel.numa_balancing=0"
    "kernel.io_delay_type=3"
    "kernel.core_pattern=/dev/null"
    "kernel.core_pipe_limit=0"
    "kernel.printk_devkmsg=off"
    "kernel.timer_migration=0"
    "kernel.perf_cpu_time_max_percent=1"
 "kernel.perf_event_max_contexts_per_stack=1"
   "kernel.perf_event_max_sample_rate=1"
    "kernel.perf_event_max_stack=1"
    "kernel.printk_ratelimit_burst=1"
    "net.core.default_qdisc=fq_codel"
   "net.ipv4.tcp_congestion_control=bbr"
)

# --- parâmetros específicos do agendador bore ---
readonly bore_params=(
    "kernel.sched_bore=1" "kernel.sched_burst_cache_lifetime=40000000"
   "kernel.sched_burst_fork_atavistic=2"
    "kernel.sched_burst_penalty_offset=26"
    "kernel.sched_burst_penalty_scale=1000"
    "kernel.sched_burst_smoothness_long=0"
    "kernel.sched_burst_smoothness_short=0"
    "kernel.sched_burst_exclude_kthreads=1"
    "kernel.sched_burst_parity_threshold=1"
)

# --- parâmetros de fallback para o agendador cfs ---
readonly cfs_params=(
    "kernel.sched_cfs_aggressive_slice_reduction=1"
    "kernel.sched_cfs_slice_scaling_factor=1"
    "kernel.sched_cfs_target_latency_factor=2"
)

# --- listas de serviços ---
readonly otimization_services=(
    "thp-config.service"
    "io-boost.service"
    "zswap-config.service"
    "hugepages.service"
    "ksm-config.service"
    "kernel-tweaks.service"
    "mem-tweaks.service"
)
readonly otimization_scripts=(
    "/usr/local/bin/thp-config.sh"
    "/usr/local/bin/io-boost.sh"
    "/usr/local/bin/zswap-config.sh"
    "/usr/local/bin/hugepages.sh"
    "/usr/local/bin/ksm-config.sh"
    "/usr/local/bin/kernel-tweaks.sh"
    "/usr/local/bin/mem-tweaks.sh"
)
readonly unnecessary_services=(
    "steamos-cfs-debugfs-tunings.service"
    "gpu-trace.service"
    "steamos-log-submitter.service"
    "cups.service"
)

# --- variáveis de ambiente ---
readonly game_env_vars=(
  "RADV_PERFTEST=gpl"
  "MESA_GLTHREAD=true"
  "WINEFSYNC=1"
  "MESA_SHADER_CACHE_MAX_SIZE=20G"
  "DXVK_ASYNC=1"
  "MESA_VK_ENABLE_ABOVE_4G=true"
)
# --- Funções ---

_ui_info() {
    echo -e "\n[info] $1: $2";
}

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
    fi
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
    fi
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
    _log "aplicando otimizações amdgpu automaticamente..."
    mkdir -p /etc/modprobe.d

    # Aplica as configurações do amdgpu.conf
    echo "options amdgpu sched_policy=0 mes=1 moverate=128 uni_mes=1 lbpw=0 mes_kiq=1" > /etc/modprobe.d/amdgpu.conf

    _ui_info "gpu" "otimizações amdgpu (MES, FIFO) aplicadas automaticamente."
    _log "arquivo /etc/modprobe.d/amdgpu.conf criado/atualizado."
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

    echo "options usbhid jspoll=1 kbpoll=1 mousepoll=1" > /etc/modprobe.d/usbhid.conf
    _log "configurações persistentes para mglru, thp shrinker e usb hid criadas."
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

# --- FUNÇÃO create_common_scripts_and_services CORRIGIDA (v1.5) ---
create_common_scripts_and_services() {
    _log "criando/atualizando scripts e services comuns"
    mkdir -p /usr/local/bin /etc/systemd/system /etc/environment.d

cat <<'IOB' > /usr/local/bin/io-boost.sh
#!/usr/bin/env bash
sleep 5
for dev_path in /sys/block/sd* /sys/block/mmcblk* /sys/block/nvme*n*; do
    [ -d "$dev_path" ] || continue
    dev_name=$(basename "$dev_path")
    queue_path="$dev_path/queue"

    echo 0 > "$queue_path/iostats" 2>/dev/null || true
    echo 0 > "$queue_path/add_random" 2>/dev/null || true

    case "$dev_name" in
    nvme*)
        # Tenta definir o agendador
        if [[ -w "$queue_path/scheduler" ]] && grep -q "kyber" "$queue_path/scheduler"; then
            echo "kyber" > "$queue_path/scheduler" 2>/dev/null || true
        elif [ -w "$queue_path/scheduler" ]; then
            echo "mq-deadline" > "$queue_path/scheduler" 2>/dev/null || true

            # --- Otimizações específicas do MQ-DEADLINE (não se aplicam ao Kyber) ---
            echo 6000000 > "$queue_path/iosched/write_lat_nsec" 2>/dev/null || true
            echo 1200000 > "$queue_path/iosched/read_lat_nsec" 2>/dev/null || true
        fi

        # --- Otimizações gerais de NVMe (aplicáveis a Kyber e MQ-Deadline) ---
        echo 512 > "$queue_path/read_ahead_kb" 2>/dev/null || true
        echo 1024 > "$queue_path/nr_requests" 2>/dev/null || true
        echo 2 > "$queue_path/nomerges" 2>/dev/null || true
        echo 999 > "$queue_path/wbt_lat_usec" 2>/dev/null || true
        ;;

    mmcblk*|sd*)
        # Tenta definir o agendador
        if [[ -w "$queue_path/scheduler" ]] && grep -q "bfq" "$queue_path/scheduler"; then
            echo "bfq" > "$queue_path/scheduler" 2>/dev/null || true

            # --- Otimizações específicas do BFQ ---
            echo 1 > "$queue_path/iosched/low_latency" 2>/dev/null || true
            echo 0 > "$queue_path/iosched/slice_idle_us" 2>/dev/null || true
            echo 1 > "$queue_path/iosched/back_seek_penalty" 2>/dev/null || true
            echo 200 > "$queue_path/iosched/fifo_expire_async" 2>/dev/null || true
            echo 100 > "$queue_path/iosched/fifo_expire_sync" 2>/dev/null || true
            echo 0 > "$queue_path/iosched/slice_idle" 2>/dev/null || true
            echo 100 > "$queue_path/iosched/timeout_sync" 2>/dev/null || true

        elif [ -w "$queue_path/scheduler" ]; then
            echo "mq-deadline" > "$queue_path/scheduler" 2>/dev/null || true
        fi

        # --- Otimizações gerais de microSD/SD (aplicáveis a BFQ e MQ-Deadline) ---
        echo 1024 > "$queue_path/read_ahead_kb" 2>/dev/null || true
        echo 2 > "$queue_path/rq_affinity" 2>/dev/null || true
        echo 2000 > "$queue_path/wbt_lat_usec" 2>/dev/null || true
        ;;
    esac
done
IOB
    chmod +x /usr/local/bin/io-boost.sh

cat <<'THP' > /usr/local/bin/thp-config.sh
#!/usr/bin/env bash
echo "always" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo "defer+madvise" > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
echo "advise" > /sys/kernel/mm/transparent_hugepage/shmem_enabled 2>/dev/null || true
echo 1 > /sys/kernel/mm/transparent_hugepage/khugepaged/defrag 2>/dev/null || true
echo 2048 > /sys/kernel/mm/transparent_hugepage/khugepaged/pages_to_scan 2>/dev/null || true
echo 5000 > /sys/kernel/mm/transparent_hugepage/khugepaged/scan_sleep_millisecs 2>/dev/null || true
echo 50000 > /sys/kernel/mm/transparent_hugepage/khugepaged/alloc_sleep_millisecs 2>/dev/null || true
echo 128 > /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_swap 2>/dev/null || true
THP
    chmod +x /usr/local/bin/thp-config.sh

cat <<'KTS' > /usr/local/bin/kernel-tweaks.sh
#!/usr/bin/env bash
echo 0 > /sys/kernel/debug/exception-trace 2>/dev/null || true
echo 0 > /proc/sys/kernel/ftrace_enabled 2>/dev/null || true
echo 2048 > /sys/class/rtc/rtc0/max_user_freq 2>/dev/null || true
echo 2048 > /proc/sys/dev/hpet/max-user-freq 2>/dev/null || true
echo NO_PLACE_LAG > /sys/kernel/debug/sched/features 2>/dev/null || true
echo NO_RUN_TO_PARITY > /sys/kernel/debug/sched/features 2>/dev/null || true
echo NEXT_BUDDY > /sys/kernel/debug/sched/features 2>/dev/null || true
echo 1000000 > /sys/kernel/debug/sched/migration_cost_ns 2>/dev/null || true
echo 4 > /sys/kernel/debug/sched/nr_migrate 2>/dev/null || true
KTS
    chmod +x /usr/local/bin/kernel-tweaks.sh

cat <<'HPS' > /usr/local/bin/hugepages.sh
#!/usr/bin/env bash
echo 256 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages 2>/dev/null || true
HPS
    chmod +x /usr/local/bin/hugepages.sh

cat <<'KSM' > /usr/local/bin/ksm-config.sh
#!/usr/bin/env bash
echo 0 > /sys/kernel/mm/ksm/run 2>/dev/null || true
echo 2 > /sys/kernel/mm/ksm/merge_across_nodes 2>/dev/null || true
KSM
    chmod +x /usr/local/bin/ksm-config.sh

cat <<'MMT' > /usr/local/bin/mem-tweaks.sh
#!/usr/bin/env bash
echo 1 > /sys/module/multi_queue/parameters/multi_queue_alloc 2>/dev/null || true
echo 1 > /sys/module/multi_queue/parameters/multi_queue_reclaim 2>/dev/null || true
MMT
    chmod +x /usr/local/bin/mem-tweaks.sh

    # Cria os serviços (sem o selinux-config)
    for service_name in thp-config io-boost hugepages ksm-config kernel-tweaks mem-tweaks; do
        description="";
        case "$service_name" in
            thp-config) description="configuracao otimizada de thp";;
            io-boost) description="otimização de i/o e agendadores de disco";;
            hugepages) description="aloca huge pages para jogos";;
            ksm-config) description="desativa kernel samepage merging (ksm)";;
            kernel-tweaks) description="aplica tweaks diversos no kernel";;
            mem-tweaks) description="otimização de alocacao de memoria";;
        esac

# --- CORREÇÃO: Removido aspas simples de UNIT ---
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

    # Cria o serviço zswap-config separadamente (ele tem seu script criado dentro do bloco principal)
# --- CORREÇÃO: Removido aspas simples de UNIT ---
cat <<UNIT > /etc/systemd/system/zswap-config.service
[Unit]
Description=aplicar configuracoes zswap
[Service]
Type=oneshot
ExecStart=/usr/local/bin/zswap-config.sh
RemainAfterExit=true
[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload || true
    _log "scripts e services comuns criados/atualizados e instalados."
}
# --- FIM DA FUNÇÃO CORRIGIDA ---


# --- NOVA FUNÇÃO DE OTIMIZAÇÃO DO MICROSD (com detecção automática) ---
otimizar_sdcard_cache() {
    _log "iniciando otimização de cache do microsd..."

    # --- Detecção dinâmica do ponto de montagem ---
    local sdcard_mount_point
    sdcard_mount_point=$(findmnt -n -o TARGET "$sdcard_device" 2>/dev/null || echo "")

    if [[ -z "$sdcard_mount_point" ]]; then
        _ui_info "erro" "não foi possível encontrar o ponto de montagem para $sdcard_device. o microsd está inserido?"
        _log "falha: findmnt não encontrou o ponto de montagem para $sdcard_device."
        return 1
    fi
    _log "microsd detectado em: $sdcard_mount_point"
    # --- Fim da detecção ---

    # Define os caminhos dinamicamente
    local sdcard_steamapps_path="${sdcard_mount_point}/steamapps"
    local sdcard_shadercache_path="${sdcard_steamapps_path}/shadercache"

    # 1. Verifica se a pasta steamapps existe
    if ! [ -d "$sdcard_steamapps_path" ]; then
        _ui_info "erro" "diretório 'steamapps' não encontrado em $sdcard_mount_point. o microsd está formatado pelo steam?"
        _log "falha: $sdcard_steamapps_path não encontrado."
        return 1
    fi

    # 2. Verifica se já não foi otimizado (se é um link simbólico)
    if [ -L "$sdcard_shadercache_path" ]; then
        _ui_info "info" "o cache do microsd já parece estar otimizado (link simbólico encontrado)."
        _log "otimização do microsd já aplicada."
        return 0
    fi

    # 3. Cria o diretório de destino no NVMe
    _log "criando diretório de destino no nvme: $nvme_shadercache_target_path"
    mkdir -p "$nvme_shadercache_target_path"

    # 4. Tenta descobrir o usuário e grupo de /home/deck para definir as permissões corretas
    local deck_user
    local deck_group
    deck_user=$(stat -c '%U' /home/deck 2>/dev/null || echo "deck")
    deck_group=$(stat -c '%G' /home/deck 2>/dev/null || echo "deck")

    _log "ajustando permissões de $nvme_shadercache_target_path para ${deck_user}:${deck_group}"
    chown "${deck_user}:${deck_group}" "$nvme_shadercache_target_path" 2>/dev/null || true

    # 5. Move os shaders existentes (se a pasta existir) do microsd para o NVMe
    if [ -d "$sdcard_shadercache_path" ]; then
        _log "movendo shaders existentes do microsd para o nvme..."
        # O '|| true' é vital caso a pasta esteja vazia ou dê erro
        mv "$sdcard_shadercache_path"/* "$nvme_shadercache_target_path"/ 2>/dev/null || true
        _log "movimentação concluída. removendo diretório original."
        rmdir "$sdcard_shadercache_path" 2>/dev/null || true
    else
        _log "diretório de cache original não encontrado no microsd. pulando etapa de 'mv'."
    fi

    # 6. Cria o link simbólico
    _log "criando link simbólico: $sdcard_shadercache_path -> $nvme_shadercache_target_path"
    ln -s "$nvme_shadercache_target_path" "$sdcard_shadercache_path"

    _ui_info "sucesso" "otimização do cache do microsd concluída! os shaders agora serão salvos no nvme."
    _log "otimização do microsd concluída."
}

# --- NOVA FUNÇÃO DE REVERSÃO DO MICROSD (com detecção automática) ---
reverter_sdcard_cache() {
    _log "iniciando reversão do cache do microsd..."

    # --- Detecção dinâmica do ponto de montagem ---
    local sdcard_mount_point
    sdcard_mount_point=$(findmnt -n -o TARGET "$sdcard_device" 2>/dev/null || echo "")

    if [[ -z "$sdcard_mount_point" ]]; then
        _ui_info "erro" "não foi possível encontrar o ponto de montagem para $sdcard_device. o microsd está inserido?"
        _log "falha: findmnt não encontrou o ponto de montagem para $sdcard_device."
        return 1
    fi
    _log "microsd detectado em: $sdcard_mount_point"
    # --- Fim da detecção ---

    # Define os caminhos dinamicamente
    local sdcard_steamapps_path="${sdcard_mount_point}/steamapps"
    local sdcard_shadercache_path="${sdcard_steamapps_path}/shadercache"

    # 1. Verifica se a otimização foi aplicada (se é um link simbólico)
    if ! [ -L "$sdcard_shadercache_path" ]; then
        _ui_info "erro" "otimização não encontrada. o cache do microsd não parece estar usando um link simbólico."
        _log "falha: link $sdcard_shadercache_path não encontrado."
        return 1
    fi

    _log "removendo link simbólico: $sdcard_shadercache_path"
    rm "$sdcard_shadercache_path"

    _log "recriando diretório original no microsd: $sdcard_shadercache_path"
    mkdir -p "$sdcard_shadercache_path"

    _log "movendo shaders de volta do nvme para o microsd..."
    mv "$nvme_shadercache_target_path"/* "$sdcard_shadercache_path"/ 2>/dev/null || true
    _log "movimentação concluída. removendo diretório do nvme."

    rmdir "$nvme_shadercache_target_path" 2>/dev/null || true

    _ui_info "sucesso" "reversão do cache do microsd concluída. os caches voltarão a ser salvos no microsd."
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
# Adiciona zswap-config.service à lista de parada/desativação da reversão
systemctl stop "\${otimization_services[@]}" zswap-config.service 2>/dev/null || true
systemctl disable "\${otimization_services[@]}" zswap-config.service 2>/dev/null || true

echo "removendo arquivos de serviço e scripts..."
for svc_file in "\${otimization_services[@]}" zswap-config.service; do # Adiciona zswap-config.service
    rm -f "/etc/systemd/system/\$svc_file";
done
for script_file in "\${otimization_scripts[@]}"; do
    rm -f "\$script_file";
done

echo "garantindo a remoção do swap-boost.service legado (se existir)..."
systemctl stop swap-boost.service 2>/dev/null || true
systemctl disable swap-boost.service 2>/dev/null || true
rm -f /etc/systemd/system/swap-boost.service
rm -f /usr/local/bin/swap-boost.sh

echo "removendo arquivos de configuração extra..."
rm -f /etc/tmpfiles.d/mglru.conf /etc/tmpfiles.d/thp_shrinker.conf
rm -f /etc/modprobe.d/usbhid.conf /etc/modprobe.d/blacklist-zram.conf
rm -f /etc/modprobe.d/amdgpu.conf

echo "removendo swapfile customizado e restaurando /etc/fstab..."
swapoff "\$swapfile_path" 2>/dev/null || true;
rm -f "\$swapfile_path" || true
_restore_file /etc/fstab || true
swapon -a 2>/dev/null || true

echo "restaurando outros arquivos de configuração..."
_restore_file "\$grub_config" || true
_restore_file /etc/sysctl.d/99-sdweak-performance.conf || rm -f /etc/sysctl.d/99-sdweak-performance.conf
_restore_file /etc/security/limits.d/99-game-limits.conf || rm -f /etc/security/limits.d/99-game-limits.conf
_restore_file /etc/environment.d/99-game-vars.conf || rm -f /etc/environment.d/99-game-vars.conf

echo "reativando serviços padrão do sistema..."
manage_unnecessary_services "enable"
systemctl unmask systemd-zram-setup@zram0.service 2>/dev/null || true
systemctl unmask systemd-zram-setup@.service 2>/dev/null || true
systemctl enable --now irqbalance.service 2>/dev/null || true
if command -v setenforce &>/dev/null; then
    setenforce 1 2>/dev/null || true;
fi

echo "recarregando systemd e atualizando grub..."
systemctl daemon-reload || true
steamos-update-grub &>/dev/null || update-grub &>/dev/null || true
sysctl --system || true
sync
BASH
}

aplicar_zswap() {
    # --- Limpeza Prévia ---
    _log "garantindo aplicação limpa: executando reversão primeiro."
    _executar_reversao
    _log "reversão (limpeza) concluída. prosseguindo com a aplicação."
    # --- FIM Limpeza ---

    _steamos_readonly_disable_if_needed;

    # --- Desativa SELinux ---
    _log "desativando selinux (se existir)..."
    if command -v setenforce &>/dev/null; then
        setenforce 0 2>/dev/null || true
        _log "selinux set to permissive."
    fi
    # --- FIM SELinux ---

    # --- GPU Otimização ---
    _optimize_gpu
    # --- FIM GPU ---

    # --- Criação dos Scripts/Serviços Comuns ---
    _log "criando e ativando serviços de otimização (pré-etapa)..."
    create_common_scripts_and_services
    # --- FIM Criação ---

    _log "aplicando otimizações com zswap (etapa principal)..."

    # --- Verificação de Espaço ---
    local free_space_gb;
    free_space_gb=$(df -BG /home | awk 'NR==2 {print $4}' | tr -d 'G' || echo 0)
    if (( free_space_gb < zswap_swapfile_size_gb )); then
        _ui_info "erro crítico" "espaço em disco insuficiente.";
        _log "execução abortada.";
        exit 1;
    fi
    _log "espaço em disco suficiente."
    # --- FIM Verificação ---

    # --- Seleção de Sysctl (Bore/CFS) ---
    local final_sysctl_params;
    final_sysctl_params=("${base_sysctl_params[@]}")
    if [[ -f "/proc/sys/kernel/sched_bore" ]]; then
        _log "bore scheduler detectado. aplicando otimizações bore.";
        final_sysctl_params+=("${bore_params[@]}")
    else
        _log "bore scheduler não encontrado. aplicando otimizações de fallback para cfs.";
        final_sysctl_params+=("${cfs_params[@]}")
    fi
    # --- FIM Seleção ---

    # --- Bloco Principal de Execução (Sem _ui_progress_exec) ---
    _log "iniciando bloco principal de aplicação..."
    ( # Inicia um subshell apenas para o set -e e variáveis locais, mas sem o mktemp/bash
        set -e # Habilita saída em erro dentro deste bloco

        _log "🧹 Limpando configurações de ZRAM customizadas conflitantes..."
        systemctl stop zram-config.service 2>/dev/null || true
        systemctl disable zram-config.service 2>/dev/null || true
        rm -f /etc/systemd/system/zram-config.service 2>/dev/null || true
        rm -f /usr/local/bin/zram-setup.sh 2>/dev/null || true
        systemctl daemon-reload

        _log "desativando zram padrão e irqbalance..."
        swapoff /dev/zram0 2>/dev/null || true
        rmmod zram 2>/dev/null || true
        create_module_blacklist # Função externa, ok
        systemctl stop systemd-zram-setup@zram0.service 2>/dev/null || true
        systemctl mask systemd-zram-setup@zram0.service 2>/dev/null || true
        systemctl mask systemd-zram-setup@.service 2>/dev/null || true
        systemctl disable --now irqbalance.service 2>/dev/null || true

        _log "desativando serviços desnecessários...";
        manage_unnecessary_services "disable" # Função externa, ok

        _log "otimizando fstab...";
        _backup_file_once /etc/fstab # Função externa, ok
        if grep -q " /home " /etc/fstab 2>/dev/null; then
            sed -E -i 's|(^[^[:space:]]+[[:space:]]+/home[[:space:]]+[^[:space:]]+[[:space:]]+ext4[[:space:]]+)[^[:space:]]+|\1defaults,nofail,lazytime,commit=60,data=writeback,barrier=0,x-systemd.growfs|g' /etc/fstab || true
        fi

        _log "configurando swapfile de fallback...";
        swapoff "$swapfile_path" 2>/dev/null || true;
        rm -f "$swapfile_path" || true
        if command -v fallocate &>/dev/null; then
            fallocate -l "${zswap_swapfile_size_gb}G" "$swapfile_path" 2>/dev/null || dd if=/dev/zero of="$swapfile_path" bs=1G count="$zswap_swapfile_size_gb" status=progress
        else
            dd if=/dev/zero of="$swapfile_path" bs=1G count="$zswap_swapfile_size_gb" status=progress
        fi
        chmod 600 "$swapfile_path" || true;
        mkswap "$swapfile_path" || true
        sed -i "\|${swapfile_path}|d" /etc/fstab 2>/dev/null || true; # Usar ${} para path
        echo "$swapfile_path none swap sw,pri=-5 0 0" >> /etc/fstab
        swapon --priority -5 "$swapfile_path" || true

        _log "aplicando tweaks de sysctl...";
        _write_sysctl_file /etc/sysctl.d/99-sdweak-performance.conf "${final_sysctl_params[@]}"; # Função externa, ok
        sysctl --system || true

        _log "ajustando limites (ulimit)...";
        _backup_file_once /etc/security/limits.d/99-game-limits.conf # Função externa, ok
        cat <<'EOF' > /etc/security/limits.d/99-game-limits.conf
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

        _log "configurando parâmetros do grub...";
        _backup_file_once "$grub_config" # Função externa, ok
        local kernel_params=("zswap.enabled=1" "zswap.compressor=lz4" "zswap.max_pool_percent=40" "zswap.zpool=zsmalloc" "zswap.non_same_filled_pages_enabled=1" "mitigations=off" "psi=1" "preempt=full")
        local current_cmdline=$(grep -oP '^GRUB_CMDLINE_LINUX="\K[^"]*"' "$grub_config" || true);
        local new_cmdline="$current_cmdline"
        local param key
        for param in "${kernel_params[@]}"; do
            key="${param%%=*}";
            new_cmdline=$(echo "$new_cmdline" | sed -E "s/ ?${key}(=[^ ]*)?//g");
        done
        for param in "${kernel_params[@]}"; do
            new_cmdline="$new_cmdline $param";
        done
        new_cmdline=$(echo "$new_cmdline" | tr -s ' ' | sed -E 's/^ //; s/ \$//')
        sed -i -E "s|^GRUB_CMDLINE_LINUX=\"[^\"]*\"|GRUB_CMDLINE_LINUX=\"$new_cmdline\"|" "$grub_config" || true
        steamos-update-grub &>/dev/null || update-grub &>/dev/null || true

        _log "criando arquivos de configuração persistentes...";
        create_persistent_configs # Função externa, ok

        _log "configurando variáveis de ambiente para jogos..."
        _backup_file_once /etc/environment.d/99-game-vars.conf; # Função externa, ok
        printf "%s\n" "${game_env_vars[@]}" > /etc/environment.d/99-game-vars.conf

        _log "criando script zswap-config (etapa final)..."
        cat <<'ZSWAP_SCRIPT' > /usr/local/bin/zswap-config.sh
#!/usr/bin/env bash
echo 1 > /sys/module/zswap/parameters/enabled 2>/dev/null || true
echo lz4 > /sys/module/zswap/parameters/compressor 2>/dev/null || true
echo 40 > /sys/module/zswap/parameters/max_pool_percent 2>/dev/null || true
echo zsmalloc > /sys/module/zswap/parameters/zpool 2>/dev/null || true
echo 1 > /sys/module/zswap/parameters/non_same_filled_pages_enabled 2>/dev/null || true
ZSWAP_SCRIPT
        chmod +x /usr/local/bin/zswap-config.sh
        # O serviço zswap-config.service já foi criado na função create_common_scripts_and_services

        _log "habilitando e iniciando todos os serviços de otimização..."
        systemctl daemon-reload || true;
        # A lista otimization_services agora contém todos os serviços necessários
        systemctl enable --now "${otimization_services[@]}" || true;
        systemctl enable --now fstrim.timer 2>/dev/null || true
        sync

        _log "bloco principal de aplicação concluído com sucesso."

    ) # Fecha o subshell
    local block_rc=$? # Captura o código de saída do subshell

    if [ $block_rc -ne 0 ]; then
        _ui_info "erro" "falha durante a aplicação das otimizações. verifique o log: $logfile"
        _log "erro: bloco principal falhou com código $block_rc."
        # Poderia adicionar uma tentativa de reversão aqui se desejado
        return 1
    fi

    _ui_info "sucesso" "otimacoes aplicadas com sucesso. reinicie o sistema.";
    _log "Otimizações aplicadas com sucesso!.";
    return 0
}

reverter_alteracoes() {
    _log "iniciando reversão completa das alterações (via menu)"
    _executar_reversao # Chama a nova função de lógica

    _ui_info "reversão" "reversão completa concluída. reinicie o sistema.";
    _log "reversão completa executada"
}

# --- FUNÇÃO MAIN ATUALIZADA ---
main() {
    local texto_inicial="autor: $autor\n\ndoações (pix): $pix_doacao\n\nEste programa aplica um conjunto abrangente de otimizações de memória, i/o e sistema no steamos. todas as alterações podem ser revertidas."

    echo -e "\n======================================================="
    echo -e " Bem-vindo(a) ao utilitário Turbo Decky (v$versao)"
    echo -e "=======================================================\n$texto_inicial\n\n-------------------------------------------------------\n"

    echo "opções:";
    echo "1) Aplicar otimizações principais do SteamOS"
    echo "2) Otimizar cache de jogos do MicroSD (Mover shaders para o NVMe)"
    echo "3) Reverter otimizações principais do SteamOs"
    echo "4) Reverter otimização do cache do MicroSD"
    echo "5) Sair"

    read -rp "escolha uma opção (1-5): " escolha

    case "$escolha" in
        1) aplicar_zswap ;;
        2) otimizar_sdcard_cache ;;
        3) reverter_alteracoes ;;
        4.1) reverter_sdcard_cache ;; # Correção aqui, deve ser 4
        4) reverter_sdcard_cache ;;
        5) _ui_info "saindo" "nenhuma alteração foi feita."; exit 0 ;;
        *) _ui_info "erro" "opção inválida."; exit 1 ;;
    esac
}

main "$@"
