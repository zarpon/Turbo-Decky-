#!/usr/bin/env bash
set -euo pipefail

# --- versão e autor do script ---

versao="1.7.2.rev03 - ENDLESS GAME (Performance Tuned)"
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
# Caminho do cache DXVK
readonly dxvk_cache_path="/home/deck/dxvkcache"

# --- parâmetros sysctl base (ATUALIZADO PARA LATÊNCIA E SCHEDULER) ---
readonly base_sysctl_params=(
    "vm.swappiness=100"
    "vm.vfs_cache_pressure=50"           # Reduzido de 66: Mantém cache de diretórios na RAM por mais tempo
    "vm.dirty_background_bytes=262144000" 
    "vm.dirty_bytes=524288000" 
    "vm.dirty_expire_centisecs=3000"     # Aumentado para 30s: Melhora bateria agrupando escritas
    "vm.dirty_writeback_centisecs=1500"
    "vm.min_free_kbytes=131072"
    "vm.page-cluster=0"
    "vm.compaction_proactiveness=20"     # Aumentado de 10: Evita stalls de alocação de memória sob pressão
    "kernel.numa_balancing=0"
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
    
    # --- TUNING DO SCHEDULER (CFS) PARA JOGOS ---
    "kernel.sched_min_granularity_ns=10000000"       # 10ms: Reduz trocas de contexto excessivas
    "kernel.sched_wakeup_granularity_ns=15000000"    # 15ms: Evita preempção muito agressiva
    "kernel.sched_migration_cost_ns=5000000"         # 5ms: "Cola" a thread no núcleo (cache locality)
    "kernel.sched_cfs_bandwidth_slice_us=5000"
    
    # --- WATCHDOG E NETWORK ---
    "kernel.nmi_watchdog=0"
    "kernel.soft_watchdog=0"
    "kernel.watchdog=0"
    "kernel.core_pattern=/dev/null"
    "kernel.core_pipe_limit=0"
    "kernel.printk_devkmsg=off"
    "net.core.default_qdisc=fq_pie"
    "net.ipv4.tcp_congestion_control=bbr"
    "net.core.netdev_max_backlog=16384"
    "net.ipv4.tcp_fastopen=3"            # Reduz latência de handshake em jogos online
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
    "steamos-cfs-debugfs-tunings.service" 
)

# --- variáveis de ambiente (Configuração de Jogos) ---
# Nota: DXVK_STATE_CACHE_PATH usa a variável definida acima
readonly game_env_vars=(
"RADV_PERFTEST=gpl,aco,sam,shader_ballot"
"RADV_DEBUG=novrsflatshading"
"RADEONSI_SHADER_PRECOMPILE=true"

"MESA_DISK_CACHE_COMPRESSION=zstd"
"MESA_SHADER_CACHE_MAX_SIZE=6G"
"VKD3D_SHADER_CACHE=1"

"PROTON_FORCE_LARGE_ADDRESS_AWARE=1"
"WINE_DISABLE_PROTOCOL_FORK=1"
"WINE_DISABLE_WRITE_WATCH=1"

"PROTON_USE_NTSYNC=1"

"WINEESYNC=0"
)


# --- Funções Utilitárias ---
_ui_info() {
    echo -e "\n[info] $1: $2";
    # Se tiver zenity e for erro ou sucesso final, exibe popup
    if command -v zenity &>/dev/null; then
        if [[ "$1" == "erro" ]]; then
            zenity --error --text="$2" --width=300 2>/dev/null || true
        elif [[ "$1" == "sucesso" ]]; then
            # Não bloqueia execução com sucesso para não irritar, apenas notifica
            zenity --notification --text="$2" 2>/dev/null || true
        fi
    fi
}

_log() {
    mkdir -p "$(dirname "$logfile")" 2>/dev/null || true
    touch "$logfile" 2>/dev/null || true
    echo "$(date '+%F %T') - $*" | tee -a "$logfile"
}

if [[ $EUID -ne 0 ]]; then
    if command -v zenity &>/dev/null; then
        zenity --error --text="Este script deve ser executado como root (sudo)." --width=300
    fi
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
    sync
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

# --- NOVA FUNÇÃO: Configurar pasta DXVK ---
_setup_dxvk_folder() {
    _log "Configurando pasta DXVK Cache..."
    if [ ! -d "$dxvk_cache_path" ]; then
        mkdir -p "$dxvk_cache_path"
        _log "Pasta criada: $dxvk_cache_path"
    fi
    # Corrige permissões para o usuário 'deck' (UID 1000)
    # Isso é crucial pois a pasta foi criada via sudo (root)
    chown -R 1000:1000 "$dxvk_cache_path" 2>/dev/null || chown -R deck:deck "$dxvk_cache_path" 2>/dev/null || true
    chmod 755 "$dxvk_cache_path"
    _log "Permissões da pasta DXVK ajustadas para usuário deck."
}

_optimize_gpu() {
    _log "aplicando otimizações amdgpu..."
    mkdir -p /etc/modprobe.d
    # Cria o arquivo que será removido na reversão
    echo "options amdgpu moverate=128" > /etc/modprobe.d/99-amdgpu-tuning.conf
    _log "arquivo /etc/modprobe.d/99-amdgpu-tuning.conf criado."
}

_configure_ulimits() {
    _log "aplicando limite de arquivo aberto (ulimit) alto (1048576)"
    mkdir -p /etc/security/limits.d
    cat <<'EOF' > /etc/security/limits.d/99-game-limits.conf
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
* hard memlock 2147483648
* soft memlock 2147483648
EOF
    _log "/etc/security/limits.d/99-game-limits.conf criado/atualizado."
}

_configure_irqbalance() {
    _log "configurando irqbalance..."
    mkdir -p /etc/default
    _backup_file_once "/etc/default/irqbalance"

    cat << 'EOF' > /etc/default/irqbalance
# Impede o uso do core 0 para interrupções (ideal para APU do Steam Deck)
IRQBALANCE_BANNED_CPUS=0x01

EOF

    systemctl unmask irqbalance.service 2>/dev/null || true
    systemctl enable irqbalance.service 2>/dev/null || true
    systemctl restart irqbalance.service 2>/dev/null || true

    _log "irqbalance configurado com política otimizada para o Steam Deck."
}
create_persistent_configs() {
    _log "criando arquivos de configuração persistentes"
    mkdir -p /etc/tmpfiles.d /etc/modprobe.d /etc/modules-load.d

    # MGLRU
    cat << EOF > /etc/tmpfiles.d/mglru.conf
w /sys/kernel/mm/lru_gen/enabled - - - - 7
w /sys/kernel/mm/lru_gen/min_ttl_ms - - - - 0
EOF
    # THP Shrinker
    cat << EOF > /etc/tmpfiles.d/thp_shrinker.conf
w! /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_none - - - - 409
EOF

    # NTSYNC - Carregamento Persistente do Módulo
    echo "ntsync" > /etc/modules-load.d/ntsync.conf
    _log "configuração ntsync criada em /etc/modules-load.d/ntsync.conf"

    _log "configurações mglru, thp_shrinker e ntsync criadas."
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

# --- FUNÇÃO: REGRAS DE ENERGIA (HÍBRIDO AC/BATERIA COM ANTI-STUTTER) ---
create_power_rules() {
    _log "configurando regras dinâmicas de energia (AC/Bateria) com detecção híbrida..."

    # ------------------------------------------------------------------
    # --- LÓGICA DE DETECÇÃO HÍBRIDA (SYSFS DINÂMICO + UPOWER FALLBACK NORMALIZADO) ---
    # ------------------------------------------------------------------

    # detecta AC via sysfs (varre dispositivos)
    get_ac_state_sysfs() {
        for ps in /sys/class/power_supply/*; do
            [ -d "$ps" ] || continue
            local type_file="$ps/type"
            local online_file="$ps/online"

            # se não há type, pula (regra obrigatória)
            [[ -f "$type_file" ]] || continue

            local type_val; type_val=$(tr -d ' \t\n' < "$type_file" 2>/dev/null)
            local online_val=""

            if [[ -f "$online_file" ]]; then
                online_val=$(tr -d ' \t\n' < "$online_file" 2>/dev/null)
            fi

            # 1. Prefer explicit line_power/AC types
            case "$type_val" in
            "Mains"|"Line"|"AC"|"USB_C"|"ACAD"|"USB-PD")
                # retorna valor de online (pode ser vazio se nao existir)
                echo "${online_val:-unknown}"
                return
                ;;
            esac

            # 2. Fallback: Catch generic "USB" devices
            if [[ "$type_val" == "USB" ]]; then
                # usa online se disponível
                if [[ -n "$online_val" ]]; then
                    echo "$online_val"
                    return
                # senão, usa present (último recurso; risco em alguns firmwares, mas cobre Steam Deck odd cases)
                elif [[ -f "$ps/present" ]]; then
                    local present_val; present_val=$(tr -d ' \t\n' < "$ps/present" 2>/dev/null)
                    echo "$present_val"
                    return
                fi
            fi
        done
        echo "unknown"
    }

    # fallback via upower, se disponível
    get_ac_state_upower() {
        if ! command -v upower &>/dev/null; then
            echo "unknown"
            return
        fi
        # tenta identificar o objeto line_power dinamicamente
        local lp; lp=$(upower -e 2>/dev/null | grep -i line_power | head -n1)
        if [[ -z "$lp" ]]; then
            echo "unknown"
            return
        fi
        # Extrai o estado, normaliza para minúsculas e remove espaços (cobre yes/no, on/off, 1/0)
        upower -i "$lp" 2>/dev/null | awk '/online/ {print $2}' | tr '[:upper:]' '[:lower:]' | tr -d ' \t\n'
    }

    # Combina Sysfs e UPower para detecção resiliente
    is_on_ac() {
        local sysfs_state; sysfs_state=$(get_ac_state_sysfs)

        if [[ "$sysfs_state" == "1" ]]; then
            return 0 # AC Detectado via SysFS (1)
        fi

        if [[ "$sysfs_state" == "0" ]]; then
            return 1 # Bateria Detectada via SysFS (0)
        fi

        # Se sysfs falhar (retornar 'unknown' ou vazio), tentamos o UPower (Normalizado)
        local up_state; up_state=$(get_ac_state_upower)

        # Testa se a string normalizada corresponde a 'yes', 'on' ou '1'
        if [[ "$up_state" =~ ^(yes|on|1)$ ]]; then
            return 0 # AC Detectado via UPower
        fi

        return 1 # Fallback (Bateria ou Falha)
    }

    # ------------------------------------------------------------------
    # --- SCRIPT DE MONITORAMENTO (EMBUTIDO) ---
    # ------------------------------------------------------------------
    cat <<'EOF' > /usr/local/bin/turbodecky-power-monitor.sh
#!/usr/bin/env bash

# Funções de Detecção (Inclusas no script para execução standalone - Refatoradas)
get_ac_state_sysfs() {
    for ps in /sys/class/power_supply/*; do
        [ -d "$ps" ] || continue
        local type_file="$ps/type"
        local online_file="$ps/online"

        [[ -f "$type_file" ]] || continue

        local type_val; type_val=$(tr -d ' \t\n' < "$type_file" 2>/dev/null)
        local online_val=""

        if [[ -f "$online_file" ]]; then
            online_val=$(tr -d ' \t\n' < "$online_file" 2>/dev/null)
        fi

        case "$type_val" in
        "Mains"|"Line"|"AC"|"USB_C"|"ACAD"|"USB-PD")
            echo "${online_val:-unknown}"
            return
            ;;
        esac

        if [[ "$type_val" == "USB" ]]; then
            if [[ -n "$online_val" ]]; then
                echo "$online_val"
                return
            elif [[ -f "$ps/present" ]]; then
                local present_val; present_val=$(tr -d ' \t\n' < "$ps/present" 2>/dev/null)
                echo "$present_val"
                return
            fi
        fi
    done
    echo "unknown"
}
get_ac_state_upower() {
    if ! command -v upower &>/dev/null; then
        echo "unknown"
        return
    fi
    local lp; lp=$(upower -e 2>/dev/null | grep -i line_power | head -n1)
    if [[ -z "$lp" ]]; then
        echo "unknown"
        return
    fi
    upower -i "$lp" 2>/dev/null | awk '/online/ {print $2}' | tr '[:upper:]' '[:lower:]' | tr -d ' \t\n'
}
is_on_ac() {
    local sysfs_state; sysfs_state=$(get_ac_state_sysfs)
    if [[ "$sysfs_state" == "1" ]]; then return 0; fi
    if [[ "$sysfs_state" == "0" ]]; then return 1; fi
    local up_state; up_state=$(get_ac_state_upower)
    if [[ "$up_state" =~ ^(yes|on|1)$ ]]; then return 0; fi
    return 1
}

if is_on_ac; then
    # --- MODO TOMADA (PERFORMANCE & BAIXA LATÊNCIA) ---
    logger "TurboDecky: Conectado a energia - Boost Seguro (Híbrido)"

    # CPU: Performance (Reação rápida, não clock travado)
    if [ -f /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference ]; then
        for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
            echo "performance" > "$epp" 2>/dev/null || true
        done
    fi

    # Wi-Fi: Sem Power Save (Ping estável)
    if command -v iw &>/dev/null; then
        WLAN=$(iw dev | awk '$1=="Interface"{print $2}' | head -n1)
        [ -n "$WLAN" ] && iw dev "$WLAN" set power_save off 2>/dev/null || true
    fi

    # THP TUNING: "Micro-Doses" (ANTI-STUTTER)
    echo 1000 > /sys/kernel/mm/transparent_hugepage/khugepaged/scan_sleep_millisecs 2>/dev/null || true
    echo 512 > /sys/kernel/mm/transparent_hugepage/khugepaged/pages_to_scan 2>/dev/null || true
    echo 50000 > /sys/kernel/mm/transparent_hugepage/khugepaged/alloc_sleep_millisecs 2>/dev/null || true

else
    # --- MODO BATERIA (PADRÃO/ECONOMIA) ---
    logger "TurboDecky: Bateria - Revertendo (Híbrido)"

    # CPU: Balanceada (Padrão SteamOS)
    if [ -f /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference ]; then
        for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
            echo "balance_power" > "$epp" 2>/dev/null || true
        done
    fi

    # Wi-Fi: Com Power Save (Economia)
    if command -v iw &>/dev/null; then
        WLAN=$(iw dev | awk '$1=="Interface"{print $2}' | head -n1)
        [ -n "$WLAN" ] && iw dev "$WLAN" set power_save on 2>/dev/null || true
    fi

    # THP Relaxado (Economia de Ciclos CPU)
    echo 5000 > /sys/kernel/mm/transparent_hugepage/khugepaged/scan_sleep_millisecs 2>/dev/null || true
    echo 2048 > /sys/kernel/mm/transparent_hugepage/khugepaged/pages_to_scan 2>/dev/null || true
    echo 50000 > /sys/kernel/mm/transparent_hugepage/khugepaged/alloc_sleep_millisecs 2>/dev/null || true
fi
EOF
    chmod +x /usr/local/bin/turbodecky-power-monitor.sh

    # 4. CRIAÇÃO DO SERVICE (Para ser acionado pelo UDEV/SYSTEMD)
    cat <<UNIT > /etc/systemd/system/turbodecky-power-monitor.service
[Unit]
Description=TurboDecky Power Monitor (oneshot udev-triggered)
Wants=sys-devices-virtual-power_supply-*/device
[Service]
Type=oneshot
ExecStart=/usr/local/bin/turbodecky-power-monitor.sh
UNIT
    systemctl daemon-reload || true

    # 5. Regra UDEV OTIMIZADA (Gatilho Systemd - Foca apenas nos tipos de fonte AC)
    cat <<'UDEV' > /etc/udev/rules.d/99-turbodecky-power.rules
SUBSYSTEM=="power_supply", ACTION=="change", ATTR{type}=="Mains", TAG+="systemd", ENV{SYSTEMD_WANTS}="turbodecky-power-monitor.service"
SUBSYSTEM=="power_supply", ACTION=="change", ATTR{type}=="ACAD", TAG+="systemd", ENV{SYSTEMD_WANTS}="turbodecky-power-monitor.service"
SUBSYSTEM=="power_supply", ACTION=="change", ATTR{type}=="USB_C", TAG+="systemd", ENV{SYSTEMD_WANTS}="turbodecky-power-monitor.service"
SUBSYSTEM=="power_supply", ACTION=="change", ATTR{type}=="USB-PD", TAG+="systemd", ENV{SYSTEMD_WANTS}="turbodecky-power-monitor.service"
UDEV

    # 6. Ativar imediatamente (usando --no-block para não travar o script principal)
    if command -v udevadm &>/dev/null; then
        udevadm control --reload-rules 2>/dev/null || true
        # Também disparamos um evento de mudança para garantir que o estado inicial seja setado.
        udevadm trigger --action=change --subsystem-match=power_supply 2>/dev/null || true
    fi
    # Executa uma vez via systemd para setar o estado atual
    systemctl start --no-block turbodecky-power-monitor.service || true
    _log "monitoramento de energia configurado (THP Latency Tuned - Híbrido/Systemd)."
}

create_common_scripts_and_services() {
    _log "criando scripts e services comuns"
    mkdir -p /usr/local/bin /etc/systemd/system /etc/environment.d

    # --- 1. APLICAÇÃO DE VARIÁVEIS DE AMBIENTE ---
    if [ ${#game_env_vars[@]} -gt 0 ]; then
        printf "%s\n" "${game_env_vars[@]}" > /etc/environment.d/turbodecky-game.conf
        chmod 644 /etc/environment.d/turbodecky-game.conf
        _log "variáveis de ambiente configuradas em /etc/environment.d/turbodecky-game.conf"
    fi

    # --- 2. SCRIPT IO-BOOST (ATUALIZADO PARA LATÊNCIA NVME) ---
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
        if echo "adios" > "$queue_path/scheduler" 2>/dev/null; then :
        elif echo "kyber" > "$queue_path/scheduler" 2>/dev/null; then :
        else echo "none" > "$queue_path/scheduler" 2>/dev/null || true; fi
        echo 1024 > "$queue_path/read_ahead_kb" 2>/dev/null || true
        echo 1024 > "$queue_path/nr_requests" 2>/dev/null || true
        echo 0 > "$queue_path/nomerges" 2>/dev/null || true
        
        # OTIMIZAÇÃO I/O AGRESSIVA (LATÊNCIA)
        echo 0 > "$queue_path/wbt_lat_usec" 2>/dev/null || true
        echo 2 > "$queue_path/rq_affinity" 2>/dev/null || true # Força conclusão na mesma CPU
        ;;
    mmcblk*|sd*)
        if grep -q "adios" "$queue_path/scheduler" 2>/dev/null; then
            echo "adios" > "$queue_path/scheduler" 2>/dev/null || true
        else
            echo "bfq" > "$queue_path/scheduler" 2>/dev/null || true
        fi

        # --- AJUSTE DE BAIXA LATÊNCIA PARA BFQ ---
        echo 500 > "$queue_path/wbt_lat_usec" 2>/dev/null || true
        echo 1 > "$queue_path/rq_affinity" 2>/dev/null || true

        for bfq_path in "$queue_path/bfq" "$queue_path/iosched"; do
            if [ -d "$bfq_path" ]; then
                if [ -f "$bfq_path/low_latency" ]; then
                    echo 1 > "$bfq_path/low_latency" 2>/dev/null || true
                elif [ -f "$bfq_path/low_latency_mode" ]; then
                    echo 1 > "$bfq_path/low_latency_mode" 2>/dev/null || true
                fi

                echo 0 > "$bfq_path/back_seek_penalty" 2>/dev/null || true
                echo 50 > "$bfq_path/fifo_expire_async" 2>/dev/null || true
                echo 50 > "$bfq_path/fifo_expire_sync" 2>/dev/null || true
                echo 100 > "$bfq_path/timeout_sync" 2>/dev/null || true
                echo 0 > "$bfq_path/slice_idle" 2>/dev/null || true
                echo 0 > "$bfq_path/slice_idle_us" 2>/dev/null || true
            fi
        done
        # --- FIM AJUSTE BFQ ---

        echo 2048 > "$queue_path/read_ahead_kb" 2>/dev/null || true
        ;;
    esac
done
IOB

    chmod +x /usr/local/bin/io-boost.sh

    # --- 3. SCRIPT THP (Valores base + alloc_sleep fix) ---
    cat <<'THP' > /usr/local/bin/thp-config.sh
#!/usr/bin/env bash
echo "always" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo "defer+madvise" > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
echo "advise" > /sys/kernel/mm/transparent_hugepage/shmem_enabled 2>/dev/null || true
echo 1 > /sys/kernel/mm/transparent_hugepage/khugepaged/defrag 2>/dev/null || true
# Segurança para evitar loop em falha de alocação (Fix Geral)
echo 50000 > /sys/kernel/mm/transparent_hugepage/khugepaged/alloc_sleep_millisecs 2>/dev/null || true
# Valores base (Bateria) - Serão sobrescritos dinamicamente pelo monitor de energia
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

# ----------------------------------------------------------------------------------
# --- FUNÇÃO DE REVERSÃO ATUALIZADA (COM SEGURANÇA DO KERNEL) ---
# ----------------------------------------------------------------------------------
_executar_reversao() {
    _steamos_readonly_disable_if_needed;
    _log "executando reversão geral"

    # --- 1. LIMPEZA DE ARQUIVOS DE CONFIGURAÇÃO CRIADOS ---
    rm -f /etc/environment.d/turbodecky*.conf
    rm -f /etc/security/limits.d/99-game-limits.conf
    # Arquivos que foram criados em /etc/modprobe.d e /etc/tmpfiles.d
    rm -f /etc/modprobe.d/99-amdgpu-tuning.conf
    rm -f /etc/tmpfiles.d/mglru.conf
    rm -f /etc/tmpfiles.d/thp_shrinker.conf
    rm -f /etc/tmpfiles.d/custom-timers.conf
    # Remove configuração persistente do ntsync
    rm -f /etc/modules-load.d/ntsync.conf

    # Limpeza do Power Monitor
    systemctl stop turbodecky-power-monitor.service 2>/dev/null || true
    systemctl disable turbodecky-power-monitor.service 2>/dev/null || true
    rm -f /etc/systemd/system/turbodecky-power-monitor.service
    rm -f /usr/local/bin/turbodecky-power-monitor.sh
    rm -f /etc/udev/rules.d/99-turbodecky-power.rules
    if command -v udevadm &>/dev/null; then udevadm control --reload-rules; fi

    # --- 2. GERENCIAMENTO DE SERVIÇOS (STOP/DISABLE/REMOVE) ---
    systemctl stop "${otimization_services[@]}" zswap-config.service zram-config.service 2>/dev/null || true
    systemctl disable "${otimization_services[@]}" zswap-config.service zram-config.service 2>/dev/null || true

    for svc in "${otimization_services[@]}" zswap-config.service zram-config.service; do
        rm -f "/etc/systemd/system/$svc"
    done

    rm -f /usr/local/bin/zswap-config.sh /usr/local/bin/zram-config.sh
    for script_svc in "${otimization_services[@]}"; do
        rm -f "/usr/local/bin/${script_svc%%.service}.sh"
    done

    # Desmascara e (re)inicia o ZRAM padrão do sistema (Restaurando o ZRAM original)
    systemctl unmask systemd-zram-setup@zram0.service 2>/dev/null || true
    systemctl start systemd-zram-setup@zram0.service 2>/dev/null || true
    _log "Serviço systemd-zram-setup@zram0.service desmascarado e iniciado."

    # --- 3. REVERSÃO KERNEL (Reinstalação automática removida) ---
    # Observação: a reinstalação automática do kernel padrão (linux-neptune)
    # foi removida conforme solicitado para evitar alterações automáticas do kernel.
    # (Nenhuma ação de pacman relacionada a kernel é executada aqui.)

    # --- FIM REVERSÃO KERNEL ---

    # --- 4. REVERSÃO IRQBALANCE ---
    # Restaura o backup do arquivo de configuração ou o remove
    _restore_file /etc/default/irqbalance || rm -f /etc/default/irqbalance
    systemctl restart irqbalance.service 2>/dev/null || true # Reinicia para limpar o IRQBALANCE_BANNED_CPUS

    # --- 5. SWAP/FSTAB/SYSCTL/GRUB ---
    swapoff "$swapfile_path" 2>/dev/null || true; rm -f "$swapfile_path" || true
    # A reversão do tweak do /home e do swapfile é feita aqui
    _restore_file /etc/fstab || true
    swapon -a 2>/dev/null || true # Ativa o swap padrão do sistema (se houver)

    _restore_file /etc/sysctl.d/99-sdweak-performance.conf || rm -f /etc/sysctl.d/99-sdweak-performance.conf
    _restore_file "$grub_config" || true

    if command -v update-grub &>/dev/null; then update-grub; else steamos-update-grub &>/dev/null || true; fi
    mkinitcpio -P &>/dev/null || true

    # --- 6. APLICAÇÃO FINAL ---
    sysctl --system || true # Recarrega sysctl sem o 99-sdweak-performance.conf
    systemctl daemon-reload || true
    manage_unnecessary_services "enable"
    _log "reversão concluída."
}
# ----------------------------------------------------------------------------------
# --- FIM FUNÇÃO DE REVERSÃO ATUALIZADA ---
# ----------------------------------------------------------------------------------

_instalar_kernel_customizado() {
    local install_msg="NOVIDADE: Instalação de Kernel Customizado.\n\nAtenção!!! A compatibilidade desse kernel foi testada apenas no SteamOS 3.7.*\n\nBenefícios:\n * Freq. 1000Hz (Menor Latência)\n * NTSYNC (Melhor sincronização Wine/Proton)\n * Otimizações Zen 2\n\n⚠️ O instalador irá substituir o kernel padrão. Você deve aceitar a remoção do 'linux-neptune' quando solicitado."

    local resp_kernel="n"

    # --- INTEGRAÇÃO ZENITY ---
    if command -v zenity &>/dev/null; then
        # Exibe informação primeiro
        if zenity --question --title="Kernel Customizado" --text="$install_msg\n\nDeseja instalar o Kernel Customizado agora? (Compatível apenas com 3.7.*)" --width=500; then
            resp_kernel="s"
        else
            resp_kernel="n"
        fi
    else
        # Fallback Texto Original
        echo -e "\n------------------------------------------------------------"
        echo -e "$install_msg"
        echo "------------------------------------------------------------"
        read -rp "Deseja instalar o Kernel Customizado agora? Compativel apenas com SteamOs 3.7.* (s/n): " input_val
        resp_kernel="$input_val"
    fi

    if [[ "$resp_kernel" =~ ^[Ss]$ ]]; then
        # --- NEW DOWNLOAD LOGIC START ---
        local REPO="V10lator/linux-charcoal"
        local DEST_DIR="./kernel"

        _log "Preparando diretório de download do Kernel..."
        # Limpa versões antigas para evitar conflitos
        if [ -d "$DEST_DIR" ]; then rm -rf "$DEST_DIR"; fi
        mkdir -p "$DEST_DIR"
        # Adição solicitada: Mudar a propriedade da pasta para o usuário deck
        chown -R deck:deck "$DEST_DIR" 2>/dev/null || true

        _log "Buscando o último release de $REPO..."
        echo "Consultando API do GitHub..."

        # Busca URLs e filtra apenas arquivos .pkg.tar.zst (pacotes instaláveis)
        local DOWNLOAD_URLS
        DOWNLOAD_URLS=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" \
            | grep "browser_download_url" \
            | cut -d '"' -f 4 \
            | grep "\.pkg\.tar\.zst$")

        if [ -z "$DOWNLOAD_URLS" ]; then
            _ui_info "erro" "Nenhum pacote de kernel (.pkg.tar.zst) encontrado no repositório."
            return 1
        fi

        # Download loop
        for url in $DOWNLOAD_URLS; do
            local filename
            filename=$(basename "$url")
            _log "Baixando: $filename"
            echo "Baixando $filename..."
            if ! wget -q --show-progress -P "$DEST_DIR" "$url"; then
                _ui_info "erro" "Falha ao baixar $filename. Verifique sua internet."
                return 1
            fi
        done
        _log "Download do Kernel concluído."
        # --- NEW DOWNLOAD LOGIC END ---

        _log "Iniciando instalação do kernel customizado..."
        _steamos_readonly_disable_if_needed

        # Ajuste de configuração do pacman para pacotes locais não assinados
       # sed -i "s/Required DatabaseOptional/TrustAll/g" /etc/pacman.conf &>/dev/null

        # Limpeza de chaves e cache para evitar conflitos
       # rm -rf /home/.steamos/offload/var/cache/pacman/pkg/{*,.*} &>/dev/null
        # rm -rf /etc/pacman.d/gnupg &>/dev/null

        # Inicialização do chaveiro
       # echo "Inicializando chaves do pacman..."
       # pacman-key --init
       # pacman-key --populate
        steamos-devmode enable --no-prompt

        echo "Instalando Kernel (linux-charcoal)..."
        echo ">>> QUANDO SOLICITADO, CONFIRME A REMOÇÃO DO PACOTE 'linux-neptune' <<<"

        if command -v zenity &>/dev/null; then
            zenity --info --text="A instalação continuará no terminal.\n\nPor favor, confirme a remoção do 'linux-neptune' digitando 's' ou 'y' quando o pacman solicitar." --width=400 2>/dev/null || true
        fi

        # Instalação interativa (o usuário precisa confirmar a substituição)
        # O wildcard agora aponta para a pasta onde baixamos os arquivos
        if pacman -U "$DEST_DIR"/*.pkg.tar.zst; then
             _log "Kernel customizado instalado com sucesso."

         # Garante atualização do GRUB após a troca do kernel
             update-grub &>/dev/null || true
        else
             _ui_info "erro" "Falha na instalação do Kernel."
        fi
    fi
}

aplicar_zswap() {
    _log "Aplicando ZSWAP (Híbrido AC/Battery)"

    # --- CORREÇÃO: Cria e ajusta permissões da pasta DXVK ---
    _setup_dxvk_folder

    _executar_reversao
    _steamos_readonly_disable_if_needed;
    _optimize_gpu
    _configure_ulimits
    create_common_scripts_and_services
    create_power_rules # Ativa monitoramento de energia com lógica híbrida
    _configure_irqbalance

    # Mascara o ZRAM padrão do sistema para evitar conflitos (Correto e Necessário)
    systemctl stop systemd-zram-setup@zram0.service 2>/dev/null || true
    systemctl mask systemd-zram-setup@zram0.service 2>/dev/null || true
    _log "Serviço systemd-zram-setup@zram0.service mascarado."

    # --- TWEAK FSTAB ---
    _backup_file_once /etc/fstab # Garante que o backup esteja atualizado
    if grep -q " /home " /etc/fstab 2>/dev/null; then
        sed -E -i 's|(^[^[:space:]]+[[:space:]]+/home[[:space:]]+[^[:space:]]+[[:space:]]+ext4[[:space:]]+)[^[:space:]]+|\1defaults,nofail,noatime,commit=60,data=writeback,x-systemd.growfs|g' /etc/fstab || true
        _log "tweak FSTAB para /home (ext4) aplicado."
    fi
    # --- FIM TWEAK FSTAB ---

    local free_space_gb; free_space_gb=$(df -BG /home | awk 'NR==2 {print $4}' | tr -d 'G' || echo 0)
    if (( free_space_gb < zswap_swapfile_size_gb )); then _ui_info "erro" "espaço insuficiente"; exit 1; fi

    fallocate -l "${zswap_swapfile_size_gb}G" "$swapfile_path" 2>/dev/null || dd if=/dev/zero of="$swapfile_path" bs=1G count="$zswap_swapfile_size_gb" status=progress
    chmod 600 "$swapfile_path" || true; mkswap "$swapfile_path" || true
    sed -i "\|${swapfile_path}|d" /etc/fstab 2>/dev/null || true; echo "$swapfile_path none swap sw,pri=-2 0 0" >> /etc/fstab
    swapon --priority -2 "$swapfile_path" || true

    _write_sysctl_file /etc/sysctl.d/99-sdweak-performance.conf "${base_sysctl_params[@]}"
    sysctl --system || true

    _backup_file_once "$grub_config"
    
    # ATUALIZAÇÃO KERNEL PARAMS: Adicionado audit=0, nowatchdog e nmi_watchdog=0
    local kernel_params=("zswap.enabled=1" "zswap.compressor=zstd" "zswap.max_pool_percent=35" "zswap.zpool=zsmalloc" "zswap.shrinker_enabled=1" "mitigations=off" "psi=1" "rcutree.enable_rcu_lazy=1" "audit=0" "nmi_watchdog=0" "nowatchdog" "split_lock_detect=off" "amdgpu.ppfeaturemask=0xffffffff")
    
    local current_cmdline; current_cmdline=$(grep -E '^GRUB_CMDLINE_LINUX=' "$grub_config" | sed -E 's/^GRUB_CMDLINE_LINUX="([^"]*)"(.*)/\1/' || true)
    local new_cmdline="$current_cmdline"
    for param in "${kernel_params[@]}"; do local key="${param%%=*}"; new_cmdline=$(echo "$new_cmdline" | sed -E "s/ ?${key}(=[^ ]*)?//g"); done
    for param in "${kernel_params[@]}"; do new_cmdline="$new_cmdline $param"; done
    new_cmdline=$(echo "$new_cmdline" | tr -s ' ' | sed -E 's/^ //; s/ $//')
    sed -i -E "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$new_cmdline\"|" "$grub_config" || true

    steamos-update-grub &>/dev/null || update-grub &>/dev/null || true
    mkinitcpio -P &>/dev/null || true

    create_persistent_configs

    cat <<'ZSWAP_SCRIPT' > /usr/local/bin/zswap-config.sh
#!/usr/bin/env bash
echo 1 > /sys/module/zswap/parameters/enabled 2>/dev/null || true
echo zstd > /sys/module/zswap/parameters/compressor 2>/dev/null || true
echo 35 > /sys/module/zswap/parameters/max_pool_percent 2>/dev/null || true
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
    systemctl enable --now "${otimization_services[@]}" zswap-config.service || true
    if command -v udevadm &>/dev/null; then udevadm trigger --action=change --subsystem-match=power_supply; fi
    _ui_info "sucesso" "ZSWAP aplicado."

    echo -e "\n------------------------------------------------------------"
    echo "Deseja otimizar o Shader Cache para jogos instalados no MicroSD?"
    echo "Benefício: Move os arquivos de cache (pequenos e frequentes) do SD para o SSD interno."
    echo "Isso reduz significativamente os 'engasgos' (stutters) em jogos rodando pelo cartão de memória."
    echo "------------------------------------------------------------"

    local resp_shader="n"
    if command -v zenity &>/dev/null; then
        if zenity --question --text="Deseja otimizar o Shader Cache para jogos instalados no MicroSD?\n\nIsso move o cache para o SSD, reduzindo stutters em jogos do cartão SD." --width=400; then
            resp_shader="s"
        fi
    else
        read -rp "Aplicar otimização do Shader Cache? (s/n): " input_shader
        resp_shader="$input_shader"
    fi

    if [[ "$resp_shader" =~ ^[Ss]$ ]]; then
        otimizar_sdcard_cache
    fi

    # --- OFERTA DE KERNEL CUSTOMIZADO ---
    _instalar_kernel_customizado

    _ui_info "aviso" "Dica extra: Configure o UMA Buffer Size para 4GB na BIOS para máximo desempenho."
    _ui_info "aviso" "Reinicie para efeito total (Kernel, GRUB e EnvVars)."
}

aplicar_zram() {
    _log "Aplicando ZRAM (Híbrido AC/Battery)"

    # --- CORREÇÃO: Cria e ajusta permissões da pasta DXVK ---
    _setup_dxvk_folder

    _executar_reversao
    _steamos_readonly_disable_if_needed;
    _optimize_gpu
    _configure_ulimits
    create_common_scripts_and_services
    create_power_rules # Ativa monitoramento de energia com lógica híbrida
    _configure_irqbalance

    # --- CORREÇÃO APLICADA: Mascara o ZRAM padrão do sistema para evitar conflitos ---
    systemctl stop systemd-zram-setup@zram0.service 2>/dev/null || true
    systemctl mask systemd-zram-setup@zram0.service 2>/dev/null || true
    _log "Serviço systemd-zram-setup@zram0.service mascarado."

    # --- TWEAK FSTAB ---
    _backup_file_once /etc/fstab # Garante que o backup esteja atualizado
    if grep -q " /home " /etc/fstab 2>/dev/null; then
        sed -E -i 's|(^[^[:space:]]+[[:space:]]+/home[[:space:]]+[^[:space:]]+[[:space:]]+ext4[[:space:]]+)[^[:space:]]+|\1defaults,nofail,noatime,commit=60,data=writeback,x-systemd.growfs|g' /etc/fstab || true
        _log "tweak FSTAB para /home (ext4) aplicado."
    fi
    # --- FIM TWEAK FSTAB ---

    _write_sysctl_file /etc/sysctl.d/99-sdweak-performance.conf "${base_sysctl_params[@]}"
    sysctl --system || true

    _backup_file_once "$grub_config"
    
    # ATUALIZAÇÃO KERNEL PARAMS: Adicionado audit=0, nowatchdog e nmi_watchdog=0
    local kernel_params=("zswap.enabled=0" "mitigations=off" "psi=1" "rcutree.enable_rcu_lazy=1" "audit=0" "nmi_watchdog=0" "nowatchdog" "split_lock_detect=off" "amdgpu.ppfeaturemask=0xffffffff")
    
    local current_cmdline; current_cmdline=$(grep -E '^GRUB_CMDLINE_LINUX=' "$grub_config" | sed -E 's/^GRUB_CMDLINE_LINUX="([^"]*)"(.*)/\1/' || true)
    local new_cmdline="$current_cmdline"
    for param in "${kernel_params[@]}"; do local key="${param%%=*}"; new_cmdline=$(echo "$new_cmdline" | sed -E "s/ ?${key}(=[^ ]*)?//g" | sed -E "s/ ?zswap\.[^ =]+(=[^ ]*)?//g"); done
    for param in "${kernel_params[@]}"; do new_cmdline="$new_cmdline $param"; done
    new_cmdline=$(echo "$new_cmdline" | tr -s ' ' | sed -E 's/^ //; s/ $//')
    sed -i -E "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$new_cmdline\"|" "$grub_config" || true
    steamos-update-grub &>/dev/null || update-grub &>/dev/null || true
    mkinitcpio -P &>/dev/null || true

    create_persistent_configs

    cat <<'ZRAM_SCRIPT' > /usr/local/bin/zram-config.sh
#!/usr/bin/env bash
CPU_CORES=$(nproc)
if [[ -z "$CPU_CORES" ]]; then CPU_CORES=4; fi
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
modprobe zram num_devices=2 2>/dev/null || true
if command -v udevadm &>/dev/null; then udevadm settle; else sleep 3; fi

if [ -d "/sys/block/zram0" ]; then
    echo 1 > /sys/block/zram0/reset 2>/dev/null || true
    if command -v udevadm &>/dev/null; then udevadm settle; else sleep 0.5; fi
    echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
    echo "$CPU_CORES" > /sys/block/zram0/max_comp_streams 2>/dev/null || true
    echo zsmalloc > /sys/block/zram0/zpool 2>/dev/null || true
    echo 2G > /sys/block/zram0/disksize 2>/dev/null || true
    mkswap /dev/zram0 2>/dev/null || true
    swapon /dev/zram0 -p 3000 2>/dev/null || true
fi

if [ -d "/sys/block/zram1" ]; then
    echo 1 > /sys/block/zram1/reset 2>/dev/null || true
    if command -v udevadm &>/dev/null; then udevadm settle; else sleep 0.5; fi
    echo zstd > /sys/block/zram1/comp_algorithm 2>/dev/null || true
    echo "$CPU_CORES" > /sys/block/zram1/max_comp_streams 2>/dev/null || true
    echo zsmalloc > /sys/block/zram1/zpool 2>/dev/null || true
    echo 4G > /sys/block/zram1/disksize 2>/dev/null || true
    mkswap /dev/zram1 2>/dev/null || true
    swapon /dev/zram1 -p 10 2>/dev/null || true
fi

echo 1 > /sys/kernel/mm/page_idle/enable 2>/dev/null || true
sysctl -w vm.fault_around_bytes=32 2>/dev/null || true
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
    systemctl enable --now "${otimization_services[@]}" zram-config.service || true
    if command -v udevadm &>/dev/null; then udevadm trigger --action=change --subsystem-match=power_supply; fi
    _ui_info "sucesso" "ZRAM Dual Layer aplicado."

    echo -e "\n------------------------------------------------------------"
    echo "Deseja otimizar o Shader Cache para jogos instalados no MicroSD?"
    echo "Benefício: Move os arquivos de cache (pequenos e frequentes) do SD para o SSD interno."
    echo "Isso reduz significativamente os 'engasgos' (stutters) em jogos rodando pelo cartão de memória."
    echo "------------------------------------------------------------"

    local resp_shader="n"
    if command -v zenity &>/dev/null; then
        if zenity --question --text="Deseja otimizar o Shader Cache para jogos instalados no MicroSD?\n\nIsso move o cache para o SSD, reduzindo stutters em jogos do cartão SD." --width=400; then
            resp_shader="s"
        fi
    else
        read -rp "Aplicar otimização do Shader Cache? (s/n): " input_shader
        resp_shader="$input_shader"
    fi

    if [[ "$resp_shader" =~ ^[Ss]$ ]]; then
        otimizar_sdcard_cache
    fi

    # --- OFERTA DE KERNEL CUSTOMIZADO ---
    _instalar_kernel_customizado

    _ui_info "aviso" "Dica extra: Configure o UMA Buffer Size para 4GB na BIOS para máximo desempenho."
    _ui_info "aviso" "Reinicie o sistema para efeito total."
}

reverter_alteracoes() {
    _executar_reversao
    _ui_info "sucesso" "Reversão completa. Reinicie."
}

# --- NOVA FUNÇÃO: Remover kernel customizado e reinstalar linux-neptune ---
_restore_kernel_to_neptune() {

steamos-devmode enable --no-prompt

    _log "Iniciando restauração do kernel padrão (linux-neptune)"

    if ! command -v pacman &>/dev/null; then
        _ui_info "erro" "pacman não encontrado no sistema. Não é possível reinstalar o kernel."
        return 1
    fi

    # Remove linux-charcoal-611 se instalado
    if pacman -Q linux-charcoal-611 &>/dev/null; then
        _log "linux-charcoal-611 detectado. Removendo..."
        _steamos_readonly_disable_if_needed
        if pacman -Rs --noconfirm linux-charcoal-611; then
            _log "linux-charcoal-611 removido com sucesso."
        else
            _ui_info "erro" "Falha ao remover linux-charcoal-611"
            return 1
        fi
    else
        _log "linux-charcoal-611 não está instalado. Pulando remoção."
        _ui_info "info" "Kernel customizado não encontrado instalado."
    fi

    # Instala linux-neptune-611
    _log "Instalando linux-neptune-611..."
    if pacman -S --noconfirm linux-neptune-611; then
        _log "linux-neptune-611 instalado com sucesso."
        # Atualiza GRUB/initramfs onde aplicável
        if command -v update-grub &>/dev/null; then update-grub; else steamos-update-grub &>/dev/null || true; fi
        mkinitcpio -P &>/dev/null || true
        _ui_info "sucesso" "Kernel padrão (linux-neptune-611) reinstalado. Reinicie o sistema para completar."
        return 0
    else
        _ui_info "erro" "Falha ao instalar linux-neptune-611"
        return 1
    fi
}

main() {
    echo -e "\n=== Turbo Decky $versao ==="
    echo "Bem vindo ao Turbo Decky! Otimize seu Steam Deck para obter o melhor desempenho em jogos!"
    echo "Todas as otimizações são seguras e podem ser revertidas."

    if command -v zenity &>/dev/null; then
        # Opção Zenity
        local z_escolha
        z_escolha=$(zenity --list --title="Turbo Decky - $versao" \
            --text="Escolha a opção desejada:" \
            --radiolist \
            --column="Ativo" --column="Opção" --column="Descrição" \
            TRUE "1" "Aplicar Otimizações Recomendadas (ZSWAP + Tuning)" \
            FALSE "2" "Aplicar Otimizações (ZRAM + Tuning - Pouco espaço)" \
            FALSE "3" "Reverter Tudo" \
            FALSE "4" "Reverter Otimizações SD Card" \
            FALSE "5" "Restaurar Kernel Padrão (Remover linux-charcoal)" \
            FALSE "6" "Sair" \
            --height 350 --width 500 --hide-column=2 --print-column=2 || echo "5")

        # Tratamento se o usuário cancelar (z_escolha vazio)
        if [ -z "$z_escolha" ]; then z_escolha="5"; fi
        escolha="$z_escolha"
    else
        # Opção Legado Texto
        echo "1) Aplicar Otimizações Recomendadas (ZSWAP + Tuning)"
        echo "2) Aplicar Otimizações (ZRAM + Tuning - Alternativa para pouco espaço)"
        echo "3) Reverter Tudo"
        echo "4) Reverter Otimizações de shader cache de jogos instalados no MicroSD"
        echo "5) Reinstalar kernel padrão (remover kernel customizado)"
        echo "6) Sair"
        read -rp "Opção: " escolha
    fi

    case "$escolha" in
        1) aplicar_zswap ;;
        2) aplicar_zram ;;
        3) reverter_alteracoes ;;
        4) reverter_sdcard_cache ;;
        5) _restore_kernel_to_neptune ;;
        6) exit 0 ;;
        *)
           _ui_info "erro" "Opção Inválida"
           if command -v zenity &>/dev/null; then exit 1; else main "$@"; fi
           ;;
    esac
}

main "$@"
