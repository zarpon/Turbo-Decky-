#!/usr/bin/env bash
set -euo pipefail

# --- versão e autor do script ---

versao="2.9.04- Timeless Child"
autor="Jorge Luis"
pix_doacao="jorgezarpon@msn.com"

# --- constantes e variáveis ---
readonly swapfile_path="/home/swapfile"
readonly grub_config="/etc/default/grub"
# Calcula 40 da RAM total de forma dinâmica
readonly total_mem_gb=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
readonly zswap_swapfile_size_gb=$(( (total_mem_gb * 60) / 100 ))

readonly zram_swapfile_size_gb="2"
readonly backup_suffix="bak-turbodecky"
readonly logfile="/var/log/turbodecky.log"

# --- Diretórios persistentes (resistem a atualizações do SteamOS) ---
readonly turbodecky_dir="/var/lib/turbodecky"
readonly turbodecky_bin="${turbodecky_dir}/bin"

# --- Constantes para otimização do MicroSD ---
readonly sdcard_device="/dev/mmcblk0p1"
readonly nvme_shadercache_target_path="/home/deck/sd_shadercache"
# Caminho do cache DXVK
readonly dxvk_cache_path="/home/deck/dxvkcache"

# --- parâmetros sysctl base (ATUALIZADO PARA LATÊNCIA E SCHEDULER) ---
readonly base_sysctl_params=(
    "vm.workingset_protection=0"
    "vm.dirty_background_bytes=227001600"
    "vm.dirty_bytes=556531840"
    "vm.dirty_expire_centisecs=1500"       
    "vm.dirty_writeback_centisecs=1500"      
    "vm.compaction_proactiveness=10"
    "kernel.numa_balancing=0"
    "vm.compact_unevictable_allowed=0"
    "vm.watermark_boost_factor=0"
    "vm.zone_reclaim_mode=0"
    "vm.mmap_rnd_compat_bits=16"
    "vm.unprivileged_userfaultfd=1"
    "vm.hugetlb_optimize_vmemmap=0"
    "fs.aio-max-nr=1048576"
    "fs.epoll.max_user_watches=100000"
    "fs.inotify.max_user_watches=524288"
    "fs.pipe-max-size=2097152"
    "fs.pipe-user-pages-soft=65536"
    "fs.file-max=1000000"   
    # --- Scheduler (scx_lavd friendly) ---
    "kernel.sched_autogroup_enabled=0"
    "kernel.split_lock_mitigate=0"
    # --- WATCHDOG E NETWORK ---
    "kernel.nmi_watchdog=0"
    "kernel.soft_watchdog=0"
    "kernel.watchdog=0"
    "kernel.core_pattern=/dev/null"
    "kernel.core_pipe_limit=0"
    "kernel.printk_devkmsg=off"
    "net.core.default_qdisc=cake"
    "net.ipv4.tcp_congestion_control=bbr"
    "net.core.netdev_max_backlog=16384"
    "net.ipv4.tcp_fastopen=3"  
    # --- REDE (BAIXA LATÊNCIA / JOGOS ONLINE) ---
    "net.ipv4.tcp_slow_start_after_idle=0"
    "net.ipv4.tcp_mtu_probing=1" # Ajuda em conexões instáveis
)

# --- listas de serviços para ativar/monitorar ---
readonly otimization_services=(
    "thp-config.service"
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
    "RADEONSI_SHADER_PRECOMPILE=true"
    "MESA_DISK_CACHE_COMPRESSION=zstd"
    "MESA_SHADER_CACHE_MAX_SIZE=10G"
    "VKD3D_SHADER_CACHE=1"
    "PROTON_FORCE_LARGE_ADDRESS_AWARE=1"
    "WINE_DISABLE_PROTOCOL_FORK=1"
    "WINE_DISABLE_WRITE_WATCH=1" 
    "PROTON_USE_NTSYNC=1"
    "VKD3D_CONFIG=force_host_cached"
    # --- Otimização de Memória Glibc (Equilíbrio Performance/Estabilidade) ---
    # Trim de 2MB: Evita micro-stutters, mas libera RAM muito antes de causar OOM.
    "MALLOC_TRIM_THRESHOLD_=2097152"
    # MMAP em 1MB: Tira o overhead de alocações frequentes, mas deixa as grandes para o mmap.
    "MALLOC_MMAP_THRESHOLD_=1048576"
    # Pad de 256KB: Dobro do padrão, reduzindo churn de sbrk sem desperdício.
    "MALLOC_TOP_PAD_=262144"   
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

# --- Nova: detecta o tipo de sistema de arquivos para um caminho ---
_get_fstype_for_path() {
    local target="$1"
    # Usa findmnt para determinar FSTYPE do ponto de montagem que contém o target
    local fstype
    fstype=$(findmnt -n -o FSTYPE --target "$target" 2>/dev/null || true)
    echo "${fstype:-}"
}

# --- Nova: cria swapfile corretamente considerando Btrfs ---
_create_swapfile() {
    local path="$1"; local size_gb="$2"
    local dir; dir=$(dirname "$path")
    mkdir -p "$dir" 2>/dev/null || true

    local fstype; fstype=$(_get_fstype_for_path "$dir")
    _log "criando swapfile em: $path (fs: ${fstype:-unknown})"

    if [[ "$fstype" == "btrfs" ]]; then
        # Em btrfs, criar um diretório dedicado sem CoW e colocar o swapfile lá,
        # então criar um symlink no caminho desejado para manter compatibilidade com $swapfile_path.
        local swapdir="${dir}/.swap"
        mkdir -p "$swapdir" 2>/dev/null || true

        # Tenta marcar o diretório com NOCOW (chattr +C) *antes* de criar o arquivo
        chattr +C "$swapdir" 2>/dev/null || true

        local actual_path="${swapdir}/$(basename "$path")"

        # Cria o arquivo (fallocate preferido; dd como fallback)
        if ! fallocate -l "${size_gb}G" "$actual_path" 2>/dev/null; then
            dd if=/dev/zero of="$actual_path" bs=1M count=$((size_gb * 1024)) status=progress 2>/dev/null || true
        fi

        # Ajustes de permissões e swap
        chmod 600 "$actual_path" 2>/dev/null || true
        # mkswap no arquivo real
        mkswap "$actual_path" 2>/dev/null || true

        # Remove entrada antiga ou arquivo/symlink e criar symlink no local esperado
        if [ -e "$path" ] || [ -L "$path" ]; then
            rm -f "$path" 2>/dev/null || true
        fi
        ln -s "$actual_path" "$path" 2>/dev/null || true

        _log "swapfile criado em (btrfs-safe): $actual_path -> symlink $path"
    else
        # Sistemas que não são btrfs: cria normalmente no caminho solicitado
        # fallocate preferível para velocidade; dd fallback
        if ! fallocate -l "${size_gb}G" "$path" 2>/dev/null; then
            dd if=/dev/zero of="$path" bs=1G count="$size_gb" status=progress 2>/dev/null || true
        fi
        chmod 600 "$path" 2>/dev/null || true
        mkswap "$path" 2>/dev/null || true
        _log "swapfile criado: $path"
    fi

    return 0
}

# --- NOVA FUNÇÃO: Tenta aplicar tweak no /etc/fstab SOMENTE se /home for EXT4 ---
_apply_fstab_tweak_if_ext4() {
    local fstab_file="/etc/fstab"
    local mount_point="/home"
    local fstype; fstype=$(_get_fstype_for_path "$mount_point")
    _backup_file_once "$fstab_file"
    if [[ "$fstype" == "ext4" ]]; then
        if grep -q " /home " "$fstab_file" 2>/dev/null; then
            sed -E -i 's|(^[^[:space:]]+[[:space:]]+/home[[:space:]]+[^[:space:]]+[[:space:]]+ext4[[:space:]]+)[^[:space:]]+|\1defaults,nofail,noatime,data=writeback,x-systemd.growfs|g' "$fstab_file" || true
            _log "tweak FSTAB para /home (ext4) aplicado."
        else
            _log "nenhuma entrada /home encontrada em $fstab_file para ajustar."
        fi
    else
        _log "Tweak FSTAB para /home SKIPPED: filesystem /home é '$fstype' (somente aplica se ext4)."
    fi
}

_setup_dxvk_folder() {
    _log "Configurando pasta DXVK Cache..."
    if [ ! -d "$dxvk_cache_path" ]; then
        mkdir -p "$dxvk_cache_path"
        _log "Pasta criada: $dxvk_cache_path"
    fi
    # Corrige permissões para o usuário 'deck' (UID 1000)
    chown -R 1000:1000 "$dxvk_cache_path" 2>/dev/null || chown -R deck:deck "$dxvk_cache_path" 2>/dev/null || true
    chmod 755 "$dxvk_cache_path"
    _log "Permissões da pasta DXVK ajustadas para usuário deck."
}

_configure_ulimits() {
    _log "aplicando limite de arquivo aberto (ulimit) alto (1048576)"
    mkdir -p /etc/security/limits.d
    cat <<'EOF' > /etc/security/limits.d/99-game-limits.conf
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
* hard memlock 2147484
* soft memlock 2147484

EOF
    _log "/etc/security/limits.d/99-game-limits.conf criado/atualizado."
}

_configure_irqbalance() {
    _log "configurando irqbalance..."

    systemctl stop irqbalance.service 2>/dev/null || true
    systemctl unmask irqbalance.service 2>/dev/null || true
    systemctl start irqbalance.service 2>/dev/null || true
    _log "irqbalance configurado com sucesso"
}


_setup_lavd_scheduler() {
    _log "Iniciando instalação dinâmica: LAVD Scheduler (CachyOS Bleeding Edge)"

    _steamos_readonly_disable_if_needed
    sudo rm -f /var/lib/pacman/db.lck

    # 1. Identificar a última versão disponível via Web Scraping
    _log "Consultando última versão no repositório CachyOS..."
    local base_url="https://mirror.cachyos.org/repo/x86_64/cachyos"

    # Captura a versão e o release mais recentes de forma dinâmica
    local latest_version=$(curl -sL "$base_url" | grep -oP 'scx-scheds-\K[0-9.]+(?=-[0-9]+-x86_64\.pkg\.tar\.zst)' | sort -V | tail -n 1)
    local latest_release=$(curl -sL "$base_url" | grep -oP "scx-scheds-${latest_version}-\K[0-9]+(?=-x86_64\.pkg\.tar\.zst)" | head -n 1)

    # Fallback caso o scraping falhe
    if [[ -z "$latest_version" ]]; then
        _log "Aviso: Falha na detecção online. Usando 1.0.20-1 como base estável."
        latest_version="1.0.20"
        latest_release="1"
    fi

    local sched_pkg="scx-scheds-${latest_version}-${latest_release}-x86_64.pkg.tar.zst"
    local tools_pkg="scx-tools-${latest_version}-${latest_release}-x86_64.pkg.tar.zst"

    # 2. Download Direto (Bypass de bloqueios do pacman.conf)
    _log "Baixando versão: ${latest_version}-${latest_release}..."
    curl -L "${base_url}/${tools_pkg}" -o "/tmp/${tools_pkg}"
    curl -L "${base_url}/${sched_pkg}" -o "/tmp/${sched_pkg}"

    # 3. Instalação Local (Resolve ciclo de dependências scx-tools <-> scx-scheds)
    _log "Instalando via Local Upgrade..."
    if ! sudo pacman -U --noconfirm "/tmp/${tools_pkg}" "/tmp/${sched_pkg}"; then
        _log "Erro na instalação CachyOS. Usando versão Neptune (Valve) como redundância."
        sudo pacman -S --noconfirm scx-scheds
    fi

    # 4. Configuração de Privilégios (Crucial para o eBPF no SteamOS)
    sudo systemctl disable --now scx.service || true
    sudo setcap 'cap_sys_admin,cap_sys_ptrace,cap_net_admin,cap_dac_override,cap_sys_resource+eip' /usr/bin/scx_lavd

    # 5. Serviço Systemd (Turbo Decky)
    sudo bash -c 'cat <<UNIT > /etc/systemd/system/scx_lavd.service
[Unit]
Description=Turbo Decky - LAVD Scheduler (CachyOS)
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/bin/scx_lavd --performance
Restart=always
RestartSec=10
Nice=-20

[Install]
WantedBy=multi-user.target
UNIT'

    sudo systemctl daemon-reload
    sudo systemctl enable --now scx_lavd.service

    # Limpeza de arquivos temporários
    rm -f "/tmp/${tools_pkg}" "/tmp/${sched_pkg}"

    _log "LAVD Scheduler ${latest_version} ativado com sucesso."
}

create_persistent_configs() {
    _log "criando arquivos de configuração persistentes"
    mkdir -p /etc/tmpfiles.d /etc/modprobe.d /etc/modules-load.d

    # MGLRU
    cat << EOF > /etc/tmpfiles.d/mglru.conf
w /sys/kernel/mm/lru_gen/enabled - - - - 7
w /sys/kernel/mm/lru_gen/min_ttl_ms - - - - 1000
EOF
    

    # NTSYNC - Carregamento Persistente do Módulo
    echo "ntsync" > /etc/modules-load.d/ntsync.conf
    _log "configuração ntsync criada em /etc/modules-load.d/ntsync.conf"

    _log "configurações mglru e ntsync criadas."
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
    # --- SCRIPT DE MONITORAMENTO (EMBUTIDO) ---
    # ------------------------------------------------------------------
    mkdir -p "${turbodecky_bin}"
    cat <<'EOF' > "${turbodecky_bin}/turbodecky-power-monitor.sh"
#!/usr/bin/env bash

# Funções de Detecção
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
      sleep 2
      for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
            echo "performance" > "$epp" 2>/dev/null || true
        done
    fi
    
    if command -v iw &>/dev/null; then
        WLAN=$(iw dev | awk '$1=="Interface"{print $2}' | head -n1)
        [ -n "$WLAN" ] && iw dev "$WLAN" set power_save off 2>/dev/null || true
    fi

else
    # --- MODO BATERIA (PADRÃO/ECONOMIA) ---
    logger "TurboDecky: Bateria - Revertendo (Híbrido)"

    # CPU: Balanceada (Padrão SteamOS)
    if [ -f /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference ]; then
        for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
            echo "balance_performance" > "$epp" 2>/dev/null || true
        done
    fi
    
    if command -v iw &>/dev/null; then
        WLAN=$(iw dev | awk '$1=="Interface"{print $2}' | head -n1)
        [ -n "$WLAN" ] && iw dev "$WLAN" set power_save off 2>/dev/null || true
    fi
fi
EOF
    chmod +x "${turbodecky_bin}/turbodecky-power-monitor.sh"

    # 4. CRIAÇÃO DO SERVICE (Para ser acionado pelo UDEV/SYSTEMD)
    cat <<UNIT > /etc/systemd/system/turbodecky-power-monitor.service
[Unit]
Description=TurboDecky Power Monitor (oneshot udev-triggered)
Wants=sys-devices-virtual-power_supply-*/device
[Service]
Type=oneshot
ExecStart=${turbodecky_bin}/turbodecky-power-monitor.sh
UNIT
    systemctl daemon-reload || true

    # 5. Regra UDEV OTIMIZADA (Gatilho Systemd - Foca apenas nos tipos de fonte AC)
    cat <<'UDEV' > /etc/udev/rules.d/99-turbodecky-power.rules
SUBSYSTEM=="power_supply", ACTION=="change", ATTR{type}=="Mains", TAG+="systemd", ENV{SYSTEMD_WANTS}="turbodecky-power-monitor.service"
SUBSYSTEM=="power_supply", ACTION=="change", ATTR{type}=="ACAD", TAG+="systemd", ENV{SYSTEMD_WANTS}="turbodecky-power-monitor.service"
SUBSYSTEM=="power_supply", ACTION=="change", ATTR{type}=="USB_C", TAG+="systemd", ENV{SYSTEMD_WANTS}="turbodecky-power-monitor.service"
SUBSYSTEM=="power_supply", ACTION=="change", ATTR{type}=="USB-PD", TAG+="systemd", ENV{SYSTEMD_WANTS}="turbodecky-power-monitor.service"
UDEV

    # 6. Ativar imediatamente
    if command -v udevadm &>/dev/null; then
        udevadm control --reload-rules 2>/dev/null || true
        udevadm trigger --action=change --subsystem-match=power_supply 2>/dev/null || true
    fi
    systemctl start --no-block turbodecky-power-monitor.service || true
    _log "monitoramento de energia configurado (THP Latency Tuned - Híbrido/Systemd)."
}

create_common_scripts_and_services() {
    _log "criando scripts e services comuns"
    mkdir -p "${turbodecky_bin}" /etc/systemd/system /etc/environment.d

    # --- 1. APLICAÇÃO DE VARIÁVEIS DE AMBIENTE ---
    if [ ${#game_env_vars[@]} -gt 0 ]; then
        printf "%s\n" "${game_env_vars[@]}" > /etc/environment.d/turbodecky-game.conf
        chmod 644 /etc/environment.d/turbodecky-game.conf
        _log "variáveis de ambiente configuradas em /etc/environment.d/turbodecky-game.conf"
    fi

    install_io_boost_uadev() {
    local script_path="${turbodecky_bin}/io-boost.sh"
    local unit_path="/etc/systemd/system/io-boost@.service"
    local rule_path="/etc/udev/rules.d/99-io-boost.rules"
    local tmp

    mkdir -p "${turbodecky_bin}"

    # Backup se já existir
    for f in "$script_path" "$unit_path" "$rule_path"; do
        if [ -f "$f" ]; then
            if type _backup_file_once >/dev/null 2>&1; then
                _backup_file_once "$f"
            else
                cp -a "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
            fi
        fi
    done

    # --- ${turbodecky_bin}/io-boost.sh ---
    tmp=$(mktemp /tmp/io-boost.XXXXXX) || { _log "erro: mktemp falhou"; return 1; }
    cat > "$tmp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Usage: io-boost.sh <device-name>
DEV="$1"
if [ -z "$DEV" ]; then
  echo "uso: $0 <device>" >&2
  exit 2
fi

# Pequena pausa para garantir que o kernel registrou a estrutura sysfs
sleep 2

resolve_parent() {
  local dev="$1"
  if [ -d "/sys/block/$dev" ]; then
    printf '%s' "$dev"
    return 0
  fi
  local path
  path=$(readlink -f "/sys/class/block/$dev" 2>/dev/null) || return 1
  while [ -n "$path" ] && [ "$path" != "/" ]; do
    local name
    name=$(basename "$path")
    if [[ "$name" =~ ^sd[a-z]+$ || "$name" =~ ^mmcblk[0-9]+$ || "$name" =~ ^nvme[0-9]+n[0-9]+$ ]]; then
      printf '%s' "$name"
      return 0
    fi
    path=$(dirname "$path")
  done
  printf '%s' "$dev"
  return 0
}

DEV_BASE=$(resolve_parent "$DEV") || DEV_BASE="$DEV"
DEV_PATH="/sys/block/$DEV_BASE"
QUEUE_PATH="$DEV_PATH/queue"

[ -d "$DEV_PATH" ] || exit 0

safe_write() {
  local file="$1" val="$2"
  if [ -w "$file" ] || [ -f "$file" ]; then
    printf "%s" "$val" > "$file" 2>/dev/null || true
  fi
}

# Desativa coleta de estatísticas I/O (reduz overhead da CPU)
safe_write "$QUEUE_PATH/iostats" 0
safe_write "$QUEUE_PATH/add_random" 0

case "$DEV_BASE" in
  nvme*)
    # NVMe: Prioridade  none -> kyber
    if printf "none" > "$QUEUE_PATH/scheduler" 2>/dev/null; then
        : # none aplicado com sucesso
    elif printf "kyber" > "$QUEUE_PATH/scheduler" 2>/dev/null; then
        : # Fallback para kyber
    else
        printf "mq-deadline" > "$QUEUE_PATH/scheduler" 2>/dev/null || true
    fi

    # NVMe se beneficia de completar requisições na CPU que iniciou (cache locality)
    safe_write "$QUEUE_PATH/rq_affinity" 2
        # Adicionar: Desativar merges para reduzir latência de CPU em NVMe rápido
    safe_write "$QUEUE_PATH/nomerges" 2

    ;;
   
  mmcblk*|sd*)
    # SD/SATA: Prioridade BFQ -> MQ-Deadline
    if printf "bfq" > "$QUEUE_PATH/scheduler" 2>/dev/null; then
        bfq_path="$QUEUE_PATH/iosched"
        if [ -d "$bfq_path" ]; then
            # 'low_latency' em 1 é vital para o Deck não travar enquanto baixa jogos
            safe_write "$bfq_path/low_latency" 1
            
            # Como o barramento UHS-I é lento, reduzimos o timeout
            safe_write "$bfq_path/timeout_sync" 200
            
            # Reduz o 'strict_priority' para evitar engasgos em multitarefa
            safe_write "$bfq_path/strict_priority" 0
            
            # Aumenta o peso das leituras interativas.
            safe_write "$bfq_path/interactive" 1
        fi
    else 
        # Fallback MQ-Deadline
        printf "mq-deadline" > "$QUEUE_PATH/scheduler" 2>/dev/null || true
        current_sched=$(cat "$QUEUE_PATH/scheduler" 2>/dev/null || true)
        if [[ "$current_sched" == *"deadline"* ]]; then
            deadline_path="$QUEUE_PATH/iosched"
            if [ -d "$deadline_path" ]; then
                safe_write "$deadline_path/read_expire" 150
                safe_write "$deadline_path/write_expire" 1500
                safe_write "$deadline_path/writes_starved" 4
                safe_write "$deadline_path/fifo_batch" 1
            fi
        fi
    fi

    # Crucial para o Deck: Força o processamento do IO no core que o solicitou
    safe_write "$QUEUE_PATH/rq_affinity" 2
    ;;

esac

exit 0
EOF

    install -m 755 "$tmp" "$script_path" || { _log "erro: falha instalando $script_path"; rm -f "$tmp"; return 1; }
    rm -f "$tmp"

    # --- /etc/systemd/system/io-boost@.service ---
    tmp=$(mktemp /tmp/io-boost-unit.XXXXXX) || { _log "erro: mktemp falhou"; return 1; }
    cat > "$tmp" <<EOF
[Unit]
Description=IO Boost for %i (Turbo Decky)
After=local-fs.target

[Service]
Type=oneshot
ExecStart=${turbodecky_bin}/io-boost.sh %i
TimeoutStartSec=30
RemainAfterExit=yes
EOF
    install -m 644 "$tmp" "$unit_path" || { _log "erro: falha instalando $unit_path"; rm -f "$tmp"; return 1; }
    rm -f "$tmp"

    # --- /etc/udev/rules.d/99-io-boost.rules ---
    tmp=$(mktemp /tmp/io-boost-rule.XXXXXX) || { _log "erro: mktemp falhou"; return 1; }
    cat > "$tmp" <<'EOF'
# Disparar otimização IO Boost para dispositivos de bloco físicos
SUBSYSTEM=="block", ACTION=="add|change", KERNEL=="sd[a-z]", TAG+="systemd", ENV{SYSTEMD_WANTS}="io-boost@%k.service"
SUBSYSTEM=="block", ACTION=="add|change", KERNEL=="mmcblk[0-9]", TAG+="systemd", ENV{SYSTEMD_WANTS}="io-boost@%k.service"
SUBSYSTEM=="block", ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", TAG+="systemd", ENV{SYSTEMD_WANTS}="io-boost@%k.service"
EOF
    install -m 644 "$tmp" "$rule_path" || { _log "erro: falha instalando $rule_path"; rm -f "$tmp"; return 1; }
    rm -f "$tmp"

    # Recarrega e aplica
    systemctl daemon-reload || true
    udevadm control --reload-rules || true
    udevadm trigger --action=change --subsystem-match=block || true
    _log "io-boost: instalação concluída (Prioridade: adios)"
    return 0
}

    # === CORREÇÃO CRÍTICA: Chamada da função de instalação do IO Boost ===
    install_io_boost_uadev

    # --- 3. SCRIPT THP (Valores base + alloc_sleep fix) ---
    cat <<'THP' > "${turbodecky_bin}/thp-config.sh"
#!/usr/bin/env bash
echo "madvise" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo "defer+madvise" > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
echo "advise" > /sys/kernel/mm/transparent_hugepage/shmem_enabled 2>/dev/null || true
echo 0 > /sys/kernel/mm/transparent_hugepage/khugepaged/defrag 2>/dev/null || true

THP
    chmod +x "${turbodecky_bin}/thp-config.sh"

    
    # --- 5. SCRIPT KSM ---
    cat <<'KSM' > "${turbodecky_bin}/ksm-config.sh"
#!/usr/bin/env bash
echo 0 > /sys/kernel/mm/ksm/run 2>/dev/null || true
KSM
    chmod +x "${turbodecky_bin}/ksm-config.sh"

    # --- 6. SCRIPT KERNEL TWEAKS ---
    cat <<'KRT' > "${turbodecky_bin}/kernel-tweaks.sh"
#!/usr/bin/env bash
echo 1 > /sys/module/multi_queue/parameters/multi_queue_alloc 2>/dev/null || true
echo 1 > /sys/module/multi_queue/parameters/multi_queue_reclaim 2>/dev/null || true

KRT
    chmod +x "${turbodecky_bin}/kernel-tweaks.sh"

    # --- 7. CRIAÇÃO DOS SERVICES SYSTEMD ---
    for service_name in thp-config ksm-config kernel-tweaks; do
        cat <<UNIT > /etc/systemd/system/${service_name}.service
[Unit]
Description=TurboDecky ${service_name} persistence
After=local-fs.target
[Service]
Type=oneshot
ExecStart=${turbodecky_bin}/${service_name}.sh
RemainAfterExit=true
[Install]
WantedBy=multi-user.target
UNIT
    done
    systemctl daemon-reload || true
}

configure_read_ahead() {
    local rule="/etc/udev/rules.d/60-read-ahead.rules"
    local tmp

    tmp=$(mktemp /tmp/60-read-ahead.XXXXXX) || { _log "erro: falha criando tmpfile"; return 1; }

    cat > "$tmp" <<'EOF'
# zram
SUBSYSTEM=="block", ACTION=="add|change", KERNEL=="zram*", ATTR{queue/read_ahead_kb}="0"

# NVMe interno (disco e partições)
SUBSYSTEM=="block", ACTION=="add|change", KERNEL=="nvme*n1*", ATTR{queue/read_ahead_kb}="512"

# microSD (disco e partições)
SUBSYSTEM=="block", ACTION=="add|change", KERNEL=="mmcblk*", ATTR{queue/read_ahead_kb}="1024"
EOF

    install -m 644 "$tmp" "$rule" || { _log "erro: falha instalando $rule"; rm -f "$tmp"; return 1; }
    rm -f "$tmp"

    udevadm control --reload-rules
    udevadm trigger --action=change --subsystem-match=block

    _log "udev rule instalada: $rule"
}



otimizar_sdcard_cache() {
    _log "otimizando microsd..."
    
    # 1. Busca o ponto de montagem real do SD
    local sdcard_mount_point; sdcard_mount_point=$(findmnt -n -o TARGET "$sdcard_device" 2>/dev/null || echo "")
    
    if [[ -z "$sdcard_mount_point" ]]; then 
        _ui_info "erro" "microsd não montado ou não encontrado em $sdcard_device"
        return 1 
    fi

    # 2. Caminhos normalizados para o cache
    local sdcard_steamapps_path="${sdcard_mount_point}/steamapps"
    local sdcard_shadercache_path="${sdcard_steamapps_path}/shadercache"

    # 3. VERIFICAÇÃO ROBUSTA:
    # Verifica se já é um link e se aponta para o destino correto no NVMe
    if [ -L "$sdcard_shadercache_path" ]; then
        local link_target; link_target=$(readlink -f "$sdcard_shadercache_path")
        if [[ "$link_target" == "$nvme_shadercache_target_path" ]]; then
            _ui_info "info" "O MicroSD já está otimizado para o SSD interno."
            return 0
        else
            _log "Link simbólico detectado, mas aponta para local diferente. Recriando..."
            rm "$sdcard_shadercache_path" 2>/dev/null || true
        fi
    fi

    # 4. Verifica a existência da pasta steamapps antes de prosseguir
    if ! [ -d "$sdcard_steamapps_path" ]; then 
        _ui_info "erro" "Pasta steamapps não encontrada no MicroSD."
        return 1 
    fi

    # 5. Prepara o diretório de destino no NVMe (SSD interno)
    mkdir -p "$nvme_shadercache_target_path"
    local deck_user; deck_user=$(stat -c '%U' /home/deck 2>/dev/null || echo "deck")
    local deck_group; deck_group=$(stat -c '%G' /home/deck 2>/dev/null || echo "deck")
    chown "${deck_user}:${deck_group}" "$nvme_shadercache_target_path" 2>/dev/null || true

    # 6. Move o conteúdo existente apenas se for um diretório real (não link)
    if [ -d "$sdcard_shadercache_path" ] && [ ! -L "$sdcard_shadercache_path" ]; then
        if command -v rsync &>/dev/null; then
             rsync -a --remove-source-files "$sdcard_shadercache_path"/ "$nvme_shadercache_target_path"/ 2>/dev/null || true
             find "$sdcard_shadercache_path" -type d -empty -delete 2>/dev/null || true
        else
             mv "$sdcard_shadercache_path"/* "$nvme_shadercache_target_path"/ 2>/dev/null || true
             rmdir "$sdcard_shadercache_path" 2>/dev/null || true
        fi
    fi

    # 7. Cria o link simbólico final e valida a operação
    if ln -s "$nvme_shadercache_target_path" "$sdcard_shadercache_path"; then
        _ui_info "sucesso" "otimização do microsd concluída!"
    else
        _ui_info "erro" "falha ao criar link simbólico para o cache."
        return 1
    fi
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
    _steamos_readonly_disable_if_needed
    _log "executando reversão geral"

    # --- 1. LIMPEZA DE ARQUIVOS DE CONFIGURAÇÃO CRIADOS ---
    rm -f /etc/environment.d/turbodecky*.conf
    rm -f /etc/security/limits.d/99-game-limits.conf
    rm -f /etc/modprobe.d/99-amdgpu-tuning.conf
    rm -f /etc/tmpfiles.d/mglru.conf
    rm -f /etc/tmpfiles.d/thp_shrinker.conf
    rm -f /etc/tmpfiles.d/custom-timers.conf
    rm -f /etc/modules-load.d/ntsync.conf

    # --- REVERSÃO LAVD (ADICIONADO) ---
    systemctl stop scx_lavd.service 2>/dev/null || true
    systemctl disable scx_lavd.service 2>/dev/null || true
    rm -f /etc/systemd/system/scx_lavd.service

    # Limpeza do Power Monitor
    systemctl stop turbodecky-power-monitor.service 2>/dev/null || true
    systemctl disable turbodecky-power-monitor.service 2>/dev/null || true
    rm -f /etc/systemd/system/turbodecky-power-monitor.service
    rm -f "${turbodecky_bin}/turbodecky-power-monitor.sh"
    rm -f /usr/local/bin/turbodecky-power-monitor.sh
    rm -f /etc/udev/rules.d/99-turbodecky-power.rules
    if command -v udevadm &>/dev/null; then udevadm control --reload-rules; fi

    # --- 2. GERENCIAMENTO DE SERVIÇOS (STOP/DISABLE/REMOVE) ---
    systemctl stop "${otimization_services[@]}" zswap-config.service zram-config.service 2>/dev/null || true
    systemctl disable "${otimization_services[@]}" zswap-config.service zram-config.service 2>/dev/null || true

    for svc in "${otimization_services[@]}" zswap-config.service zram-config.service; do
        rm -f "/etc/systemd/system/$svc"
    done

    # Remove scripts nos novos e antigos caminhos
    rm -f "${turbodecky_bin}/zswap-config.sh" "${turbodecky_bin}/zram-config.sh"
    rm -f /usr/local/bin/zswap-config.sh /usr/local/bin/zram-config.sh

    for script_svc in "${otimization_services[@]}"; do
        rm -f "${turbodecky_bin}/${script_svc%%.service}.sh"
        rm -f "/usr/local/bin/${script_svc%%.service}.sh"
    done

    # Remover io-boost scripts e regras
    rm -f "${turbodecky_bin}/io-boost.sh" /usr/local/bin/io-boost.sh
    rm -f /etc/systemd/system/io-boost@.service
    rm -f /etc/udev/rules.d/99-io-boost.rules

    # Desmascara e (re)inicia o ZRAM padrão do sistema (Restaurando o ZRAM original)
    systemctl unmask systemd-zram-setup@zram0.service 2>/dev/null || true
    systemctl start systemd-zram-setup@zram0.service 2>/dev/null || true
    _log "Serviço systemd-zram-setup@zram0.service desmascarado e iniciado."
    
    # Remover override de ZRAM em /etc (Caminho persistente)
    rm -f /etc/systemd/zram-generator.conf
    # Remover override legado em /usr (se existir por versões anteriores)
    rm -f /usr/lib/systemd/zram-generator.conf
    if [ -f /usr/lib/systemd/zram-generator.conf.bak ]; then
         mv /usr/lib/systemd/zram-generator.conf.bak /usr/lib/systemd/zram-generator.conf
    fi

    # --- 4. REVERSÃO IRQBALANCE ---
    _restore_file /etc/default/irqbalance || rm -f /etc/default/irqbalance
    systemctl unmask irqbalance.service 2>/dev/null || true
    systemctl restart irqbalance.service 2>/dev/null || true 

    # --- 5. SWAP/FSTAB/SYSCTL/GRUB ---
    swapoff "$swapfile_path" 2>/dev/null || true; rm -f "$swapfile_path" || true
    _restore_file /etc/fstab || true
    swapon -a 2>/dev/null || true 

    _restore_file /etc/sysctl.d/99-sdweak-performance.conf || rm -f /etc/sysctl.d/99-sdweak-performance.conf
    _restore_file "$grub_config" || true

    if command -v update-grub &>/dev/null; then update-grub; else steamos-update-grub &>/dev/null || true; fi
    mkinitcpio -P &>/dev/null || true

    # --- 6. APLICAÇÃO FINAL ---
    sysctl --system || true 
    systemctl daemon-reload || true
    manage_unnecessary_services "enable"

    rm -rf "${turbodecky_bin}" 2>/dev/null || true
    rm -rf "${turbodecky_dir}" 2>/dev/null || true

    _log "reversão concluída."
}

_instalar_kernel_customizado() {
    local install_msg="NOVIDADE: Instalação de Kernel Customizado.\n\nAtenção!!! A compatibilidade desse kernel foi testada apenas no SteamOS 3.7.*\n\nBenefícios:\n * Freq. 1000Hz (Menor Latência)\n * NTSYNC (Melhor sincronização Wine/Proton)\n * Otimizações Zen 2\n\n⚠️ O instalador irá substituir o kernel padrão. Você deve aceitar a remoção do 'linux-neptune' quando solicitado."

    local resp_kernel="n"

    # --- INTEGRAÇÃO ZENITY ---
    if command -v zenity &>/dev/null; then
        if zenity --question --title="Kernel Customizado" --text="$install_msg\n\nDeseja instalar o Kernel Customizado agora? (Compatível apenas com 3.7.*)" --width=500; then
            resp_kernel="s"
        else
            resp_kernel="n"
        fi
    else
        echo -e "\n------------------------------------------------------------"
        echo -e "$install_msg"
        echo "------------------------------------------------------------"
        read -rp "Deseja instalar o Kernel Customizado agora? Compativel apenas com SteamOs 3.7.* (s/n): " input_val
        resp_kernel="$input_val"
    fi

    if [[ "$resp_kernel" =~ ^[Ss]$ ]]; then
        local REPO="V10lator/linux-charcoal"
        local DEST_DIR="./kernel"

        _log "Preparando diretório de download do Kernel..."
        if [ -d "$DEST_DIR" ]; then rm -rf "$DEST_DIR"; fi
        mkdir -p "$DEST_DIR"
        chown -R deck:deck "$DEST_DIR" 2>/dev/null || true

        _log "Buscando o último release de $REPO..."
        local DOWNLOAD_URLS
        DOWNLOAD_URLS=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" \
            | grep "browser_download_url" \
            | cut -d '"' -f 4 \
            | grep "\.pkg\.tar\.zst$")

        if [ -z "$DOWNLOAD_URLS" ]; then
            _ui_info "erro" "Nenhum pacote de kernel (.pkg.tar.zst) encontrado no repositório."
            return 1
        fi

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

        _log "Iniciando instalação do kernel customizado..."
        _steamos_readonly_disable_if_needed
        steamos-devmode enable --no-prompt
        echo "Instalando Kernel (linux-charcoal)..." 
             pacman -R --noconfirm linux-neptune-611 || true
             pacman -R --noconfirm linux-neptune-611-headers || true
        if pacman -U --noconfirm "$DEST_DIR"/*.pkg.tar.zst; then
             
             _log "Kernel customizado instalado com sucesso."
             update-grub &>/dev/null || true
             mkinitcpio -P &>/dev/null || true
        else
             _ui_info "erro" "Falha na instalação do Kernel customizado, reinstalando kernel padrão."
        if pacman -S --noconfirm linux-neptune-611; then
        _log "linux-neptune-611 instalado com sucesso."
        if command -v update-grub &>/dev/null; then update-grub; else steamos-update-grub &>/dev/null || true; fi
        mkinitcpio -P &>/dev/null || true
        _ui_info "sucesso" "Kernel padrão (linux-neptune-611) reinstalado. Reinicie o sistema para completar."
             
        fi
    fi

    fi
}
optimize_zram() {
    # ZRAM SteamOS-safe 
   
    local gen_dir="/etc/systemd/zram-generator.conf.d"
    local gen_conf="${gen_dir}/00-turbodecky.conf"
    
    [ "$(id -u)" -eq 0 ] || return 1
    _steamos_readonly_disable_if_needed

    # -------------------------------------------------
    # 1) zram-generator (único criador da zram)
    # -------------------------------------------------
    mkdir -p "$gen_dir"
    rm -f "$gen_conf"
rm -f /etc/systemd/system/zram-recompress.timer 
rm -f /etc/systemd/system/zram-recompress.service
    cat <<'EOF' > "$gen_conf"
[zram0]
zram-size = min(ram, 8192)
compression-algorithm = lz4 zstd(level=3) (type=idle) 
swap-priority = 1000
fs-type = swap
EOF

    systemctl daemon-reexec
    systemctl daemon-reload

   

    return 0
}

aplicar_zswap() {
    _log "Aplicando ZSWAP (Híbrido AC/Battery)"

    _steamos_readonly_disable_if_needed
    _setup_dxvk_folder
    configure_read_ahead
    _executar_reversao
    _configure_ulimits
    create_common_scripts_and_services
    create_power_rules 
    _configure_irqbalance
    
    _setup_lavd_scheduler

    systemctl stop systemd-zram-setup@zram0.service 2>/dev/null || true
    systemctl mask systemd-zram-setup@zram0.service 2>/dev/null || true
    _log "Serviço systemd-zram-setup@zram0.service mascarado."

    _apply_fstab_tweak_if_ext4

    local free_space_gb; free_space_gb=$(df -BG /home | awk 'NR==2 {print $4}' | tr -d 'G' || echo 0)
    if (( free_space_gb < zswap_swapfile_size_gb )); then _ui_info "erro" "espaço insuficiente"; exit 1; fi

    _create_swapfile "$swapfile_path" "$zswap_swapfile_size_gb"

    sed -i "\|${swapfile_path}|d" /etc/fstab 2>/dev/null || true; echo "$swapfile_path none swap sw,pri=-2 0 0" >> /etc/fstab
    swapon --priority -2 "$swapfile_path" || true

    _write_sysctl_file /etc/sysctl.d/99-sdweak-performance.conf "${base_sysctl_params[@]}"
    sysctl --system || true

    _backup_file_once "$grub_config"
    
    local kernel_params=("zswap.enabled=1" "zswap.compressor=lz4" "zswap.max_pool_percent=35" "zswap.zpool=zsmalloc" "zswap.shrinker_enabled=0" "mitigations=off"  "audit=0" "nmi_watchdog=0" "nowatchdog" "split_lock_detect=off")
    
    local current_cmdline; current_cmdline=$(grep -E '^GRUB_CMDLINE_LINUX=' "$grub_config" | sed -E 's/^GRUB_CMDLINE_LINUX="([^"]*)"(.*)/\1/' || true)
    local new_cmdline="$current_cmdline"
    for param in "${kernel_params[@]}"; do local key="${param%%=*}"; new_cmdline=$(echo "$new_cmdline" | sed -E "s/ ?${key}(=[^ ]*)?//g"); done
    for param in "${kernel_params[@]}"; do new_cmdline="$new_cmdline $param"; done
    new_cmdline=$(echo "$new_cmdline" | tr -s ' ' | sed -E 's/^ //; s/ $//')
    sed -i -E "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$new_cmdline\"|" "$grub_config" || true

    steamos-update-grub &>/dev/null || update-grub &>/dev/null || true
    mkinitcpio -P &>/dev/null || true

    create_persistent_configs

    cat <<'ZSWAP_SCRIPT' > "${turbodecky_bin}/zswap-config.sh"
#!/usr/bin/env bash
echo 1 > /sys/module/zswap/parameters/enabled 2>/dev/null || true
echo lz4 > /sys/module/zswap/parameters/compressor 2>/dev/null || true
echo 35 > /sys/module/zswap/parameters/max_pool_percent 2>/dev/null || true
echo zsmalloc > /sys/module/zswap/parameters/zpool 2>/dev/null || true
echo 0 > /sys/module/zswap/parameters/shrinker_enabled 2>/dev/null || true
echo 0 > /sys/kernel/mm/page_idle/enable 2>/dev/null || true
sysctl -w vm.page-cluster=1 || true
sysctl -w vm.swappiness=133 || true
sysctl -w vm.watermark_scale_factor=125 || true
sysctl -w vm.vfs_cache_pressure=66 || true
ZSWAP_SCRIPT
    chmod +x "${turbodecky_bin}/zswap-config.sh"

    cat <<UNIT > /etc/systemd/system/zswap-config.service
[Unit]
Description=Configuracao ZSWAP Persistent
After=local-fs.target
[Service]
Type=oneshot
ExecStart=${turbodecky_bin}/zswap-config.sh
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

    _instalar_kernel_customizado

    
    _ui_info "aviso" "Reinicie para efeito total (Kernel, GRUB e EnvVars)."
}

aplicar_zram() {
    _log "Aplicando otimizações (ZRAM)"

    _steamos_readonly_disable_if_needed
    _setup_dxvk_folder
    configure_read_ahead
    _executar_reversao
    _configure_ulimits
    create_common_scripts_and_services
    create_power_rules 
    _configure_irqbalance
   
    _setup_lavd_scheduler

    _apply_fstab_tweak_if_ext4

    _write_sysctl_file /etc/sysctl.d/99-sdweak-performance.conf "${base_sysctl_params[@]}"
    sysctl --system || true

    _backup_file_once "$grub_config"
    
    local kernel_params=("zswap.enabled=0" "mitigations=off" "audit=0" "nmi_watchdog=0" "nowatchdog" "split_lock_detect=off")
    
    local current_cmdline; current_cmdline=$(grep -E '^GRUB_CMDLINE_LINUX=' "$grub_config" | sed -E 's/^GRUB_CMDLINE_LINUX="([^"]*)"(.*)/\1/' || true)
    local new_cmdline="$current_cmdline"
    for param in "${kernel_params[@]}"; do local key="${param%%=*}"; new_cmdline=$(echo "$new_cmdline" | sed -E "s/ ?${key}(=[^ ]*)?//g" | sed -E "s/ ?zswap\.[^ =]+(=[^ ]*)?//g"); done
    for param in "${kernel_params[@]}"; do new_cmdline="$new_cmdline $param"; done
    new_cmdline=$(echo "$new_cmdline" | tr -s ' ' | sed -E 's/^ //; s/ $//')
    sed -i -E "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$new_cmdline\"|" "$grub_config" || true
    steamos-update-grub &>/dev/null || update-grub &>/dev/null || true
    mkinitcpio -P &>/dev/null || true

    create_persistent_configs

    cat <<'ZRAM_SCRIPT' > "${turbodecky_bin}/zram-config.sh"
#!/usr/bin/env bash

echo 0 > /sys/kernel/mm/page_idle/enable 2>/dev/null || true
sysctl -w vm.swappiness=150 || true
sysctl -w vm.watermark_scale_factor=125 || true
sysctl -w vm.vfs_cache_pressure=66  || true
sysctl -w vm.page-cluster=0 || true
echo "=== ZRAM STATUS ===" >> /var/log/turbodecky.log
zramctl >> /var/log/turbodecky.log
ZRAM_SCRIPT

    chmod +x "${turbodecky_bin}/zram-config.sh"
    cat <<UNIT > /etc/systemd/system/zram-config.service
[Unit]
Description=ZRAM Setup Persistent
After=local-fs.target
[Service]
Type=oneshot
ExecStart=${turbodecky_bin}/zram-config.sh
RemainAfterExit=true
[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload || true
    systemctl enable --now "${otimization_services[@]}" zram-config.service || true
    if command -v udevadm &>/dev/null; then udevadm trigger --action=change --subsystem-match=power_supply; fi
    _ui_info "sucesso" "otimizações aplicadas."

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

    _instalar_kernel_customizado
    # CORREÇÃO DE LÓGICA: optimize_zram deve ser chamado para configurar o dispositivo ZRAM
    optimize_zram
  
    _ui_info "aviso" "Reinicie o sistema para efeito total."
}

reverter_alteracoes() {
    _executar_reversao
    _ui_info "sucesso" "Reversão completa. Reinicie."
}

_restore_kernel_to_neptune() {
    steamos-devmode enable --no-prompt
    _log "Iniciando restauração do kernel padrão (linux-neptune)"

    if ! command -v pacman &>/dev/null; then
        _ui_info "erro" "pacman não encontrado no sistema. Não é possível reinstalar o kernel."
        return 1
    fi

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

    _log "Instalando linux-neptune-611..."
    if pacman -S --noconfirm linux-neptune-611; then
        _log "linux-neptune-611 instalado com sucesso."
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
            --height 350 --width 500 --hide-column=2 --print-column=2 || echo "6")

        if [ -z "$z_escolha" ]; then z_escolha="6"; fi
        escolha="$z_escolha"
    else
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
