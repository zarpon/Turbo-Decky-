# Análise técnica do Turbo Decky

Data: 02/10/2026. Repositório: https://github.com/zarpon/Turbo-Decky-.
Branch examinada: `main`. Commit: `d6356a4c77dbb24aefaffc65982f3edf92aac46e`.
Versão interna: `4.0.0-test`.

Este relatório registra a auditoria anterior às alterações. A implementação da branch de teste está descrita em `TESTE-4.1.0.md`; `mitigations=off` foi mantido conforme instrução do usuário.

## Escopo e conclusão

Foram examinados o entrypoint, todos os oito módulos de `lib/`, o launcher AppImage, os scripts e metadados de empacotamento, os cinco testes, os dois workflows e os READMEs. O projeto atual é um utilitário Bash para Desktop/terminal, distribuído como AppImage; não há plugin Decky Loader nem frontend web nesta árvore.

O código tem boas bases: gravação atômica de configurações, snapshots, isolamento de dry-run, proteção contra ZRAM/ZSWAP simultâneos, validação do swapfile e protocolo de progresso. Entretanto, a promessa de alterações sempre seguras e reversíveis excede o comportamento observado. Corrigir propriedade dos arquivos, reversão, validação prévia e tratamento de falhas deve preceder novos tweaks.

A barra de porcentagem solicitada **já existe** na versão analisada. Precisa de correções nos caminhos de interface e de progresso mais informativo para operações longas.

Esta é uma auditoria com propostas: o código de produção não foi modificado e nada foi publicado. Nenhum tweak foi aplicado ao sistema real do ambiente.

## Validação realizada e limites

- Sintaxe: 18 arquivos shell aprovados individualmente por `bash -n`.
- `tests/test-installtd.sh`: aprovado.
- `tests/test-persistence.sh`: aprovado.
- `tests/test-zswap-runtime-guard.sh`: aprovado.
- `tests/test-progress-ui.sh`: aprovado.
- `tests/test-appimage-layout.sh`: aprovado.
- Seis reproduções adicionais em diretórios temporários confirmaram lacunas não detectadas pela suíte existente. Script: `/workspace/scratch/turbodecky-audit/reproduce.py`.

Os testes de persistência verificam arquivos e usam mocks; não executam um reboot real. Não foram medidos FPS, consumo, temperaturas ou frametime em Steam Deck LCD/OLED. Não foram validados visualmente YAD/Zenity/KDialog em uma sessão gráfica. O AppDir foi testado; não foi recompilado nem executado um AppImage completo para esta auditoria. ShellCheck não estava disponível.

## Arquitetura e pontos positivos

| Parte | Responsabilidade | Avaliação |
|---|---|---|
| `InstallTD.sh` | Carrega os módulos e chama `main` | Pequeno e compreensível; comportamento depende da ordem de `source`. |
| `lib/00-core.sh` | Valores, caminhos, UI, snapshots, arquivos comuns | Centraliza dados; reúne responsabilidades demais. |
| `lib/10-profiles.sh` | Runtime, GRUB, ZRAM e diagnóstico | Persistência explícita; compatibilidade e checagem de resultado incompletas. |
| `lib/20-actions.sh` | SCX LAVD, CLI, GUI | Fluxo simples; instalação de pacotes e estado anterior do sistema exigem revisão. |
| `lib/30-hardening.sh` | Preparação e legado | Snapshot inicial da ZRAM é uma proteção útil; migração ainda remove arquivos sem ownership. |
| `lib/40-source-sync.sh` | Diagnóstico e validação dos valores | Evita listas divergentes; validação não é chamada pelas ações de produção. |
| `lib/50-memory-mode-safety.sh` | Exclusão mútua, runtime, serviços e migração | Melhora segurança de memória; restauração não conserva todos os estados. |
| `lib/60-swapfile-safety.sh` | Swapfile de 8 GiB | Verifica tamanho, assinatura e atividade; pode destruir swap preexistente sem restaurá-lo. |
| `lib/70-zswap-runtime-guard.sh` | Guardas ZSWAP e implementação final dos perfis/reversão | Verifica enabled em runtime; reversão e falhas parciais precisam de transação. |
| `packaging/appimage/turbodecky` | Menu, autenticação e progresso | Mantém GUI no usuário comum; duplica lógica de UI e contém bugs de seleção. |
| Testes e workflows | Geração, compatibilidade e releases | Boa base automatizada; faltam testes de falha e testes reais da interface. |

`prepare_apply`, `status_report` e `configure_zswap_runtime` são redefinidos por módulos posteriores. A implementação efetiva é a última carregada. Consolidar cada função em um único módulo evita correções feitas em uma definição que nunca será usada.

## Falhas prioritárias

### A01 — Crítica: reversão sem snapshot altera um sistema que o aplicativo não gerenciou

**Referências:** `lib/70-zswap-runtime-guard.sh:150-185`; `lib/50-memory-mode-safety.sh:127-146,174-188`.

`revert_all` não verifica a existência/integridade dos snapshots antes de remover serviços e executar a limpeza de legado. Essa limpeza apaga `00-turbodecky.conf` mesmo que o arquivo tenha sido criado pelo usuário. No sistema real, a reversão também chama `remove_managed_zram`, que mascara e para a ZRAM. Sem snapshot de serviços, não há restauração desse estado.

**Reprodução:** criei uma configuração ZRAM em um root temporário sem estado do Turbo Decky e executei a reversão. Ela retornou sucesso e apagou o arquivo (`baseline-DELETED`).

**Correção:** sem estado válido, retornar “nenhuma alteração gerenciada para reverter”. Limitar a reversão aos recursos registrados na transação. Reverter apenas SCX não deve modificar memória, ZRAM ou GRUB.

### A02 — Crítica: restauração com backup ausente apaga o arquivo atual

**Referência:** `lib/00-core.sh:510-527`.

`restore_files` executa `rm -rf` antes de verificar se o backup necessário existe. Se o manifesto diz `existed=1`, mas o backup sumiu, o arquivo atual é apagado e a função pode terminar com sucesso. Isso afeta inclusive `/etc/default/grub` e `/etc/fstab`.

**Reprodução:** fiz snapshot do GRUB temporário, removi o backup e restaurei. Resultado: `grub-DELETED`, sem erro.

**Correção:** validar todos os backups e seu checksum antes de alterar qualquer arquivo; restaurar por substituição atômica; preservar arquivo e snapshot se ocorrer falha. Não usar remoção recursiva para arquivos comuns.

### A03 — Alta: swapfile preexistente pode ser destruído e não restaurado

**Referências:** `lib/60-swapfile-safety.sh:64-97,107-152,177-189`.

Qualquer `/home/swapfile` com tamanho diferente de exatamente 8 GiB é removido, mesmo que seja um swap válido do SteamOS. O conteúdo/tamanho/UUID/estado ativo/permissões anteriores não são registrados para restauração. O snapshot de `fstab` não basta: a reversão remove o novo arquivo e pode restaurar uma entrada para um arquivo que deixou de existir.

A checagem de espaço livre acontece em `create_real_swapfile`, depois da remoção do swap antigo. Uma falha de espaço pode deixar a máquina sem o recurso anterior.

**Correção:** usar caminho exclusivo do aplicativo; aceitar swap existente compatível sem impor 8 GiB; validar espaço antes de remover qualquer recurso; preservar o swap anterior ou registrar uma estratégia verificável de recriação. A validação atual de tamanho/assinatura/atividade deve ser mantida.

### A04 — Alta: falha no meio da operação deixa alterações parciais

**Referências:** `lib/30-hardening.sh:47-67`; `lib/70-zswap-runtime-guard.sh:119-146`; `lib/00-core.sh:571-578`.

Antes de validar o swapfile e o suporte completo do kernel, o perfil já escreve sysctl, THP, ambiente, limites e udev, modifica serviços e pode remover ZRAM. O trap de saída restaura o modo readonly e fecha o progresso; não desfaz a transação. O arquivo `profile` só é escrito no fim, logo o diagnóstico pode dizer “não aplicado” apesar de mudanças parciais.

**Reprodução:** injetei uma falha explícita em `ensure_swapfile`, usando root temporário. O sysctl permaneceu alterado e o perfil não foi registrado.

**Correção:** separar análise prévia, plano, snapshot completo, execução, validação e commit. Persistir estado `applying/failed/partial/applied/reverting`; em falha, desfazer somente a transação atual e manter backup e evidências se a recuperação falhar.

### A05 — Alta: reversão ignora erros e elimina a possibilidade de tentar novamente

**Referências:** `lib/50-memory-mode-safety.sh:76-125`; `lib/70-zswap-runtime-guard.sh:166-184`.

Falhas de `sysctl`, writes sysfs, start/stop/mask de serviços e `swapon -a` são ignoradas com `|| true`. Mesmo com runtime incorreto, `STATE_DIR` é removido e a UI anuncia sucesso. O estado anterior de readonly também é restaurado sem reportar falha.

**Correção:** tratar recursos ausentes como incompatibilidade explícita, diferenciar erro obrigatório/opcional e coletar falhas. Só eliminar os snapshots depois de comprovar restauração. Mostrar “reversão parcial” quando necessário.

### A06 — Alta: limpeza de legado remove configurações sem comprovar autoria

**Referências:** `lib/30-hardening.sh:6-35`; `lib/50-memory-mode-safety.sh:127-146`.

A lista inclui arquivos genéricos como `/etc/modprobe.d/amdgpu.conf`, `/etc/modules-load.d/ntsync.conf` e `99-sdweak-performance.conf`. Eles podem pertencer a outro utilitário ou ao usuário. Exceto o caso especial da ZRAM, os arquivos removidos não entram no manifesto antes da exclusão. Backups legados de GRUB/fstab também são restaurados antes do snapshot novo desses arquivos, alterando o baseline prometido.

**Correção:** exigir marcador ou registro de ownership, fazer snapshot antes da migração e tornar conflitos visíveis no plano. Não apagar arquivos de outras ferramentas apenas pelo nome.

### A07 — Alta: o parser do GRUB pode descartar parâmetros válidos

**Referência:** `lib/10-profiles.sh:22-74`.

A regex só aceita `GRUB_CMDLINE_LINUX="..."` sem espaços ao redor de `=`. Uma atribuição válida com aspas simples é ignorada; o código acrescenta outra atribuição, que prevalece e perde as opções anteriores.

**Reprodução:** `GRUB_CMDLINE_LINUX='quiet root=UUID=example'` permaneceu na primeira linha e foi seguido de outra atribuição sem `root=UUID=example`.

Também não há tratamento de opções conflitantes em `GRUB_CMDLINE_LINUX_DEFAULT`. Na ausência de GRUB/updater, o fluxo pode informar sucesso sem persistir o modo de memória no bootloader efetivo.

**Correção:** adaptar por bootloader, preservar a sintaxe existente, validar as duas variáveis e recusar formatos não suportados antes de alterar o arquivo. Distinguir “runtime aplicado” de “boot configurado”.

### A08 — Alta: instalação SCX faz atualização parcial e não restaura todos os efeitos

**Referência:** `lib/20-actions.sh:1-60`; `lib/00-core.sh:541-551`.

`pacman -Sy ... scx-scheds` atualiza os índices e instala pacotes sem atualizar o sistema inteiro. Em Arch, isso cria risco de atualização parcial e incompatibilidade com bibliotecas instaladas. No SteamOS, atualizar o sistema inteiro automaticamente também não é uma solução adequada: é necessário um fluxo compatível com a imagem/versionamento do sistema.

Não há análise prévia de sched_ext/BTF, compatibilidade da versão de LAVD nem conflitos com outros schedulers. `steamos-devmode enable` e alterações no keyring/pacotes não são revertidos. `Conflicts=scx.service` pode parar um scheduler existente que não consta do snapshot. Estados `enabled-runtime`, `linked` e `masked-runtime` são convertidos em operações persistentes diferentes durante restore.

A combinação `After=multi-user.target` e `WantedBy=multi-user.target` merece revisão: é inversa ao padrão de ordenar o serviço antes do target que o puxa. Não foi demonstrado um ciclo neste ambiente, portanto isto é recomendação de revisão, não falha de boot confirmada.

**Correção:** detectar capacidades primeiro, preferir pacote já disponível/compatível e usar instalação específica por distribuição. Capturar unidades concorrentes, symlinks e estados runtime. Separar “instalar pacote” de “ativar scheduler”; informar o que a reversão cobre.

### A09 — Alta: snapshots antigos sobrescrevem alterações posteriores do usuário

**Referências:** `lib/00-core.sh:496-527`; `lib/70-zswap-runtime-guard.sh:152`.

O snapshot é do primeiro uso e restaura arquivos completos. Alterações posteriores feitas por SteamOS, outro utilitário ou usuário em GRUB/fstab são perdidas.

**Reprodução:** adicionei `user-added=1` ao GRUB após o backup. A restauração voltou a `quiet` e removeu a opção.

**Correção:** registrar original, última versão escrita e versão atual; detectar conflito e remover somente chaves/entradas gerenciadas quando possível. Guardar snapshots por transação, mantendo separado o baseline inicial.

### A10 — Alta: falta de lock e segurança na troca de memória sob pressão

**Referências:** `lib/30-hardening.sh:47`; `lib/60-swapfile-safety.sh:64`; `lib/50-memory-mode-safety.sh:174-198`.

Duas instâncias podem escrever o manifesto, remover swapfiles e alternar ZRAM/ZSWAP simultaneamente. Não existe `flock` global. Desativar/reiniciar swap sob forte pressão de RAM pode levar a stall ou OOM, mesmo que o código detecte o erro depois.

**Correção:** lock único em `/run/lock`, preflight de memória/swap/PSI e bloqueio de troca com jogos em execução quando não houver margem segura. Oferecer “preparar para o próximo boot” sem trocar memória em runtime.

## Interface e progresso

### A11 — Confirmada: menu de terminal não executa a seleção corretamente

**Referências:** `lib/00-core.sh:452-465`; `lib/20-actions.sh:76-87`; `packaging/appimage/turbodecky:198-215,375-379`.

As funções escrevem tanto o menu quanto a opção em stdout, mas os chamadores fazem `action="$(...)"`. O valor contém o menu completo seguido da opção. O backend sai pelo caso default; o launcher acusa ação inválida.

**Reprodução:** selecionar `3` em `ui_menu` produz uma string multilinha terminando em `status`, não apenas `status`.

**Correção:** renderizar o menu em stderr/TTY e devolver exclusivamente o identificador em stdout; tratar EOF/cancelamento como saída normal. Testar os dois menus ponta a ponta.

### A12 — Código incompatível com saída padrão do YAD

**Referências:** `lib/00-core.sh:419-427`; `packaging/appimage/turbodecky:170-178`.

YAD imprime o separador após o campo selecionado. O padrão documentado é `|`; o código fonte de YAD também imprime o separador no fim do campo. Assim, a opção tende a ser `apply-zram|`/`zram|`, que não coincide com o `case`. Não há `--separator` explícito nem normalização. Isto foi verificado na documentação/fonte do YAD, sem execução gráfica local.

**Correção:** definir `--separator=''` e validar/normalizar o identificador. Não interpretar texto visível como comando.

### A13 — Progresso atual existe, mas ainda pode ser enganoso ou perder informações

**Referências:** `lib/00-core.sh:259-372`; `lib/70-zswap-runtime-guard.sh:90-146`; `packaging/appimage/turbodecky:88-166,243-319`.

- Percentuais são marcos fixos por etapa, não medida de bytes/tempo/trabalho total. Download SCX e criação de swap podem ficar muito tempo parados no mesmo número.
- O launcher mostra 3% esperando autenticação; o backend emite 0% e depois 5%. Há regressão na porcentagem.
- `prepare_apply` faz limpeza, gera várias configurações e modifica serviços sob um único rótulo de 5%; o rótulo de “limpando legados” vem depois dessa limpeza.
- Backend e launcher mantêm implementações de UI duplicadas.
- O gauge `dialog` emite `XXX`, mensagem, percentual, `XXX`; o protocolo deve começar o bloco com o percentual e depois o texto.
- KDialog depende de QDBus. Se a detecção falhar, o AppImage pode cair em progresso de terminal, invisível para quem abriu com duplo clique (`Terminal=false`).
- Status é uma leitura síncrona e não tem progresso próprio; não convém apresentar porcentagem fictícia para uma leitura curta.
- Erros esperados de `die` têm mensagem específica; erros imprevistos sob `set -e` podem aparecer apenas como interrupção genérica, sem comando/etapa causadora.
- Cancelar/fechar o aplicativo não possui contrato de cancelamento e recuperação. O trap do launcher apaga temporários, mas não coordena explicitamente o filho privilegiado.
- No menu do launcher, `run_action ... || true` suprime `errexit` dentro das funções chamadas. Portanto falhas de staging/instalação de arquivos exigem testes explícitos de retorno; confiar apenas em `set -e` nesse caminho é insuficiente. O backend executado como processo separado tem seu próprio comportamento de `set -e`.

**Correção proposta:** protocolo de eventos único e renderizadores finos; progresso monotônico; eventos com `operation_id`, `state`, `step_id`, `step_label`, `percent`, `detail` e `error_code`. Tratar cada comando obrigatório explicitamente. Manter rastreamento de etapa para o trap de erro.

## Outras lacunas de execução e diagnóstico

1. **Runtime parcialmente silencioso.** `apply_runtime_profiles` chama `sysctl --system` para todo o sistema: um erro de configuração alheia pode abortar o perfil. THP/udev podem falhar silenciosamente. Usar aplicação restrita ao arquivo e verificar readback de cada parâmetro suportado.
2. **Sucesso ZRAM insuficientemente verificado.** Unidade ativa não comprova, por si só, que `/dev/zram0` está ativo em `swapon`, nem tamanho/compressor/prioridade desejados. Verificar esses valores e diagnosticar drop-ins de prioridade posterior ao `00-turbodecky.conf`.
3. **Serviço ZSWAP sem garantia de backing swap.** `After=swap.target` e `Wants=swap.target` estabelecem ordem/puxam o target, mas não validam que o swapfile funcionou. O helper só verifica `enabled`. Validar swap efetivo no helper e vincular a unidade de swap quando aplicável.
4. **Swap reutilizado não é totalmente rastreado.** Reutilizar swap válido de 8 GiB pode mudar permissões, fstab e estado ativo, mas não registra ownership/criação nem atividade anterior. Troca para ZRAM pode manter backing swap existente; isso não é ZSWAP+ZRAM simultâneo, mas precisa estar claro na UI e na reversão.
5. **Udev não reverte atributos runtime.** `iostats`, `read_ahead_kb` e outros atributos não têm snapshot. Remover/restaurar regras e recarregá-las não desfaz necessariamente valores já escritos no dispositivo. Registrar atributos por dispositivo e restaurar readback; evitar padrões que também alcancem partições sem os atributos.
6. **Diagnóstico não comprova a configuração inteira.** Não mostra claramente swap de disco, enabled/pool/compressor ZSWAP, scheduler efetivo, serviços, boot pendente, colisões de configuração e erros de última operação. Perfil gravado é intenção, não estado efetivo.
7. **Validação não usada em produção.** `validate_generated_profile` exige arquivo ZRAM mesmo para outros modos e só aparece nos testes. Criar validadores específicos por perfil e pós-condições runtime.
8. **Ambiente Mesa e nofile.** `environment.d` e `limits.d` não alteram jogos já abertos. A propagação para Steam/Game Mode deve ser verificada; respeitar variantes de driver/cache e limites do serviço/user manager, sem prometer efeito imediato.
9. **Snapshot não é uma transação atômica.** Arquivos de snapshot são preenchidos diretamente e a existência basta para considerá-los completos. Uma interrupção pode deixar snapshot parcial. Gravar em temporário, validar e promover, com versão de esquema e checksum.
10. **Portabilidade do pacote.** AppImage depende de Bash, Python, ferramentas de swap/GRUB/systemd e de UI/autenticação do host; não é totalmente autocontido. Exibir requisitos detectados antes de ações e reportar falta de GUI sem falhar silenciosamente.
11. **Releases.** O build baixa `appimagetool` da tag mutável `continuous` e o executa sem checksum fixado. Fixar versão/hash e versão de actions. Atualização de `Latest` substitui assets sem necessariamente atualizar o commit da tag existente. Publicar versões imutáveis, commit do build e manter `Latest` como ponteiro claramente identificado.
12. **Documentação além do código.** README promete otimização de GPU e ganhos de desempenho sem benchmark publicado; o código atual principalmente faz memória, cache, armazenamento e serviços. A remoção de arquivos AMDGPU legados não é uma nova otimização da GPU. Explicitar compatibilidade testada e efeitos cobertos pela reversão.

## Reavaliar os tweaks atuais

| Ajuste atual | Avaliação para FPS estável | Proposta |
|---|---|---|
| ZRAM LZ4, `ram * 1.5` | Pode ajudar sob pressão; tamanho lógico não é RAM pré-alocada, mas tamanho/política ideais variam. | Manter como opção; comparar padrão SteamOS, variantes conservadoras e pressão real. |
| ZSWAP LZ4, pool 35%, swap 8 GiB | Pool máximo não é reserva fixa; CPU, RAM e I/O têm custos. | Tornar limites/tamanho configuráveis e validar por workload; evitar imposição universal de 8 GiB. |
| THP `madvise`, defrag controlado | Plausível, dependente de aplicação/kernel. | Manter experimental/conservador com readback e A/B por jogo. |
| KSM desligado | Pode reduzir trabalho de deduplicação, mas muitas instalações já o mantêm desligado. | Não apresentar como ganho se já estava desligado; explicar conflito com VMs. |
| MGLRU enabled=7 | Depende de suporte/configuração do kernel; pode já ser padrão. | Detectar disponibilidade/estado e pular sem erro se inaplicável. |
| Sysctl de memória fixos | Tradeoffs entre reserva, cache, writeback e reclaim; copiar Charcoal não comprova ganho em outro kernel. | Separar baseline e experimental; usar capacidades e medições. |
| `mitigations=off`, audit/watchdogs off | Reduz proteções/diagnóstico; ganho não foi demonstrado nesta auditoria. | Retirar do perfil comum; opt-in avançado com explicação e benchmark. |
| Split lock mitigation/detection off | Aplicabilidade depende da CPU/kernel e do workload. | Mostrar indisponível/inaplicável quando não suportado; não aplicar universalmente. |
| Shader cache Mesa 10G | Pode preservar cache entre sessões, mas não precompila shaders nem cura todo stutter. | Mostrar espaço, driver/cache efetivo; opções por jogo; evitar limpar cache automaticamente. |
| Read-ahead NVMe 512/microSD 1024 | Pode ajudar acesso sequencial e piorar desperdício em acesso aleatório. | Medir por dispositivo/jogo; preservar padrões como baseline. |
| `iostats=0` | Pequeno custo evitado, mas perde observabilidade útil para diagnosticar stalls. | Manter estatísticas por padrão. |
| Desativar cups/telemetria | Efeito em frametime não demonstrado; cups envolve uso de impressão. | Oferecer seleções separadas e indicar impacto funcional. |
| `fstrim.timer` | Manutenção razoável em dispositivos compatíveis; não garante ganho imediato de FPS. | Preservar política anterior e evitar trim durante benchmark/jogo. |
| SCX LAVD `--performance` | Potencial para CPU-bound; pode competir por orçamento energético compartilhado da APU. | Opcional, por jogo/energia, com compatibilidade e benchmark. |
| `nofile=524288` | Evita limites específicos; não aumenta FPS genericamente. | Alterar apenas quando necessário e comprovar limite da sessão Steam. |

## Proposta de interface e interação

### Tela inicial

Apresentar modelo LCD/OLED/outro, versão SteamOS/kernel, perfil efetivo, estado do scheduler, memória/swap, espaço e necessidade de reiniciar. Distinguir `ativo agora`, `configurado para o próximo boot`, `parcial` e `indisponível`.

Ações principais: **Diagnosticar**, **Configurar**, **Comparar desempenho** e **Restaurar**. Mostrar opções com descrição compreensível: “memória comprimida em RAM (ZRAM)” e “cache comprimido para swap em disco (ZSWAP)”. Charcoal é referência de parâmetros; usar o nome sem contexto pode sugerir troca de kernel, que o aplicativo não faz.

### Antes de aplicar

Exibir o plano real: alterações, estados já corretos, requisitos ausentes, espaço necessário, impacto funcional, conflitos e reinicialização. Deixar opções sem suporte desabilitadas com motivo. Separar tweaks avançados da escolha de memória.

### Durante a operação

Exemplo de conteúdo:

```text
Aplicando configuração de memória                       48%
[████████████░░░░░░░░░░░░]
Etapa 4 de 8 — Criando o swapfile
Gravados 3,2 GiB de 8 GiB
[Ver detalhes]
```

Os percentuais devem medir o plano/etapas concluídas; não equivalem a tempo restante. Para operações mensuráveis, emitir progresso interno real (bytes de `dd`, download, número de verificações). Para `fallocate`/GRUB/initramfs sem medida confiável, mostrar atividade indeterminada dentro da etapa e tempo decorrido. Não estimar conclusão com timer fictício.

Distribuição inicial possível, ajustada ao plano concreto: validar requisitos 0–10%, snapshot 10–20%, configurações 20–40%, memória/swap 40–70%, boot 70–90%, readback 90–98%, finalização 98–100%. Só mostrar 100% após finalizar logs/estado, readonly e pós-condições obrigatórias.

Autenticação deve ser um estado anterior separado, sem começar em 3% e voltar a 0%. Percentual exibido deve ser monotônico. Atualizações de etapa devem ocorrer no momento do trabalho. A janela deve continuar responsiva, com detalhe da operação privilegiada.

Cancelar somente em fronteiras seguras. Durante escrita crítica, explicar que a etapa será concluída antes de interromper. Fechar a janela deve ter comportamento explícito: continuar em segundo plano com retorno de status, ou cancelar coordenadamente com recuperação. Preservar logs e erro da etapa para diagnóstico.

### Depois de aplicar

Mostrar resumo das mudanças verificadas, recursos ignorados, erros, perfil efetivo e próximo passo. Se o bootloader não foi atualizado, não informar configuração plenamente persistente. Oferecer copiar/exportar diagnóstico e restaurar a última transação. Não incluir dumps técnicos extensos no resumo padrão.

### Navegação e implementação

No curto prazo, aproveitar os diálogos atuais, corrigir menus e centralizar renderização/eventos. Para uma interface persistente com dashboard e navegação por controle, considerar frontend Qt/PySide; validar tamanho do pacote e integração KDE. Um plugin Decky para Game Mode é um produto adicional que requer integração própria e helper administrativo restrito, não uma alteração apenas do launcher atual.

Testar 1280×800 e modo dock, toque/controle/teclado, foco visível, escala de fonte, PT/EN e estados indicados por texto além de cor. Evitar hover obrigatório e janelas maiores que a área disponível.

## Novas funções e tweaks com maior valor

1. **Benchmark A/B por jogo.** Importar ou integrar logs MangoHud e comparar frametime mediano/P95/P99, 1% low com definição documentada, quantidade de frames acima do orçamento, consumo, temperatura e pressão de memória. Executar 3–5 repetições por condição, mesma cena, resolução, limite de FPS, cache aquecido e alimentação. Mostrar variação entre runs, não apenas uma média.
2. **Assistente de FPS/Hz.** Recomendar alvo sustentável (30/40/45/60 quando suportado pelo painel/modo), baseado na cena medida. Exemplo: orçamento de 25 ms para 40 FPS. Diferenciar limiter do jogo/Steam e evitar dois limitadores concorrentes. Aplicar somente através de integração confiável disponível.
3. **Perfis por jogo.** Registrar escolhas por Steam AppID, alimentação/bateria, estado anterior e conflitos. Restaurar ao sair do jogo. Priorizar parâmetros realmente ajustáveis em runtime; GRUB global não é um tweak por jogo. Só um controlador deve alterar TDP/GPU/CPU.
4. **Diagnóstico de gargalo.** Mostrar pressão de memória PSI, swap-in/out, GPU/CPU, temperatura, consumo e evidências de limitação térmica/energética quando expostas. Separar hipótese de medição; baixa ocupação média da CPU não exclui gargalo em uma thread.
5. **Ajuste de TDP/GPU orientado por medição.** Explorar o menor orçamento que mantém o alvo sem piorar P99. Evitar frequências máximas universais: CPU e GPU dividem energia na APU. Exigir suporte do dispositivo e respeitar os controles existentes do SteamOS/plugins.
6. **Preparar jogos antes de iniciar.** Orientar downloads, verificação/compilação de shaders disponível na plataforma e tarefas de manutenção para fora da sessão. Não prometer precompilação universal; não apagar caches como “otimização”.
7. **Comparação e restauração por tweak.** Separar memória, scheduler, cache, serviços e armazenamento; mostrar efeito incremental. Isso facilita identificar o responsável por uma regressão.
8. **Checagem após atualização do SteamOS.** Detectar drift, recursos removidos e incompatibilidades; oferecer plano de reparo, sem reaplicar automaticamente configurações antigas em kernel novo.

ZRAM/ZSWAP, scheduler e ajustes de memória devem ser classificados como opções a validar. Evitar adicionar drop_caches periódico, swapoff automático durante jogos, limpeza recorrente de shader cache, RAM cleaners, desativação de proteções térmicas ou perfis de “máximo desempenho” universais: esses comportamentos podem produzir mais stalls e variância.

## Plano de implementação

**P0 — Integridade:** A01–A06, ownership, preflight, lock, backups verificados, swap exclusivo, transação e estado parcial. Adicionar testes de reversão sem snapshot, backup ausente/corrompido, falta de espaço, falha após cada etapa, troca sob pouca RAM, concorrência e recursos alheios.

**P1 — Execução/UI:** menus terminal/YAD, retorno de erro explícito no launcher, cancelamento, progresso/eventos centralizados, detecção de GUI/Polkit, validadores por perfil, bootloader suportado, preservação de estados de serviços. Testes com mocks que devolvem saída real das ferramentas e smoke tests gráficos em KDE/Wayland e X11.

**P2 — Experiência:** dashboard, planos compreensíveis, resultado verificado, detalhe sob demanda, PT/EN e navegação por controle. Testar em Deck LCD/OLED e instalação SteamOS limpa, com e sem configurações de terceiros.

**P3 — Desempenho:** benchmark A/B, perfis por jogo e assistente de alvo FPS; só então promover novos valores default. Publicar resultados reproduzíveis para jogos CPU-bound, GPU-bound e sob pressão de memória. Um perfil só deve ser promovido quando melhorar estabilidade sem regressões materiais em consumo, temperaturas ou compatibilidade.

## Resultado das reproduções adicionais

```text
terminal-menu: exit=1
captured=<texto completo do menu seguido de status>
revert-without-snapshot: exit=0
baseline-DELETED
missing-backup: exit=0
grub-DELETED
single-quoted-grub: exit=0
GRUB_CMDLINE_LINUX='quiet root=UUID=example'
GRUB_CMDLINE_LINUX="zswap.enabled=0 mitigations=off audit=0 nmi_watchdog=0 nowatchdog split_lock_detect=off"
failure-after-prepare: exit=0
sysctl-STILL-CHANGED
profile-NOT-COMMITTED
stale-whole-file-snapshot: exit=0
GRUB_CMDLINE_LINUX="quiet"
```

Os códigos acima são da execução de cada cenário de auditoria; o cenário de falha injeta `die` e captura esse erro propositalmente para inspecionar os arquivos deixados no disco. Todos usam `TURBODECKY_ROOTFS` temporário e dry-run. Não exercitam sysfs/swap do host.

Documentação/fonte externa consultada para saída de seleção YAD:
- https://raw.githubusercontent.com/v1cont/yad/master/data/yad.1
- https://raw.githubusercontent.com/v1cont/yad/master/src/list.c
