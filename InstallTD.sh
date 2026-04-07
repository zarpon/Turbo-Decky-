#!/usr/bin/env bash
set -euo pipefail

# --- versão e autor do script ---

versao="3.2.3 - 07-04 R6 - Timeless Child"
autor="Jorge Luis"
pix_doacao="jorgezarpon@msn.com"

# --- constantes e variáveis ---
readonly swapfile_path="/home/swapfile"
readonly grub_config="/etc/default/grub"
# Calcula 40% da RAM total de forma dinâmica
readonly zswap_swapfile_size_gb=$(awk '/MemTotal/ {printf "%.0f", ($2 / 1024 / 1024) * 0.40}' /proc/meminfo)


readonly zram_swapfile_size_gb="2"
readonly backup_suffix="bak-turbodecky"
readonly logfile="/var/log/turbodecky.log"

# --- Diretórios persistentes (resistem a atualizações do SteamOS) ---
readonly turbodecky_dir="/var/lib/turbodecky"
readonly turbodecky_bin="${turbodecky_dir}/bin"

# Caminho do cache DXVK
readonly dxvk_cache_path="/home/deck/dxvkcache"

# --- parâmetros sysctl base (ATUALIZADO PARA LATÊNCIA E SCHEDULER) ---
readonly base_sysctl_params=(
    "vm.min_free_kbytes=131072" 
    "vm.compaction_proactiveness=10"
    "vm.dirty_ratio=6" 
    "vm.dirty_background_ratio=2" 
    "vm.dirty_expire_centisecs=1500"       
    "vm.dirty_writeback_centisecs=1500"      
    "kernel.numa_balancing=0"
    "vm.zone_reclaim_mode=0"
    "vm.vfs_cache_pressure=50"
    # --- Scheduler (scx_lavd friendly) ---
    "kernel.split_lock_mitigate=0"
    # --- WATCHDOG E NETWORK ---
    "kernel.nmi_watchdog=0"
    "kernel.soft_watchdog=0"
    "kernel.watchdog=0"
    "kernel.core_pattern=/dev/null"
    "kernel.core_pipe_limit=0"
    "kernel.printk_devkmsg=off"
    "net.core.default_qdisc=fq_codel"
    "net.ipv4.tcp_congestion_control=bbr"
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
    "MESA_SHADER_CACHE_MAX_SIZE=10G"
    "PROTON_USE_NTSYNC=1"
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
            sed -E -i 's|(^[^[:space:]]+[[:space:]]+/home[[:space:]]+[^[:space:]]+[[:space:]]+ext4[[:space:]]+)[^[:space:]]+|\1defaults,nofail,noatime,data=writeback,commit=60,x-systemd.growfs|g' "$fstab_file" || true
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
* soft nofile 524288
* hard nofile 524288
root soft nofile 524288
root hard nofile 524288
* hard memlock 2147484
* soft memlock 2147484

EOF
    _log "/etc/security/limits.d/99-game-limits.conf criado/atualizado."
}



_setup_lavd_scheduler() {
    _log "Iniciando instalação estável: LAVD Scheduler (via SteamOS Neptune Repo)"

    _steamos_readonly_disable_if_needed
    # NOVO: Garante que o DevMode está ativo para permitir alterações no pacman
    sudo systemctl disable --now irqbalance 2>/dev/null || true
    sudo systemctl mask irqbalance 2>/dev/null || true

    steamos-devmode enable --no-prompt 2>/dev/null || true

    # 1. Tratamento do pacman lock
    if [[ -f /var/lib/pacman/db.lck ]]; then
        if ! fuser /var/lib/pacman/db.lck >/dev/null 2>&1; then
            _log "Removendo pacman lock órfão..."
            sudo rm -f /var/lib/pacman/db.lck
        else
            _ui_info "erro" "O gerenciador de pacotes está em uso. Tente novamente mais tarde."
            return 1
        fi
    fi

    # 2. Limpeza de versões anteriores (CachyOS ou locais) para evitar conflitos
    _log "Removendo versões customizadas anteriores do scx..."
    sudo systemctl disable --now scx_lavd.service scx.service 2>/dev/null || true
    # Remove pacotes que podem ter vindo do CachyOS para garantir que o pacman use o repo oficial
    sudo pacman -Rns --noconfirm scx-scheds scx-tools 2>/dev/null || true

    # NOVO: Inicialização obrigatória do chaveiro do pacman no SteamOS
    _log "Inicializando chaves do pacman..."
    sudo pacman-key --init 2>/dev/null || true
    sudo pacman-key --populate archlinux holo 2>/dev/null || true

    # 3. Sincronização e Instalação do repositório oficial do SteamOS (Neptune)
    _log "Instalando scx-scheds oficial do repositório SteamOS..."
    if ! sudo pacman -S --noconfirm scx-scheds; then
        _log "Erro crítico: Não foi possível instalar o scx-scheds do repositório oficial."
        return 1
    fi

    # 4. Configuração de Privilégios (Fundamental para o eBPF)
    # No SteamOS oficial, o binário costuma estar em /usr/bin/scx_lavd
    if [[ -f /usr/bin/scx_lavd ]]; then
        _log "Aplicando permissões de execução (capabilities)..."
        sudo setcap 'cap_sys_admin,cap_sys_ptrace,cap_net_admin,cap_dac_override,cap_sys_resource+eip' /usr/bin/scx_lavd
    else
        _log "Erro: Binário /usr/bin/scx_lavd não encontrado após instalação oficial."
        return 1
    fi

    # 5. Criação do Serviço Systemd customizado para o Turbo Decky
    _log "Configurando serviço scx_lavd..."
    sudo bash -c 'cat <<UNIT > /etc/systemd/system/scx_lavd.service
[Unit]
Description=Turbo Decky - LAVD Scheduler (Official Stable)
After=multi-user.target
Conflicts=scx.service

[Service]
Type=simple
# Usamos --performance para garantir o foco em jogos no Steam Deck
ExecStart=/usr/bin/scx_lavd --performance
Restart=always
RestartSec=5


[Install]
WantedBy=multi-user.target
UNIT'

    sudo systemctl daemon-reload
    sudo systemctl enable --now scx_lavd.service

    # 6. Verificação final
    if systemctl is-active --quiet scx_lavd.service; then
        _log "LAVD Scheduler (Versão Estável) ativado com sucesso."
    else
        _log "Aviso: O serviço foi instalado, mas falhou ao iniciar. Verifique 'journalctl -u scx_lavd'."
    fi
}

manage_unnecessary_services() {
    local action="$1"

    if [[ "$action" == "disable" ]]; then
        systemctl stop "${unnecessary_services[@]}" 2>/dev/null || true
        systemctl mask "${unnecessary_services[@]}" 2>/dev/null || true
    elif [[ "$action" == "enable" ]]; then
        systemctl unmask "${unnecessary_services[@]}" 2>/dev/null || true
        systemctl start "${unnecessary_services[@]}" 2>/dev/null || true
    fi
}

create_persistent_configs() {
    _log "criando arquivos de configuração persistentes"
    mkdir -p /etc/tmpfiles.d /etc/modprobe.d /etc/modules-load.d


    cat << EOF > /etc/tmpfiles.d/mglru.conf
w /sys/kernel/mm/lru_gen/enabled - - - - 7
w /sys/kernel/mm/lru_gen/min_ttl_ms - - - - 100
EOF

    echo "ntsync" > /etc/modules-load.d/ntsync.conf
    _log "configuração ntsync criada em /etc/modules-load.d/ntsync.conf"

    manage_unnecessary_services "disable"

    systemctl daemon-reload || true
    _log "configurações mglru, ntsync e serviços desnecessários aplicados."
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
    
    # --- 3. SCRIPT THP (Valores base + alloc_sleep fix) ---
    cat <<'THP' > "${turbodecky_bin}/thp-config.sh"
#!/usr/bin/env bash
echo "always" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo "defer+madvise" > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
echo "advise" > /sys/kernel/mm/transparent_hugepage/shmem_enabled 2>/dev/null || true
echo 1 > /sys/kernel/mm/transparent_hugepage/khugepaged/defrag 2>/dev/null || true
echo 2048 > /sys/kernel/mm/transparent_hugepage/khugepaged/pages_to_scan 2>/dev/null || true
echo 5000 > /sys/kernel/mm/transparent_hugepage/khugepaged/scan_sleep_millisecs 2>/dev/null || true
echo 50000 > /sys/kernel/mm/transparent_hugepage/khugepaged/alloc_sleep_millisecs 2>/dev/null || true
echo 409 > /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_none 2>/dev/null || true
echo 0 > /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_swap 2>/dev/null || true
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
systemctl enable --now thp-config.service ksm-config.service kernel-tweaks.service || true 

}

install_io_boost_uadev() {
    _log "💾 Configurando I/O Nativo e Read-Ahead (BFQ Otimizado)..."
    
    # Criar regra UDEV unificada
    cat << 'EOF' > /etc/udev/rules.d/99-turbodecky-io.rules
# 1. ZRAM: Latência zero e sem read-ahead
ACTION=="add|change", KERNEL=="zram*", ATTR{queue/read_ahead_kb}="0", ATTR{queue/scheduler}="none"

# 2. NVMe Interno: Passthrough total e Read-Ahead equilibrado
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", \
  ATTR{queue/scheduler}="none", \
  ATTR{queue/nr_requests}="256", \
  ATTR{queue/read_ahead_kb}="512", \
  ATTR{queue/nomerges}="2"

# 3. MicroSD/SD Cards: Otimização para BFQ (Budget Fair Queuing)
# Parte A: Define o escalonador BFQ e aumenta a profundidade da fila para o scheduler trabalhar
ACTION=="add|change", KERNEL=="mmcblk[0-9]*", \
  ATTR{queue/scheduler}="bfq", \
  ATTR{queue/nr_requests}="128", \
  ATTR{queue/read_ahead_kb}="2048"

# Parte B: Ajustes finos do BFQ para priorizar carregamento de jogos e interatividade
ACTION=="add|change", KERNEL=="mmcblk[0-9]*", ATTR{queue/scheduler}=="bfq", \
  ATTR{iosched/low_latency}="1", \
  ATTR{iosched/slice_idle}="1", \
  ATTR{iosched/strict_guarantees}="0", \
  ATTR{iosched/timeout_sync}="300", \
  ATTR{iosched/back_seek_max}="16384"

# 4. Otimizações Gerais de Overhead (NVMe, SD e Discos USB)
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/iostats}="0", ATTR{queue/add_random}="0", ATTR{queue/rq_affinity}="2"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/iostats}="0", ATTR{queue/add_random}="0", ATTR{queue/rq_affinity}="2"
ACTION=="add|change", KERNEL=="mmcblk[0-9]*", ATTR{queue/iostats}="0", ATTR{queue/add_random}="0", ATTR{queue/rq_affinity}="2"
EOF

    # Remove o arquivo de regra antigo se ele existir
    rm -f /etc/udev/rules.d/60-read-ahead.rules 2>/dev/null || true

    # Aplicar as regras imediatamente
    udevadm control --reload-rules && udevadm trigger
    _log "✅ I/O unificado com BFQ aplicado ao MicroSD com sucesso."
}




_executar_reversao() {
    _steamos_readonly_disable_if_needed
    _log "executando reversão geral"
    sudo systemctl unmask irqbalance 2>/dev/null || true
    sudo systemctl enable --now irqbalance 2>/dev/null || true
    
    # --- 1. LIMPEZA DE ARQUIVOS DE CONFIGURAÇÃO CRIADOS ---
    rm -f /etc/environment.d/turbodecky*.conf
    rm -f /etc/security/limits.d/99-game-limits.conf
    rm -f /etc/modprobe.d/amdgpu.conf
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
    rm -f /etc/systemd/zram-generator.conf.d/00-turbodecky.conf
    rm -f /etc/systemd/zram-generator.conf
    # Remover override legado em /usr (se existir por versões anteriores)
    rm -f /usr/lib/systemd/zram-generator.conf
    if [ -f /usr/lib/systemd/zram-generator.conf.bak ]; then
         mv /usr/lib/systemd/zram-generator.conf.bak /usr/lib/systemd/zram-generator.conf
    fi

    

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

    # --- LIMPEZA ZRAM RECOMPRESS (TurboDecky) ---
systemctl disable --now zram-recompress.timer 2>/dev/null || true
rm -f /etc/systemd/system/zram-recompress.timer
rm -f /etc/systemd/system/zram-recompress.service
_log "zram-recompress timer/service removidos na reversão"

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
    local gen_dir="/etc/systemd/zram-generator.conf.d"
    local gen_conf="${gen_dir}/00-turbodecky.conf"
    local timer_file="/etc/systemd/system/zram-recompress.timer"
    local service_file="/etc/systemd/system/zram-recompress.service"
    
    [ "$(id -u)" -eq 0 ] || return 1
    _steamos_readonly_disable_if_needed

    # 1) Configuração do Gerador (LZ4 primário para escrita rápida)
    mkdir -p "$gen_dir"
    cat > "$gen_conf" <<EOF
[zram0]
zram-size = min(ram, 8192)
compression-algorithm = lz4
swap-priority = 1000
fs-type = swap
EOF

    # 2) Timer (Frequência de  3 minutos)
    cat <<'EOF' > "$timer_file"
[Unit]
Description=Timer para Recompressão de Páginas ZRAM (TurboDecky)

[Timer]
OnBootSec=3min
OnUnitActiveSec=3min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # 3) Service - ExecStart Totalmente Linearizado (Compatibilidade Máxima)
    cat <<'EOF' > "$service_file"
[Unit]
Description=Serviço de Recompressão ZRAM (Compat Mode)
After=dev-zram0.swap

[Service]
Type=oneshot
ExecStart=/usr/bin/bash -c 'Z=/sys/block/zram0; if [ -e "$Z/recomp_algorithm" ]; then echo zstd > "$Z/recomp_algorithm" 2>/dev/null || echo "algo=zstd" > "$Z/recomp_algorithm" 2>/dev/null || echo "algo=zstd priority=1" > "$Z/recomp_algorithm" 2>/dev/null; fi; echo 30 > "$Z/idle" 2>/dev/null; if [ -e "$Z/recompress" ]; then echo idle > "$Z/recompress" 2>/dev/null || echo "type=idle" > "$Z/recompress" 2>/dev/null || echo "type=idle max_pages=15000" > "$Z/recompress" 2>/dev/null; echo huge > "$Z/recompress" 2>/dev/null || echo "type=huge" > "$Z/recompress" 2>/dev/null || echo "type=huge max_pages=10000" > "$Z/recompress" 2>/dev/null; echo huge_idle > "$Z/recompress" 2>/dev/null || echo "type=huge_idle" > "$Z/recompress" 2>/dev/null || echo "type=huge_idle max_pages=8000" > "$Z/recompress" 2>/dev/null; fi'
RemainAfterExit=no
EOF

    # 4) Reset e Aplicação
    if [ -b /dev/zram0 ]; then
        swapoff /dev/zram0 2>/dev/null || true
        zramctl --reset /dev/zram0 2>/dev/null || true
    fi

    systemctl daemon-reload
    sleep 1

    systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || true
    systemctl enable --now zram-recompress.timer
    systemctl start zram-recompress.service
}


aplicar_zswap() {
    _log "Aplicando otimizações"

    _steamos_readonly_disable_if_needed
    
    _executar_reversao
    _configure_ulimits
    create_common_scripts_and_services
    install_io_boost_uadev
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
    
    local kernel_params=("zswap.enabled=1" "zswap.compressor=lz4" "zswap.max_pool_percent=30" "zswap.zpool=zsmalloc" "zswap.shrinker_enabled=0" "mitigations=off" "audit=0" "nmi_watchdog=0" "nowatchdog" "split_lock_detect=off")

    local current_cmdline; current_cmdline=$(grep -E '^GRUB_CMDLINE_LINUX=' "$grub_config" | sed -E 's/^GRUB_CMDLINE_LINUX="([^"]*)"(.*)/\1/' || true)
    local new_cmdline="$current_cmdline"
    for param in "${kernel_params[@]}"; do local key="${param%%=*}"; new_cmdline=$(echo "$new_cmdline" | sed -E "s/ ?${key}(=[^ ]*)?//g"); done
    for param in "${kernel_params[@]}"; do new_cmdline="$new_cmdline $param"; done
    new_cmdline=$(echo "$new_cmdline" | tr -s ' ' | sed -E 's/^ //; s/ $//')
    sed -i -E "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$new_cmdline\"|" "$grub_config" || true

create_persistent_configs

    steamos-update-grub &>/dev/null || update-grub &>/dev/null || true
    mkinitcpio -P &>/dev/null || true

    

    cat <<'ZSWAP_SCRIPT' > "${turbodecky_bin}/zswap-config.sh"
#!/usr/bin/env bash
echo 1 > /sys/module/zswap/parameters/enabled 2>/dev/null || true
echo lz4 > /sys/module/zswap/parameters/compressor 2>/dev/null || true
echo 30 > /sys/module/zswap/parameters/max_pool_percent 2>/dev/null || true
echo zsmalloc > /sys/module/zswap/parameters/zpool 2>/dev/null || true
echo 0 > /sys/module/zswap/parameters/shrinker_enabled 2>/dev/null || true
sysctl -w vm.page-cluster=0 || true
sysctl -w vm.swappiness=150 || true
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
   

    systemctl enable --now fstrim.timer
    _instalar_kernel_customizado

    _ui_info "sucesso" "Otimizações aplicadas."
    
    _ui_info "aviso" "Reinicie para efeito total (Kernel, GRUB e EnvVars)."
}

aplicar_zram() {
    _log "Aplicando otimizações (ZRAM)"

    _steamos_readonly_disable_if_needed

    _executar_reversao
    _configure_ulimits
    create_common_scripts_and_services
   install_io_boost_uadev
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

create_persistent_configs

    steamos-update-grub &>/dev/null || update-grub &>/dev/null || true
    mkinitcpio -P &>/dev/null || true

    

    cat <<'ZRAM_SCRIPT' > "${turbodecky_bin}/zram-config.sh"
#!/usr/bin/env bash


sysctl -w vm.swappiness=180 || true
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
   
    _ui_info "sucesso" "otimizações aplicadas."

    
   
    # CORREÇÃO DE LÓGICA: optimize_zram deve ser chamado para configurar o dispositivo ZRAM
    optimize_zram
    systemctl enable --now fstrim.timer
   _instalar_kernel_customizado
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
            FALSE "5" "Restaurar Kernel Padrão (Remover linux-charcoal)" \
            FALSE "6" "Sair" \
            --height 350 --width 500 --hide-column=2 --print-column=2 || echo "6")

        if [ -z "$z_escolha" ]; then z_escolha="6"; fi
        escolha="$z_escolha"
    else
        echo "1) Aplicar Otimizações Recomendadas (ZSWAP + Tuning)"
        echo "2) Aplicar Otimizações (ZRAM + Tuning - Alternativa para pouco espaço)"
        echo "3) Reverter Tudo"
        echo "5) Reinstalar kernel padrão (remover kernel customizado)"
        echo "6) Sair"
        read -rp "Opção: " escolha
    fi

    case "$escolha" in
        1) aplicar_zswap ;;
        2) aplicar_zram ;;
        3) reverter_alteracoes ;;
        5) _restore_kernel_to_neptune ;;
        6) exit 0 ;;
        *)
           _ui_info "erro" "Opção Inválida"
           if command -v zenity &>/dev/null; then exit 1; else main "$@"; fi
           ;;
    esac
}

main "$@"
