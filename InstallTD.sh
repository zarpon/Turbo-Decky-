#!/usr/bin/env bash
set -euo pipefail

# --- versão e autor do script ---
versao="1.1.0.21 Dupla Dinamica"
autor="Jorge Luis"
pix_doacao="jorgezarpon@msn.com"

# --- constantes e variáveis ---
readonly swapfile_path="/home/swapfile"
readonly grub_config="/etc/default/grub"
readonly zswap_swapfile_size_gb="8"
readonly zram_swapfile_size_gb="2" # <<< ADICIONADO (PARA O FALLBACK DO ZRAM)
readonly backup_suffix="bak-turbodecky"
readonly logfile="/var/log/turbodecky.log"

# --- Constantes para otimização do MicroSD ---
# O dispositivo do microsd
readonly sdcard_device="/dev/mmcblk0p1"
# O diretório de destino no NVMe (SSD interno)
readonly nvme_shadercache_target_path="/home/deck/sd_shadercache"

# --- parâmetros sysctl base (ATUALIZADO) ---
readonly base_sysctl_params=(
"vm.swappiness=100"
"vm.vfs_cache_pressure=66"
# ALTERNATIVA AO BYTES: Usando RATIO para maior compatibilidade/limpeza
"vm.dirty_background_ratio=10"
"vm.dirty_ratio=30"
"vm.dirty_expire_centisecs=1500"
"vm.dirty_writeback_centisecs=1500"
"vm.min_free_kbytes=65536"
"vm.page-cluster=0"
"vm.page_lock_unfairness=8"
"vm.watermark_scale_factor=125"
"vm.stat_interval=15"
"vm.compact_unevictable_allowed=0"
"vm.compaction_proactiveness=10"
"vm.watermark_boost_factor=0"
"vm.overcommit_memory=1"
"vm.overcommit_ratio=100"
"vm.zone_reclaim_mode=0"
"vm.max_map_count=2147483642"
"vm.mmap_rnd_compat_bits=16" # NOVO: Para binários 32-bit
"vm.unprivileged_segfault=1" # NOVO: Estabilidade de jogos antigos
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
"mem-tweaks.service"
)
readonly otimization_scripts=(
"/usr/local/bin/thp-config.sh"
"/usr/local/bin/io-boost.sh"
"/usr/local/bin/hugepages.sh"
"/usr/local/bin/ksm-config.sh"
"/usr/local/bin/mem-tweaks.sh"
)
readonly unnecessary_services=(
"gpu-trace.service"
"steamos-log-submitter.service"
"cups.service"
)

# --- variáveis de ambiente ---
readonly game_env_vars=(
# Desempenho Vulkan: Ativa Smart Access Memory (sam) e Graphics Pipeline Library (gpl)
"RADV_PERFTEST=sam,gpl,aco"
"RADV_ENABLE_ACO=1"
# Desempenho OpenGL: Move o processamento de GL para uma thread separada
"MESA_GLTHREAD=true"
# Sincronização: Garante o uso do Fsync (método moderno)
"WINEFSYNC=1"
# Cache Moderno: Define o tamanho do cache de shader (nova sintaxe)
"MESA_SHADER_CACHE_MAX_SIZE=20G"
"MESA_SHADER_CACHE_DIR=/home/deck/.cache/"
# Compatibilidade: Permite que jogos 32-bit usem mais RAM
"PROTON_FORCE_LARGE_ADDRESS_AWARE=1"
# Opcional (OpenGL): Reduz stutter em troca de loads mais longos
"radeonsi_shader_precompile=true"
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

# ==========================================================
_backup_file_once() {
local f="$1";
local backup_path="${f}.${backup_suffix}"
if [[ -f "$f" && ! -f "$backup_path" ]]; then
cp -a --preserve=timestamps "$f" "$backup_path" 2>/dev/null || cp -a "$f" "$backup_path"
_log "backup criado: $backup_path"
fi
}
# ==========================================================

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

# --- FUNÇÃO _optimize_gpu (REINTRODUZIDO uni_mes e mes_kiq) ---
_optimize_gpu() {
_log "aplicando otimizações amdgpu (com MES completo)..."
mkdir -p /etc/modprobe.d
# <<< CORREÇÃO (SOLICITAÇÃO DO USUÁRIO) >>>
# Reintroduzindo os parâmetros MES completos conforme solicitado
echo "options amdgpu mes=1 moverate=128 lbpw=0 uni_mes=1 mes_kiq=1" > /etc/modprobe.d/99-amdgpu-tuning.conf
_ui_info "gpu" "otimizações amdgpu (com MES completo) aplicadas."
_log "arquivo /etc/modprobe.d/99-amdgpu-tuning.conf (com uni_mes e mes_kiq) criado."
}
# --- FIM DA MODIFICAÇÃO ---

# --- NOVA FUNÇÃO _configure_irqbalance ---
_configure_irqbalance() {
_log "configurando irqbalance..."
mkdir -p /etc/default
_backup_file_once "/etc/default/irqbalance"
            
# Escreve a nova configuração
cat << EOF > /etc/default/irqbalance
# Configurado pelo Turbo Decky
# Bane as CPUs 0 e 1 (máscara 0x03) de lidar com IRQs,
# reservando-as para os threads principais do jogo.
IRQBALANCE_BANNED_CPUS=0x03
EOF
            
_log "configuração /etc/default/irqbalance criada."
            
# Habilita e reinicia o serviço para aplicar a config
systemctl unmask irqbalance.service 2>/dev/null || true
systemctl enable irqbalance.service 2>/dev/null || true
systemctl restart irqbalance.service 2>/dev/null || true
_log "irqbalance ativado e configurado."
}
# --- FIM DA NOVA FUNÇÃO ---

# --- FUNÇÃO create_persistent_configs ---
create_persistent_configs() {
_log "criando arquivos de configuração persistentes"
mkdir -p /etc/tmpfiles.d /etc/modprobe.d
cat << EOF > /etc/tmpfiles.d/mglru.conf
w /sys/kernel/mm/lru_gen/enabled - - - - 7
w /sys/kernel/mm/lru_gen/min_ttl_ms - - - - 200
w /sys/kernel/mm/lru_gen/shrink_promote_threshold - - - - 100
# NOVO: Otimiza a limpeza de RAM
EOF
cat << EOF > /etc/tmpfiles.d/thp_shrinker.conf
w! /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_none - - - - 409
EOF
_log "configurações persistentes para mglru e thp shrinker criadas."
}
# --- FIM DA FUNÇÃO ---

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

# --- FUNÇÃO create_common_scripts_and_services (CORRIGIDA COM APST E WBT=500) ---
create_common_scripts_and_services() {
_log "criando/atualizando scripts e services comuns"
mkdir -p /usr/local/bin /etc/systemd/system /etc/environment.d

# --- Script io-boost.sh ATUALIZADO (com APST e WBT=500) ---
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
        # --- OTIMIZAÇÃO APST (ECONOMIA DE ENERGIA) ADICIONADA ---
        # Encontra o dispositivo "pai" (ex: nvme0)
        nvme_parent_name=$(echo "$dev_name" | sed -E 's/n[0-9]+$//' | sed -E 's/p[0-9]+$//')
        nvme_power_path="/sys/class/nvme/${nvme_parent_name}/power"

        if [[ -w "${nvme_power_path}/autosuspend_delay_ms" ]]; then
            echo "100" > "${nvme_power_path}/autosuspend_delay_ms" 2>/dev/null || true
            echo "auto" > "${nvme_power_path}/control" 2>/dev/null || true
        fi
        # --- FIM DA OTIMIZAÇÃO APST ---

        # Tenta definir o agendador
        if [[ -w "$queue_path/scheduler" ]] && grep -q "kyber" "$queue_path/scheduler"; then
            echo "kyber" > "$queue_path/scheduler" 2>/dev/null || true
        elif [ -w "$queue_path/scheduler" ]; then
            echo "mq-deadline" > "$queue_path/scheduler" 2>/dev/null || true
            # --- Otimizações específicas do MQ-DEADLINE (não se aplicam ao Kyber) ---
            echo 6000000 > "$queue_path/iosched/write_lat_nsec" 2>/dev/null || true
            echo 1200000 > "$queue_path/iosched/read_lat_nsec" 2>/dev/null || true
        fi

        # --- Otimizações gerais de NVMe ---
        echo 256 > "$queue_path/read_ahead_kb" 2>/dev/null || true
        echo 1024 > "$queue_path/nr_requests" 2>/dev/null || true
        echo 1 > "$queue_path/nomerges" 2>/dev/null || true
        
        # --- CORREÇÃO: wbt_lat_usec (ANTI-STUTTER) ---
        # Definido para 500 (meio-termo)
        echo 500 > "$queue_path/wbt_lat_usec" 2>/dev/null || true
        # --- FIM DA CORREÇÃO WBT ---
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
        # --- Otimizações gerais de microSD/SD ---
        echo 512 > "$queue_path/read_ahead_kb" 2>/dev/null || true
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

cat <<'HPS' > /usr/local/bin/hugepages.sh
#!/usr/bin/env bash
# Define 0 para não desperdiçar RAM com páginas estáticas que jogos não usam
echo 0 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages 2>/dev/null || true
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

# Cria os serviços
for service_name in thp-config io-boost hugepages ksm-config mem-tweaks; do
description="";
case "$service_name" in
thp-config) description="configuracao otimizada de thp";;
io-boost) description="otimização de i/o e agendadores de disco";;
hugepages) description="aloca huge pages para jogos";;
ksm-config) description="desativa kernel samepage merging (ksm)";;
mem-tweaks) description="otimização de alocacao de memoria";;
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
# --- FIM DA FUNÇÃO ---

# --- FUNÇÃO DE OTIMIZAÇÃO DO MICROSD ---
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

# --- FUNÇÃO DE REVERSÃO DO MICROSD ---
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

# --- FUNÇÃO _executar_reversao (MODIFICADA) ---
# Nenhuma mudança necessária aqui. A lógica genérica de remoção do swapfile já existe.
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
# Adiciona zswap-config, zram-config e kernel-tweaks (legado) para limpeza total
systemctl stop "\${otimization_services[@]}" zswap-config.service zram-config.service kernel-tweaks.service 2>/dev/null || true
systemctl disable "\${otimization_services[@]}" zswap-config.service zram-config.service kernel-tweaks.service 2>/dev/null || true
echo "removendo arquivos de serviço e scripts..."
for svc_file in "\${otimization_services[@]}"; do
rm -f "/etc/systemd/system/\$svc_file";
done
# Remove explicitamente os serviços de swap e legados
rm -f /etc/systemd/system/zswap-config.service
rm -f /etc/systemd/system/zram-config.service
rm -f /etc/systemd/system/kernel-tweaks.service
for script_file in "\${otimization_scripts[@]}"; do
rm -f "\$script_file";
done
# Remove explicitamente os scripts de swap e legados
rm -f /usr/local/bin/zswap-config.sh
rm -f /usr/local/bin/zram-config.sh
rm -f /usr/local/bin/kernel-tweaks.sh
echo "garantindo a remoção do swap-boost.service legado (se existir)..."
systemctl stop swap-boost.service 2>/dev/null || true
systemctl disable swap-boost.service 2>/dev/null || true
rm -f /etc/systemd/system/swap-boost.service
rm -f /usr/local/bin/swap-boost.sh
echo "removendo arquivos de configuração extra..."
rm -f /etc/tmpfiles.d/mglru.conf /etc/tmpfiles.d/thp_shrinker.conf
rm -f /etc/modprobe.d/usbhid.conf
rm -f /etc/modprobe.d/blacklist-zram.conf
rm -f /etc/modprobe.d/amdgpu.conf
# Limpa todos os arquivos de tuning da GPU
rm -f /etc/modprobe.d/99-gpu-sched.conf /etc/modprobe.d/99-amdgpu-mes.conf /etc/modprobe.d/99-amdgpu-tuning.conf

echo "removendo swapfile customizado e restaurando /etc/fstab..."
swapoff "\$swapfile_path" 2>/dev/null || true;
rm -f "\$swapfile_path" || true
_restore_file /etc/fstab || true
swapon -a 2>/dev/null || true
echo "restaurando outros arquivos de configuração..."
_restore_file "\$grub_config" || true # Restaura o GRUB (limpando todos os parâmetros do kernel)
_restore_file /etc/sysctl.d/99-sdweak-performance.conf || rm -f /etc/sysctl.d/99-sdweak-performance.conf
_restore_file /etc/security/limits.d/99-game-limits.conf || rm -f /etc/security/limits.d/99-game-limits.conf
_restore_file /etc/environment.d/99-game-vars.conf || rm -f /etc/environment.d/99-game-vars.conf
# <<< INÍCIO DA MODIFICAÇÃO (IRQBALANCE) >>>
echo "restaurando configuração padrão do irqbalance..."
_restore_file /etc/default/irqbalance || rm -f /etc/default/irqbalance
# <<< FIM DA MODIFICAÇÃO (IRQBALANCE) >>>

echo "reativando serviços padrão do sistema..."
manage_unnecessary_services "enable"
systemctl unmask systemd-zram-setup@zram0.service 2>/dev/null || true
systemctl unmask systemd-zram-setup@.service 2>/dev/null || true

# <<< INÍCIO DA MODIFICAÇÃO (IRQBALANCE) >>>
# Garante que ele seja reativado e recarregue a config padrão (restaurada)
echo "reativando irqbalance com config padrão..."
systemctl unmask irqbalance.service 2>/dev/null || true
systemctl enable irqbalance.service 2>/dev/null || true
systemctl restart irqbalance.service 2>/dev/null || true
# <<< FIM DA MODIFICAÇÃO (IRQBALANCE) >>>

echo "reativando serviço steamos cfs-debugfs..."
systemctl unmask steamos-cfs-debugfs-tunings.service 2>/dev/null || true
systemctl enable --now steamos-cfs-debugfs-tunings.service 2>/dev/null || true
if command -v setenforce &>/dev/null; then setenforce 1 2>/dev/null || true; fi
echo "recarregando systemd e atualizando grub..."
systemctl daemon-reload || true
steamos-update-grub &>/dev/null || update-grub &>/dev/null || true
# --- CORREÇÃO ADICIONADA ---
echo "atualizando initramfs (revertendo amdgpu)..."
mkinitcpio -P &>/dev/null || true
# --- FIM DA CORREÇÃO ---
sysctl --system || true
sync
BASH
}

# --- FUNÇÃO aplicar_zswap (MODIFICADA) ---
aplicar_zswap() {
# --- Limpeza Prévia ---
_log "garantindo aplicação limpa: executando reversão primeiro."
_executar_reversao
_log "reversão (limpeza) concluída. prosseguindo com a aplicação (zswap)."
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

# <<< INÍCIO DA MODIFICAÇÃO (IRQBALANCE) >>>
_configure_irqbalance
# <<< FIM DA MODIFICAÇÃO (IRQBALANCE) >>>

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
# --- Seleção de Sysctl (BORE Apenas) ---
local final_sysctl_params;
final_sysctl_params=("${base_sysctl_params[@]}")
if [[ -f "/proc/sys/kernel/sched_bore" ]]; then
_log "bore scheduler detectado. aplicando otimizações bore.";
final_sysctl_params+=("${bore_params[@]}")
else
_log "bore scheduler não encontrado. otimizações BORE não aplicadas.";
fi
# --- FIM Seleção ---
# --- Bloco Principal de Execução (Sem _ui_progress_exec) ---
_log "iniciando bloco principal de aplicação (zswap)..."
(
set -e
_log "🧹 Limpando configurações de ZRAM customizadas conflitantes..."
systemctl stop zram-config.service 2>/dev/null || true
systemctl disable zram-config.service 2>/dev/null || true
rm -f /etc/systemd/system/zram-config.service 2>/dev/null || true
rm -f /usr/local/bin/zram-setup.sh 2>/dev/null || true
systemctl daemon-reload
_log "desativando zram padrão..."
swapoff /dev/zram0 2>/dev/null || true
rmmod zram 2>/dev/null || true
create_module_blacklist # Função externa, ok
systemctl stop systemd-zram-setup@zram0.service 2>/dev/null || true
systemctl mask systemd-zram-setup@zram0.service 2>/dev/null || true
systemctl mask systemd-zram-setup@.service 2>/dev/null || true
# <<< INÍCIO DA MODIFICAÇÃO (IRQBALANCE) >>>
# A linha 'systemctl disable --now irqbalance.service' foi REMOVIDA daqui
# <<< FIM DA MODIFICAÇÃO (IRQBALANCE) >>>

_log "desativando serviços desnecessários...";
manage_unnecessary_services "disable" # Função externa, ok
_log "otimizando fstab...";
_backup_file_once /etc/fstab # Função externa, ok
if grep -q " /home " /etc/fstab 2>/dev/null; then
sed -E -i 's|(^[^[:space:]]+[[:space:]]+/home[[:space:]]+[^[:space:]]+[[:space:]]+ext4[[:space:]]+)[^[:space:]]+|\1defaults,nofail,lazytime,commit=60,data=writeback,x-systemd.growfs|g' /etc/fstab || true
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
echo "$swapfile_path none swap sw,pri=-100 0 0" >> /etc/fstab
swapon --priority -100 "$swapfile_path" || true
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
# ==========================================================
# --- BLOCO GRUB (COM PARÂMETROS ZSWAP) ---
# ==========================================================
_log "configurando parâmetros do grub (com zswap)...";
_backup_file_once "$grub_config" # Função externa, ok
local kernel_params=(
"zswap.enabled=1"
"zswap.compressor=lz4"
"zswap.max_pool_percent=30"
"zswap.zpool=zsmalloc"
"zswap.non_same_filled_pages_enabled=1"
"mitigations=off"
"psi=1"
"rcutree.enable_rcu_lazy=1"
)
local current_cmdline
current_cmdline=$(grep -E '^GRUB_CMDLINE_LINUX=' "$grub_config" | sed -E 's/^GRUB_CMDLINE_LINUX="([^"]*)"(.*)/\1/' || true)
local new_cmdline="$current_cmdline"
local param
local key
for param in "${kernel_params[@]}"; do
key="${param%%=*}";
new_cmdline=$(echo "$new_cmdline" | sed -E "s/ ?${key}(=[^ ]*)?//g");
done
for param in "${kernel_params[@]}"; do
new_cmdline="$new_cmdline $param";
done
new_cmdline=$(echo "$new_cmdline" | tr -s ' ' | sed -E 's/^ //; s/ $//')
sed -i -E "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$new_cmdline\"|" "$grub_config" || true
steamos-update-grub &>/dev/null || update-grub &>/dev/null || true
# ==========================================================
# --- FIM DO BLOCO GRUB ---
# ==========================================================
# --- CORREÇÃO ADICIONADA ---
_log "atualizando initramfs (para amdgpu tuning)..."
mkinitcpio -P &>/dev/null || true
# --- FIM DA CORREÇÃO ---
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
echo 30 > /sys/module/zswap/parameters/max_pool_percent 2>/dev/null || true
echo zsmalloc > /sys/module/zswap/parameters/zpool 2>/dev/null || true
echo 1 > /sys/module/zswap/parameters/non_same_filled_pages_enabled 2>/dev/null || true
ZSWAP_SCRIPT
chmod +x /usr/local/bin/zswap-config.sh
_log "criando serviço zswap-config..."
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
_log "habilitando e iniciando todos os serviços de otimização (zswap)..."
systemctl daemon-reload || true;
systemctl enable --now "${otimization_services[@]}" zswap-config.service || true;
systemctl enable --now fstrim.timer 2>/dev/null || true
sync
_log "bloco principal de aplicação (zswap) concluído com sucesso."
) # Fecha o subshell
local block_rc=$? # Captura o código de saída do subshell
if [ $block_rc -ne 0 ]; then
_ui_info "erro" "falha durante a aplicação das otimizações (zswap). verifique o log: $logfile"
_log "erro: bloco principal (zswap) falhou com código $block_rc."
return 1
fi
_ui_info "sucesso" "otimacoes (zswap) aplicadas com sucesso. reinicie o sistema.";
_log "Otimizações (ZSwap) aplicadas com sucesso!.";
return 0
}

# --- NOVA FUNÇÃO aplicar_zram (MODIFICADA) ---
aplicar_zram() {
# --- Limpeza Prévia ---
_log "garantindo aplicação limpa: executando reversão primeiro."
_executar_reversao
_log "reversão (limpeza) concluída. prosseguindo com a aplicação (zram)."
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

# <<< INÍCIO DA MODIFICAÇÃO (IRQBALANCE) >>>
_configure_irqbalance
# <<< FIM DA MODIFICAÇÃO (IRQBALANCE) >>>

_log "aplicando otimizações com zram (etapa principal)..."

# <<< INÍCIO DA MODIFICAÇÃO (VERIFICAÇÃO DE ESPAÇO) >>>
# --- Verificação de Espaço ---
local free_space_gb;
free_space_gb=$(df -BG /home | awk 'NR==2 {print $4}' | tr -d 'G' || echo 0)
if (( free_space_gb < zram_swapfile_size_gb )); then
    _ui_info "erro crítico" "espaço em disco insuficiente para criar o swapfile de 4GB.";
    _log "execução (zram) abortada por falta de espaço.";
    exit 1;
fi
_log "espaço em disco suficiente para o swapfile."
# --- FIM Verificação ---
# <<< FIM DA MODIFICAÇÃO >>>

# --- Seleção de Sysctl (BORE Apenas) ---
local final_sysctl_params;
final_sysctl_params=("${base_sysctl_params[@]}")
if [[ -f "/proc/sys/kernel/sched_bore" ]]; then
_log "bore scheduler detectado. aplicando otimizações bore.";
final_sysctl_params+=("${bore_params[@]}")
else
_log "bore scheduler não encontrado. otimizações BORE não aplicadas.";
fi
# --- FIM Seleção ---
# --- Bloco Principal de Execução (ZRAM) ---
_log "iniciando bloco principal de aplicação (zram)..."
(
set -e
_log "🧹 Limpando configurações de ZRAM customizadas conflitantes..."
systemctl stop zram-config.service 2>/dev/null || true
systemctl disable zram-config.service 2>/dev/null || true
rm -f /etc/systemd/system/zram-config.service 2>/dev/null || true
rm -f /usr/local/bin/zram-setup.sh 2>/dev/null || true
systemctl daemon-reload
_log "desativando zram padrão..."
swapoff /dev/zram0 2>/dev/null || true
# REMOVE a blacklist do zram, caso exista
rm -f /etc/modprobe.d/blacklist-zram.conf
systemctl stop systemd-zram-setup@zram0.service 2>/dev/null || true
systemctl mask systemd-zram-setup@zram0.service 2>/dev/null || true
systemctl mask systemd-zram-setup@.service 2>/dev/null || true
# <<< INÍCIO DA MODIFICAÇÃO (IRQBALANCE) >>>
# A linha 'systemctl disable --now irqbalance.service' foi REMOVIDA daqui
# <<< FIM DA MODIFICAÇÃO (IRQBALANCE) >>>

_log "desativando serviços desnecessários...";
manage_unnecessary_services "disable" # Função externa, ok
_log "otimizando fstab...";
_backup_file_once /etc/fstab # Função externa, ok
if grep -q " /home " /etc/fstab 2>/dev/null; then
sed -E -i 's|(^[^[:space:]]+[[:space:]]+/home[[:space:]]+[^[:space:]]+[[:space:]]+ext4[[:space:]]+)[^[:space:]]+|\1defaults,nofail,lazytime,commit=60,data=writeback,x-systemd.growfs|g' /etc/fstab || true
fi

# <<< INÍCIO DA MODIFICAÇÃO (SWAPFILE DE FALLBACK) >>>
_log "configurando swapfile de fallback (4GB, pri=-2)...";
swapoff "$swapfile_path" 2>/dev/null || true;
rm -f "$swapfile_path" || true
if command -v fallocate &>/dev/null; then
    fallocate -l "${zram_swapfile_size_gb}G" "$swapfile_path" 2>/dev/null || dd if=/dev/zero of="$swapfile_path" bs=1G count="$zram_swapfile_size_gb" status=progress
else
    dd if=/dev/zero of="$swapfile_path" bs=1G count="$zram_swapfile_size_gb" status=progress
fi
chmod 600 "$swapfile_path" || true;
mkswap "$swapfile_path" || true
sed -i "\|${swapfile_path}|d" /etc/fstab 2>/dev/null || true;
echo "$swapfile_path none swap sw,pri=-2 0 0" >> /etc/fstab
swapon --priority -2 "$swapfile_path" || true
_log "swapfile de fallback para zram criado."
# <<< FIM DA MODIFICAÇÃO >>>

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
# ==========================================================
# --- BLOCO GRUB (SEM PARÂMETROS ZSWAP) ---
# ==========================================================
_log "configurando parâmetros do grub (sem zswap)...";
_backup_file_once "$grub_config" # Função externa, ok
local kernel_params=(
"mitigations=off"
"psi=1"
"rcutree.enable_rcu_lazy=1"
)
local current_cmdline
current_cmdline=$(grep -E '^GRUB_CMDLINE_LINUX=' "$grub_config" | sed -E 's/^GRUB_CMDLINE_LINUX="([^"]*)"(.*)/\1/' || true)
local new_cmdline="$current_cmdline"
local param
local key
for param in "${kernel_params[@]}"; do
key="${param%%=*}";
# Remove o zswap também, para limpeza
new_cmdline=$(echo "$new_cmdline" | sed -E "s/ ?${key}(=[^ ]*)?//g" | sed -E "s/ ?zswap\.[^ =]+(=[^ ]*)?//g");
done
for param in "${kernel_params[@]}"; do
new_cmdline="$new_cmdline $param";
done
new_cmdline=$(echo "$new_cmdline" | tr -s ' ' | sed -E 's/^ //; s/ $//')
sed -i -E "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$new_cmdline\"|" "$grub_config" || true
steamos-update-grub &>/dev/null || update-grub &>/dev/null || true
# ==========================================================
# --- FIM DO BLOCO GRUB ---
# ==========================================================
# --- CORREÇÃO ADICIONADA ---
_log "atualizando initramfs (para amdgpu tuning)..."
mkinitcpio -P &>/dev/null || true
# --- FIM DA CORREÇÃO ---
_log "criando arquivos de configuração persistentes...";
create_persistent_configs # Função externa, ok
_log "configurando variáveis de ambiente para jogos..."
_backup_file_once /etc/environment.d/99-game-vars.conf; # Função externa, ok
printf "%s\n" "${game_env_vars[@]}" > /etc/environment.d/99-game-vars.conf

# <<< INÍCIO DA CORREÇÃO (LOG) >>>
_log "criando script zram-config (6G, lz4)..."
# <<< FIM DA CORREÇÃO (LOG) >>>

# --- SCRIPT ZRAM-CONFIG.SH CORRIGIDO ---
cat <<'ZRAM_SCRIPT' > /usr/local/bin/zram-config.sh
#!/usr/bin/env bash
modprobe zram num_devices=1 2>/dev/null || true
# --- CORREÇÃO ---
# Define o algoritmo de compressão e o zpool ANTES de definir o tamanho.
# Escrevemos diretamente no dispositivo zram0 para garantir.
echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
echo zsmalloc > /sys/block/zram0/zpool 2>/dev/null || true
# Agora, ativamos o dispositivo com o tamanho
echo 12G > /sys/block/zram0/disksize 2>/dev/null || true
# O resto continua o mesmo
mkswap /dev/zram0 2>/dev/null || true
swapon /dev/zram0 -p 3000 2>/dev/null || true
ZRAM_SCRIPT
# --- FIM DA CORREÇÃO ---
chmod +x /usr/local/bin/zram-config.sh
_log "criando serviço zram-config..."
cat <<UNIT > /etc/systemd/system/zram-config.service
[Unit]
# <<< INÍCIO DA CORREÇÃO (DESCRIÇÃO) >>>
Description=configuracao otimizada de zram (6g, lz4)
# <<< FIM DA CORREÇÃO (DESCRIÇÃO) >>>
[Service]
Type=oneshot
ExecStart=/usr/local/bin/zram-config.sh
RemainAfterExit=true
[Install]
WantedBy=multi-user.target
UNIT
_log "habilitando e iniciando todos os serviços de otimização (zram)..."
systemctl daemon-reload || true;
systemctl enable --now "${otimization_services[@]}" zram-config.service || true;
systemctl enable --now fstrim.timer 2>/dev/null || true
sync
_log "bloco principal de aplicação (zram) concluído com sucesso."
) # Fecha o subshell
local block_rc=$? # Captura o código de saída do subshell
if [ $block_rc -ne 0 ]; then
_ui_info "erro" "falha durante a aplicação das otimizações (zram). verifique o log: $logfile"
_log "erro: bloco principal (zram) falhou com código $block_rc."
return 1
fi
_ui_info "sucesso" "otimacoes (zram) aplicadas com sucesso. reinicie o sistema.";
_log "Otimizações (ZRAM) aplicadas com sucesso!.";
return 0
}

reverter_alteracoes() {
_log "iniciando reversão completa das alterações (via menu)"
_executar_reversao # Chama a nova função de lógica
_ui_info "reversão" "reversão completa concluída. reinicie o sistema.";
_log "reversão completa executada"
}

# --- FUNÇÃO MAIN ATUALIZADA (com novas opções) ---
main() {
local texto_inicial="autor: $autor\n\ndoações (pix): $pix_doacao\n\nEste programa aplica um conjunto abrangente de otimizações de memória, i/o e sistema no steamos. todas as alterações podem ser revertidas."
echo -e "\n======================================================="
echo -e " Bem-vindo(a) ao utilitário Turbo Decky (v$versao)"
echo -e "=======================================================\n$texto_inicial\n\n-------------------------------------------------------\n"
echo "opções de otimização principal:"
echo "1) Aplicar Otimizações (Padrão com ZSwap + Swapfile)"
echo "2) Aplicar Otimizações (Alternativa com ZRAM)"
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
