# Turbo Decky

Utilitário de otimização para SteamOS e distribuições Arch Linux compatíveis. A versão 4 reorganiza o código para tornar aplicação, diagnóstico e reversão determinísticos.

## Principais mudanças da versão 4

- perfil `sysctl` sincronizado com `zarpon/linux-charcoal-vulcano`;
- política THP/memória sincronizada com `99-charcoal-memory.conf` do kernel Charcoal;
- ZRAM gerenciado apenas pelo `zram-generator`, sem timer, serviço ou comando de recompressão;
- interface com suporte a YAD, Zenity, KDialog, Dialog e terminal;
- modo de diagnóstico que exibe kernel, ZRAM, sysctl e THP efetivos;
- snapshots dos arquivos, valores de runtime e estados dos serviços antes da primeira aplicação;
- reversão restrita aos recursos gerenciados pelo Turbo Decky;
- comandos não interativos para validação e automação;
- instalação do kernel Charcoal separada da aplicação das otimizações.

## Perfis disponíveis

### ZRAM padrão

Mantém o ZRAM do sistema por meio de `/etc/systemd/zram-generator.conf.d/00-turbodecky.conf`:

- tamanho: `ram * 1.5`;
- algoritmos aceitos, em ordem: `lz4 zstd`;
- prioridade de swap: `3000`;
- sem recompressão temporizada ou imediata.

### ZSWAP

Configura ZSWAP com LZ4, zsmalloc e pool de 35%, além de um swapfile de 8 GiB quando ainda não existe um swapfile compatível.

## Perfil sysctl sincronizado

```text
vm.swappiness=1
vm.page-cluster=0
vm.min_free_kbytes=262144
vm.compaction_proactiveness=15
vm.dirty_expire_centisecs=3500
vm.dirty_writeback_centisecs=500
vm.watermark_boost_factor=0
vm.watermark_scale_factor=125
kernel.split_lock_mitigate=0
vm.dirty_background_bytes=209715200
vm.dirty_bytes=409430400
vm.vfs_cache_pressure=125
```

O `linux-charcoal-vulcano` também possui um ajuste opcional específico do
ZRAM-IR. Ele não é copiado pelo Turbo Decky porque esta branch remove a lógica
de recompressão e conserva somente o perfil padrão do `zram-generator`.

## Perfil THP/memória sincronizado

```text
THP enabled=madvise
THP defrag=defer
THP shmem_enabled=advise
khugepaged defrag=0
khugepaged max_ptes_none=64
khugepaged max_ptes_swap=0
KSM run=0
MGLRU enabled=7
MGLRU min_ttl_ms=0
```

## Execução

Interface automática:

```bash
sudo bash InstallTD.sh --gui
```

Comandos diretos:

```bash
sudo bash InstallTD.sh --apply-zram
sudo bash InstallTD.sh --apply-zswap
bash InstallTD.sh --status
sudo bash InstallTD.sh --revert
sudo bash InstallTD.sh --setup-lavd
sudo bash InstallTD.sh --install-kernel
sudo bash InstallTD.sh --restore-kernel
```

## Reversão

Na primeira aplicação, o script registra:

- conteúdo original dos arquivos alterados;
- valores sysctl e THP em runtime;
- estado habilitado/mascarado e ativo/inativo dos serviços gerenciados;
- criação do swapfile pelo Turbo Decky.

A reversão restaura esses snapshots em vez de presumir valores padrão. Resíduos das antigas unidades de recompressão ZRAM são removidos durante aplicação e reversão.

## Validação local

```bash
bash -n InstallTD.sh
bash -n tests/test-installtd.sh
bash tests/test-installtd.sh
```

O teste usa um root temporário, não altera o sistema local e valida:

- todos os valores sysctl e THP;
- criação do perfil ZRAM sem recompressão;
- edição idempotente do GRUB;
- remoção de resíduos antigos;
- backup e restauração de arquivos;
- ciclo completo de aplicação e reversão em modo isolado.

## Limitações

- requer SteamOS ou uma distribuição compatível com `systemd`, `sysctl` e ferramentas Arch para funções de kernel/LAVD;
- a alteração do kernel exige `pacman` e deve ser usada somente em sistemas compatíveis;
- `mitigations=off` reduz proteções contra vulnerabilidades de CPU em troca de menor overhead;
- as otimizações não garantem ganho de FPS em todos os jogos; o efeito depende de hardware, carga e versão do SteamOS.
