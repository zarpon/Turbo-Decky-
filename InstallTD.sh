#!/usr/bin/env bash
set -euo pipefail

# --- versão e autor do script ---

versao="3.6 - 28-05 R1 - Timeless Child"
autor="Jorge Luis"
pix_doacao="jorgezarpon@msn.com"

# --- constantes e variáveis ---
readonly swapfile_path="/home/swapfile"
readonly grub_config="/etc/default/grub"
# Define o tamanho do swapfile fixo em 8GB
readonly zswap_swapfile_size_gb="8"
readonly backup_suffix="bak-turbodecky"
readonly logfile="/var/log/turbodecky.log"

# --- Diretórios persistentes (resistem a atualizações do SteamOS) ---
readonly turbodecky_dir="/var/lib/turbodecky"
readonly turbodecky_bin="${turbodecky_dir}/bin"



# --- parâmetros sysctl base (ATUALIZADO PARA LATÊNCIA E SCHEDULER) ---
readonly base_sysctl_params=(
    "vm.min_free_kbytes=65536" 
    "vm.compaction_proactiveness=15"
    "vm.dirty_expire_centisecs=1500"       
    "vm.dirty_writeback_centisecs=1000"      
    "vm.watermark_boost_factor=0"
    "vm.watermark_scale_factor=125"
    # --- Scheduler (scx_lavd friendly) ---
    "kernel.split_lock_mitigate=0"
      # --- Novos Parâmetros ---
    "vm.dirty_background_bytes=209715200"
    "vm.dirty_bytes=409430400"
    "vm.vfs_cache_pressure=125"
    "vm.kcompressd=256"
)



readonly unnecessary_services=(
    "gpu-trace.service"
    "steamos-log-submitter.service"
    "cups.service"
    
)

# --- variáveis de ambiente (Configuração de Jogos) ---
# Nota: DXVK_STATE_CACHE_PATH usa a variável definida acima
readonly game_env_vars=(
    "MESA_SHADER_CACHE_MAX_SIZE=10G"
     "MESA_DISK_CACHE_DATABASE=1"    
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

# --- seleção de idioma / language selection ---
select_language() {
    local lang_choice
    if command -v zenity &>/dev/null; then
        lang_choice=$(zenity --list --title="Language / Idioma" \
            --text="Select your language / Selecione seu idioma:" \
            --radiolist \
            --column="Select" --column="Code" --column="Language" \
            TRUE "pt" "Português" \
            FALSE "en" "English" \
            --height 250 --width 400 --hide-column=2 --print-column=2 2>/dev/null || echo "pt")
        if [ -z "$lang_choice" ]; then lang_choice="pt"; fi
    else
        echo "Select your language / Selecione seu idioma:"
        echo "1) Português"
        echo "2) English"
        read -rp "Option/Opção (1/2): " lang_opt
        if [[ "$lang_opt" == "2" ]]; then lang_choice="en"; else lang_choice="pt"; fi
    fi

    if [[ "$lang_choice" == "en" ]]; then
        STR_ERR_ROOT="This script must be run as root (sudo)."
        STR_ERR_ROOT_CLI="❌ error: this script must be run as root (sudo)."
        STR_ERR_PACMAN_LOCK="The package manager is in use. Try again later."
        STR_ERR_NO_SPACE="Insufficient space"
        STR_SUCCESS_OPT="Optimizations applied."
        STR_WARN_REBOOT="Reboot for full effect (Kernel, GRUB and EnvVars)."
        STR_WARN_REBOOT_SHORT="Reboot the system for full effect."
        STR_SUCCESS_REVERT="Reversion complete. Please reboot."
        STR_ERR_NO_PACMAN="pacman not found on the system. Cannot reinstall the kernel."
        STR_ERR_RM_KERNEL="Failed to remove linux-charcoal"
        STR_INFO_NO_KERNEL="Custom kernel not found installed."
        STR_SUCCESS_RESTORE_KERNEL="Default kernel (linux-neptune) reinstalled. Reboot the system to complete."
        STR_ERR_INSTALL_KERNEL="Failed to install linux-neptune"
        
        STR_KERNEL_TITLE="Custom Kernel"
        STR_KERNEL_MSG="NEW: Custom Kernel Installation.\n\nAttention!!! Compatibility tested only on SteamOS 3.8.*\n\nBenefits:\n * 1000Hz Freq (Lower Latency)\n * NTSYNC (Better Wine/Proton sync)\n * Zen 2 Optimizations\n\n⚠️ The installer will replace the default kernel. You must accept the removal of 'linux-neptune' when asked."
        STR_KERNEL_Q_ZENITY="Do you want to install the Custom Kernel now? (Only compatible with 3.8.*). Follow the instructions carefully and accept the default Kernel removal when prompted."
        STR_KERNEL_Q_CLI="Do you want to install the Custom Kernel now? Compatible only with SteamOS 3.8.* (y/n): "
        STR_KERNEL_ERR_NO_PKG="No kernel package (.pkg.tar.zst) found in the repository."
        STR_KERNEL_ERR_DL="Failed to download"
        STR_KERNEL_DOWNLOADING="Downloading"
        STR_KERNEL_INSTALLING="Installing Kernel (linux-charcoal)..."
        STR_KERNEL_ERR_FAIL_REINSTALL="Custom Kernel installation failed, reinstalling default kernel."

        STR_MAIN_WELCOME="Welcome to Turbo Decky! Optimize your Steam Deck for the best gaming performance!\nAll optimizations are safe and can be reverted."
        STR_MAIN_CHOOSE="Choose the desired option:"
        STR_OPT_1="Apply Recommended Optimizations (ZSWAP + Tuning)"
        STR_OPT_2="Apply Optimizations (ZRAM + Tuning - Low space)"
        STR_OPT_2_CLI="Apply Optimizations (ZRAM + Tuning - Low space alternative)"
        STR_OPT_3="Revert Everything"
        STR_OPT_5="Restore Default Kernel (Remove linux-charcoal)"
        STR_OPT_5_CLI="Reinstall default kernel (remove custom kernel)"
        STR_OPT_6="Exit"
        STR_OPT_INVALID="Invalid Option"
        STR_CLI_OPT="Option: "
        
        STR_COL_ACTIVE="Active"
        STR_COL_OPT="Option"
        STR_COL_DESC="Description"
        REGEX_YES="^[YySs]$"
    else
        STR_ERR_ROOT="Este script deve ser executado como root (sudo)."
        STR_ERR_ROOT_CLI="❌ erro: este script deve ser executado como root (sudo)."
        STR_ERR_PACMAN_LOCK="O gerenciador de pacotes está em uso. Tente novamente mais tarde."
        STR_ERR_NO_SPACE="espaço insuficiente"
        STR_SUCCESS_OPT="Otimizações aplicadas."
        STR_WARN_REBOOT="Reinicie para efeito total (Kernel, GRUB e EnvVars)."
        STR_WARN_REBOOT_SHORT="Reinicie o sistema para efeito total."
        STR_SUCCESS_REVERT="Reversão completa. Reinicie."
        STR_ERR_NO_PACMAN="pacman não encontrado no sistema. Não é possível reinstalar o kernel."
        STR_ERR_RM_KERNEL="Falha ao remover linux-charcoal"
        STR_INFO_NO_KERNEL="Kernel customizado não encontrado instalado."
        STR_SUCCESS_RESTORE_KERNEL="Kernel padrão (linux-neptune) reinstalado. Reinicie o sistema para completar."
        STR_ERR_INSTALL_KERNEL="Falha ao instalar linux-neptune"
        
        STR_KERNEL_TITLE="Kernel Customizado"
        STR_KERNEL_MSG="NOVIDADE: Instalação de Kernel Customizado.\n\nAtenção!!! A compatibilidade desse kernel foi testada apenas no SteamOS 3.8.*\n\nBenefícios:\n * Freq. 1000Hz (Menor Latência)\n * NTSYNC (Melhor sincronização Wine/Proton)\n * Otimizações Zen 2\n\n⚠️ O instalador irá substituir o kernel padrão. Você deve aceitar a remoção do 'linux-neptune' quando solicitado."
        STR_KERNEL_Q_ZENITY="Deseja instalar o Kernel Customizado agora? (Compatível apenas com 3.8.*). Siga atentamente as instruções e aceite a remoção do Kernel padrão quando for perguntado"
        STR_KERNEL_Q_CLI="Deseja instalar o Kernel Customizado agora? Compativel apenas com SteamOs 3.8.* (s/n): "
        STR_KERNEL_ERR_NO_PKG="Nenhum pacote de kernel (.pkg.tar.zst) encontrado no repositório."
        STR_KERNEL_ERR_DL="Falha ao baixar"
        STR_KERNEL_DOWNLOADING="Baixando"
        STR_KERNEL_INSTALLING="Instalando Kernel (linux-charcoal)..."
        STR_KERNEL_ERR_FAIL_REINSTALL="Falha na instalação do Kernel customizado, reinstalando kernel padrão."

        STR_MAIN_WELCOME="Bem vindo ao Turbo Decky! Otimize seu Steam Deck para obter o melhor desempenho em jogos!\nTodas as otimizações são seguras e podem ser revertidas."
        STR_MAIN_CHOOSE="Escolha a opção desejada:"
        STR_OPT_1="Aplicar Otimizações Recomendadas (ZSWAP + Tuning)"
        STR_OPT_2="Aplicar Otimizações (ZRAM + Tuning - Pouco espaço)"
        STR_OPT_2_CLI="Aplicar Otimizações (ZRAM + Tuning - Alternativa para pouco espaço)"
        STR_OPT_3="Reverter Tudo"
        STR_OPT_5="Restaurar Kernel Padrão (Remover linux-charcoal)"
        STR_OPT_5_CLI="Reinstalar kernel padrão (remover kernel customizado)"
        STR_OPT_6="Sair"
        STR_OPT_INVALID="Opção Inválida"
        STR_CLI_OPT="Opção: "
        
        STR_COL_ACTIVE="Ativo"
        STR_COL_OPT="Opção"
        STR_COL_DESC="Descrição"
        REGEX_YES="^[SsYy]$"
    fi
}

# Inicializa idioma
select_language

if [[ $EUID -ne 0 ]]; then
    if command -v zenity &>/dev/null; then
        zenity --error --text="$STR_ERR_ROOT" --width=300
    fi
    echo "$STR_ERR_ROOT_CLI" >&2; exit 1;
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
            sed -E -i 's|(^[^[:space:]]+[[:space:]]+/home[[:space:]]+[^[:space:]]+[[:space:]]+ext4[[:space:]]+)[^[:space:]]+|\1defaults,nofail,noatime,commit=60,x-systemd.growfs|g' "$fstab_file" || true
            _log "tweak FSTAB para /home (ext4) aplicado."
        else
            _log "nenhuma entrada /home encontrada em $fstab_file para ajustar."
        fi
    else
        _log "Tweak FSTAB para /home SKIPPED: filesystem /home é '$fstype' (somente aplica se ext4)."
    fi
}




_configure_ulimits() {
    _log "aplicando limite de arquivo aberto (ulimit) alto (524288)"
    mkdir -p /etc/security/limits.d
    cat <<'EOF' > /etc/security/limits.d/99-game-limits.conf
* soft nofile 524288
* hard nofile 524288
root soft nofile 524288
root hard nofile 524288
EOF
    _log "/etc/security/limits.d/99-game-limits.conf criado/atualizado."
}



_setup_lavd_scheduler() {
    _log "Iniciando instalação estável: LAVD Scheduler (via SteamOS Neptune Repo)"

    _steamos_readonly_disable_if_needed
    # NOVO: Garante que o DevMode está ativo para permitir alterações no pacman
    
    steamos-devmode enable --no-prompt 2>/dev/null || true

    # 1. Tratamento do pacman lock
    if [[ -f /var/lib/pacman/db.lck ]]; then
        if ! fuser /var/lib/pacman/db.lck >/dev/null 2>&1; then
            _log "Removendo pacman lock órfão..."
            sudo rm -f /var/lib/pacman/db.lck
        else
            _ui_info "erro" "$STR_ERR_PACMAN_LOCK"
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
    if ! sudo pacman -Sy --noconfirm --needed scx-scheds; then
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

   # --- 7. OTIMIZAÇÃO DE MEMÓRIA (TdMemoryTweak) ---

# Remoção de legado
for s in thp-config mglru-tune; do
    systemctl disable --now "$s.service" &>/dev/null || true
    rm -f "/etc/systemd/system/$s.service"
done
rm -f "${turbodecky_bin}/thp-config.sh"
systemctl daemon-reload

# Configuração via tmpfiles.d

cat <<'EOF' > /etc/tmpfiles.d/TdMemoryTweak.conf
w! /sys/kernel/mm/transparent_hugepage/enabled - - - - madvise
w! /sys/kernel/mm/transparent_hugepage/defrag - - - - defer+madvise
w! /sys/kernel/mm/transparent_hugepage/shmem_enabled - - - - advise
w! /sys/kernel/mm/transparent_hugepage/khugepaged/defrag - - - - 0
w! /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_none - - - - 409
w! /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_swap - - - - 8
w! /sys/kernel/mm/ksm/run - - - - 0
w! /sys/kernel/mm/lru_gen/enabled - - - - 7
w! /sys/kernel/mm/lru_gen/min_ttl_ms - - - - 200
EOF

# Aplicação imediata
systemd-tmpfiles --create /etc/tmpfiles.d/TdMemoryTweak.conf || true


    # 2. Configuração do ntsync
    echo "ntsync" > /etc/modules-load.d/ntsync.conf
    _log "configuração ntsync criada em /etc/modules-load.d/ntsync.conf"

    # 3. Gerenciamento de serviços desnecessários
    manage_unnecessary_services "disable"

    
    
    
    _log "configurações mglru, ntsync e serviços desnecessários aplicados."
}

   

create_common_scripts_and_services() {
    _log "criando scripts e services comuns"
    mkdir -p "${turbodecky_bin}" /etc/systemd/system /etc/environment.d /home/deck/.config/environment.d
    # --- 1. APLICAÇÃO DE VARIÁVEIS DE AMBIENTE ---
    if [ ${#game_env_vars[@]} -gt 0 ]; then
        printf "%s\n" "${game_env_vars[@]}" > /etc/environment.d/turbodecky-game.conf
        printf "%s\n" "${game_env_vars[@]}" > /home/deck/.config/environment.d/envvars.conf
        chmod 644 /etc/environment.d/turbodecky-game.conf
        chmod 644 /home/deck/.config/environment.d/envvars.conf
        _log "variáveis de ambiente configuradas em /etc/environment.d/turbodecky-game.conf"
    fi
    
    
}

install_io_boost_uadev() {
    _log "💾 Configurando I/O Nativo e Read-Ahead (Híbrido Adios-Aware)..."
    
    # Criar regra UDEV unificada com lógica de proteção e delay
    # Usamos RUN para garantir que o sleep de 1s ocorra antes da verificação
    cat << 'EOF' > /etc/udev/rules.d/99-turbodecky-io.rules

# 1. NVMe Interno: Tunables universais + Scheduler condicional
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", RUN+="/usr/bin/systemd-run --no-block /usr/bin/bash -c 'sleep 1; echo 512 > /sys/block/%k/queue/read_ahead_kb; echo 0 > /sys/block/%k/queue/rotational; if ! grep -q \"\\[adios\\]\" /sys/block/%k/queue/scheduler 2>/dev/null; then echo none > /sys/block/%k/queue/scheduler; fi'"

# 2. MicroSD/SD Cards: Tunables universais + Scheduler e parâmetros iosched condicionais
ACTION=="add|change", KERNEL=="mmcblk[0-9]*", RUN+="/usr/bin/systemd-run --no-block /usr/bin/bash -c 'sleep 1; echo 1024 > /sys/block/%k/queue/read_ahead_kb; echo 0 > /sys/block/%k/queue/rotational; if ! grep -q \"\\[adios\\]\" /sys/block/%k/queue/scheduler 2>/dev/null; then echo mq-deadline > /sys/block/%k/queue/scheduler; echo 200 > /sys/block/%k/queue/iosched/read_expire; echo 8000 > /sys/block/%k/queue/iosched/write_expire; echo 2 > /sys/block/%k/queue/iosched/writes_starved; echo 4 > /sys/block/%k/queue/iosched/fifo_batch; fi'"

# 3. Otimizações Gerais de Overhead (Sempre aplicadas após o delay de 1s)
ACTION=="add|change", KERNEL=="nvme[0-9]*|sd[a-z]|mmcblk[0-9]*", RUN+="/usr/bin/systemd-run --no-block /usr/bin/bash -c 'sleep 1; echo 0 > /sys/block/%k/queue/iostats; echo 0 > /sys/block/%k/queue/add_random;'"

EOF

    # Remove o arquivo de regra antigo se ele existir
    rm -f /etc/udev/rules.d/60-read-ahead.rules 2>/dev/null || true

    # Aplicar as regras imediatamente
    udevadm control --reload-rules && udevadm trigger
    _log "✅ Otimizações de I/O aplicadas (Respeitando Adios e Race Condition)."
}




_executar_reversao() {
    _steamos_readonly_disable_if_needed
    _log "executando reversão geral"
    
        # --- LIMPEZA DE NOVOS SERVIÇOS (MGLRU E PRE-CONFIG) ---
    systemctl stop mglru-tune.service zram-preconfig.service 2>/dev/null || true
    systemctl disable mglru-tune.service zram-preconfig.service 2>/dev/null || true
    rm -f /etc/systemd/system/mglru-tune.service
    rm -f /etc/systemd/system/zram-preconfig.service
    rm -f /usr/local/bin/zram-preconfig.sh
    rm -f /etc/tmpfiles.d/TdMemoryTweak.conf || true

    
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
    systemctl stop zswap-config.service zram-config.service 2>/dev/null || true
    systemctl disable zswap-config.service zram-config.service 2>/dev/null || true

    for svc in zswap-config.service zram-config.service; do
        rm -f "/etc/systemd/system/$svc"
    done

    # Remove scripts nos novos e antigos caminhos
    rm -f "${turbodecky_bin}/zswap-config.sh" "${turbodecky_bin}/zram-config.sh"
    rm -f /usr/local/bin/zswap-config.sh /usr/local/bin/zram-config.sh

    

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
systemctl disable --now zram-recompress.timer 2>/dev/null || true

rm -f "${turbodecky_bin}/zram-recompress.sh"
_log "zram-recompress timer/service removidos na reversão"

    rm -rf "${turbodecky_bin}" 2>/dev/null || true
    rm -rf "${turbodecky_dir}" 2>/dev/null || true

    _log "reversão concluída."
}


_instalar_kernel_customizado() {
    local install_msg="$STR_KERNEL_MSG"
    local resp_kernel="n"
    local REPO="zarpon/linux-charcoal-TD"
    local DEST_DIR="./kernel"

    if command -v zenity &>/dev/null; then
        if zenity --question \
            --title="$STR_KERNEL_TITLE" \
            --text="$install_msg\n\n$STR_KERNEL_Q_ZENITY" \
            --width=500; then
            resp_kernel="s"
        fi
    else
        echo -e "\n------------------------------------------------------------"
        echo -e "$install_msg"
        echo "------------------------------------------------------------"
        read -rp "$STR_KERNEL_Q_CLI" input_val
        resp_kernel="$input_val"
    fi

    [[ ! "$resp_kernel" =~ $REGEX_YES ]] && return 0

    _log "Preparando diretório..."
    rm -rf "$DEST_DIR"
    mkdir -p "$DEST_DIR"

    _log "Buscando último release..."

    local DOWNLOAD_URL
    DOWNLOAD_URL="$(curl -fsSL \
        "https://api.github.com/repos/$REPO/releases/latest" \
        | grep -oE '"browser_download_url":[[:space:]]*"[^"]+\.zip"' \
        | cut -d '"' -f 4 \
        | head -n1)"

    if [[ -z "$DOWNLOAD_URL" ]]; then
        _ui_info "erro" "$STR_KERNEL_ERR_NO_PKG"
        return 1
    fi

    local ZIP_FILE="$DEST_DIR/kernel.zip"

    _log "Baixando release ZIP..."
    echo "$STR_KERNEL_DOWNLOADING"

    if ! wget -O "$ZIP_FILE" "$DOWNLOAD_URL"; then
        _ui_info "erro" "$STR_KERNEL_ERR_DL"
        return 1
    fi

    _log "Extraindo ZIP..."

    if ! unzip -o "$ZIP_FILE" -d "$DEST_DIR"; then
        _ui_info "erro" "Falha ao extrair ZIP."
        return 1
    fi

    local PKGS
    PKGS=$(find "$DEST_DIR" -type f -name "*.pkg.tar.zst")

    if [[ -z "$PKGS" ]]; then
        _ui_info "erro" "Nenhum pacote .pkg.tar.zst encontrado."
        return 1
    fi

    _log "Iniciando instalação..."
    _steamos_readonly_disable_if_needed

    steamos-devmode enable --no-prompt

    if pacman -U $PKGS; then
        _log "Kernel instalado com sucesso."

        if command -v update-grub &>/dev/null; then
            update-grub
        else
            steamos-update-grub &>/dev/null || true
        fi

        mkinitcpio -P &>/dev/null || true

    else
        _ui_info "erro" "$STR_KERNEL_ERR_FAIL_REINSTALL"

        if pacman -S --noconfirm --needed linux-neptune-616; then

            if command -v update-grub &>/dev/null; then
                update-grub
            else
                steamos-update-grub &>/dev/null || true
            fi

            mkinitcpio -P &>/dev/null || true

            _ui_info "sucesso" "$STR_SUCCESS_RESTORE_KERNEL"
        fi
    fi

    rm -rf "$DEST_DIR"
}



optimize_zram() {
    local gen_dir="/etc/systemd/zram-generator.conf.d"
    local gen_conf="${gen_dir}/00-turbodecky.conf"
    
    [ "$(id -u)" -eq 0 ] || return 1
    _steamos_readonly_disable_if_needed

    # 1) Configuração do Gerador (primário para escrita rápida)
    mkdir -p "$gen_dir"
    cat > "$gen_conf" <<EOF
[zram0]
zram-size = ram * 1.5
compression-algorithm = lz4 zstd
swap-priority = 3000
options = discard
fs-type = swap
EOF
       
}

_setup_zram_preconfig() {
    local script="/usr/local/bin/zram-preconfig.sh"
    local service="/etc/systemd/system/zram-preconfig.service"

    [ "$(id -u)" -eq 0 ] || return 1

    _steamos_readonly_disable_if_needed

    cat > "$script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Garante que o módulo está carregado
modprobe zram

ZRAM="/sys/block/zram0"

# Aguarda device aparecer
for i in {1..50}; do
    [[ -e "$ZRAM" ]] && break
    sleep 0.1
done

[[ -e "$ZRAM" ]] || exit 1

# Reset é necessário para mudar algoritmos se o disco já tiver tamanho
echo 1 > "$ZRAM/reset"

# Configurações de algoritmos
echo "lz4" > "$ZRAM/comp_algorithm"
# Recompressão (Requer kernel 6.2+)
if [[ -e "$ZRAM/recomp_algorithm" ]]; then
    echo "algo=zstd level=4 priority=1" > "$ZRAM/recomp_algorithm"
fi
EOF

    chmod +x "$script"

    cat > "$service" <<EOF
[Unit]
Description=ZRAM Pre-Configuration
DefaultDependencies=no
After=systemd-udev-settle.service
Before=systemd-zram-setup@zram0.service swap.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$script

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable zram-preconfig.service
}


_setup_zram_recompress() {
    _log "Configurando recompressão em segundo plano do zram..."

    local recompress_script="${turbodecky_bin}/zram-recompress.sh"

    mkdir -p "${turbodecky_bin}"

    cat > "$recompress_script" <<'EOF'
#!/usr/bin/env bash
set -u

ZRAM_DEV="/sys/block/zram0"
LOCK_FILE="/tmp/zram-recompress.lock"

# Evita execução concorrente
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

# Verificações de suporte
[[ -e "${ZRAM_DEV}/recompress" ]] || exit 0
[[ -e "${ZRAM_DEV}/idle" ]] || exit 0

# Confirma uso como swap
grep -q '^/dev/zram0' /proc/swaps 2>/dev/null || exit 0

# Função segura para sysfs
write_sysfs() {
    local path="$1"
    local value="$2"
    printf '%s\n' "$value" > "$path" 2>/dev/null || return 1
}

# Marca páginas como idle
write_sysfs "${ZRAM_DEV}/idle" "all" || exit 0

# Dispara recompressão (pode falhar se busy → comportamento esperado)
write_sysfs "${ZRAM_DEV}/recompress" "type=idle threshold=2048" || exit 0

exit 0
EOF

    chmod +x "$recompress_script"

    cat > /etc/systemd/system/zram-recompress.service <<EOF
[Unit]
Description=TurboDecky ZRAM background recompression
ConditionPathExists=/sys/block/zram0/recompress
ConditionPathExists=/sys/block/zram0/idle
After=local-fs.target

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
ExecStart=${recompress_script}
EOF

    cat > /etc/systemd/system/zram-recompress.timer <<'EOF'
[Unit]
Description=TurboDecky ZRAM recompression timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=30min
AccuracySec=1min
Unit=zram-recompress.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload || true
    systemctl enable --now zram-recompress.timer || true
}

aplicar_zswap() {
    _log "Aplicando otimizações"

    _steamos_readonly_disable_if_needed
    
    _executar_reversao
    _configure_ulimits
    create_common_scripts_and_services
    install_io_boost_uadev
    systemctl stop systemd-zram-setup@zram0.service 2>/dev/null || true
    systemctl mask systemd-zram-setup@zram0.service 2>/dev/null || true
    _log "Serviço systemd-zram-setup@zram0.service mascarado."

    _apply_fstab_tweak_if_ext4

    local free_space_gb; free_space_gb=$(df -BG /home | awk 'NR==2 {print $4}' | tr -d 'G' || echo 0)
    if (( free_space_gb < zswap_swapfile_size_gb )); then _ui_info "erro" "$STR_ERR_NO_SPACE"; exit 1; fi

    _create_swapfile "$swapfile_path" "$zswap_swapfile_size_gb"

    sed -i "\|${swapfile_path}|d" /etc/fstab 2>/dev/null || true; echo "$swapfile_path none swap sw,pri=-2 0 0" >> /etc/fstab
    swapon --priority -2 "$swapfile_path" || true

    _write_sysctl_file /etc/sysctl.d/99-sdweak-performance.conf "${base_sysctl_params[@]}"
    sysctl --system || true

    _backup_file_once "$grub_config"
    
    local kernel_params=("zswap.enabled=1" "zswap.compressor=lz4" "zswap.max_pool_percent=35" "zswap.zpool=zsmalloc" "zswap.shrinker_enabled=1" "mitigations=off" "audit=0" "nmi_watchdog=0" "nowatchdog" "split_lock_detect=off")

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
echo lz4> /sys/module/zswap/parameters/compressor 2>/dev/null || true
echo 35 > /sys/module/zswap/parameters/max_pool_percent 2>/dev/null || true
echo zsmalloc > /sys/module/zswap/parameters/zpool 2>/dev/null || true
echo 1 > /sys/module/zswap/parameters/shrinker_enabled 2>/dev/null || true
sysctl -w vm.page-cluster=0 || true
sysctl -w vm.swappiness=40 || true
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
    systemctl enable --now zswap-config.service || true
   

    systemctl enable --now fstrim.timer
    _instalar_kernel_customizado

    _ui_info "sucesso" "$STR_SUCCESS_OPT"
    
    _ui_info "aviso" "$STR_WARN_REBOOT"
}

aplicar_zram() {
    _log "Aplicando otimizações (ZRAM)"

 _steamos_readonly_disable_if_needed
    _executar_reversao
    _configure_ulimits
    create_common_scripts_and_services
   install_io_boost_uadev
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


sysctl -w vm.swappiness=50 || true
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
    systemctl enable --now zram-config.service || true
   
    _ui_info "sucesso" "$STR_SUCCESS_OPT"

    
   
    # CORREÇÃO DE LÓGICA: optimize_zram deve ser chamado para configurar o dispositivo ZRAM
    optimize_zram
    _setup_zram_preconfig
   _setup_zram_recompress 
    systemctl enable --now fstrim.timer
   _instalar_kernel_customizado
    _ui_info "aviso" "$STR_WARN_REBOOT_SHORT"
}

reverter_alteracoes() {
    _executar_reversao
    _ui_info "sucesso" "$STR_SUCCESS_REVERT"
}

_restore_kernel_to_neptune() {
    steamos-devmode enable --no-prompt
    _log "Iniciando restauração do kernel padrão (linux-neptune)"

    if ! command -v pacman &>/dev/null; then
        _ui_info "erro" "$STR_ERR_NO_PACMAN"
        return 1
    fi

    if pacman -Q linux-charcoal-* &>/dev/null; then
        _log "linux-charcoal detectado. Removendo..."
        _steamos_readonly_disable_if_needed
        if pacman -Rs --noconfirm linux-charcoal-*; then
            _log "linux-charcoal removido com sucesso."
        else
            _ui_info "erro" "$STR_ERR_RM_KERNEL"
            return 1
        fi
    else
        _log "linux-charcoal não está instalado. Pulando remoção."
        _ui_info "info" "$STR_INFO_NO_KERNEL"
    fi

    _log "Instalando linux-neptune..."
    if pacman -S --noconfirm linux-neptune-616; then
        _log "linux-neptune instalado com sucesso."
        if command -v update-grub &>/dev/null; then update-grub; else steamos-update-grub &>/dev/null || true; fi
        mkinitcpio -P &>/dev/null || true
        _ui_info "sucesso" "$STR_SUCCESS_RESTORE_KERNEL"
        return 0
    else
        _ui_info "erro" "$STR_ERR_INSTALL_KERNEL"
        return 1
    fi
}

main() {
    echo -e "\n=== Turbo Decky $versao ==="
    echo -e "$STR_MAIN_WELCOME"

    if command -v zenity &>/dev/null; then
        local z_escolha
        z_escolha=$(zenity --list --title="Turbo Decky - $versao" \
            --text="$STR_MAIN_CHOOSE" \
            --radiolist \
            --column="$STR_COL_ACTIVE" --column="$STR_COL_OPT" --column="$STR_COL_DESC" \
            TRUE "1" "$STR_OPT_1" \
            FALSE "2" "$STR_OPT_2" \
            FALSE "3" "$STR_OPT_3" \
            FALSE "5" "$STR_OPT_5" \
            FALSE "6" "$STR_OPT_6" \
            --height 350 --width 500 --hide-column=2 --print-column=2 || echo "6")

        if [ -z "$z_escolha" ]; then z_escolha="6"; fi
        escolha="$z_escolha"
    else
        echo "1) $STR_OPT_1"
        echo "2) $STR_OPT_2_CLI"
        echo "3) $STR_OPT_3"
        echo "5) $STR_OPT_5_CLI"
        echo "6) $STR_OPT_6"
        read -rp "$STR_CLI_OPT" escolha
    fi

    case "$escolha" in
        1) aplicar_zswap ;;
        2) aplicar_zram ;;
        3) reverter_alteracoes ;;
        5) _restore_kernel_to_neptune ;;
        6) exit 0 ;;
        *)
           _ui_info "erro" "$STR_OPT_INVALID"
           if command -v zenity &>/dev/null; then exit 1; else main "$@"; fi
           ;;
    esac
}

main "$@"
