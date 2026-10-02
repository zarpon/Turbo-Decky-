# Turbo Decky 4.1.0-test.1

Branch: `test/safe-profiles-progress-no-lavd`.

## Alterações

- Mantido `mitigations=off` nos perfis ZRAM e ZSWAP.
- Removidos instalador LAVD, comandos pacman, opção de menu e ação `--setup-lavd`. Schedulers já instalados não são desinstalados.
- Swap exclusivo em `/home/.swap/turbodecky.swap`; o swap do SteamOS e arquivos sem ownership são preservados.
- Reversão sem snapshot não faz alterações. Backups são validados antes da restauração, com checksum e substituição atômica.
- Journal por operação, recuperação de falhas/interrupções, estado parcial preservado e ação `--recover`.
- Lock único e verificação de conflitos com alterações externas após a aplicação.
- Parser GRUB separado, suportando aspas simples, espaços e preservação das duas variáveis de command line; formatos ambíguos/dinâmicos são recusados.
- Menus terminal e YAD corrigidos; resumo de estado no menu AppImage, progresso monotônico, etapas identificadas e logs persistentes.
- Diagnóstico ZSWAP/swap/memória/boot pendente; verificação de aplicação de sysctl/THP e backing swap no boot.
- Estatísticas I/O mantidas e atributos de bloco capturados para restauração; regras restritas a discos.
- Ferramenta AppImage fixada em 1.9.1 com SHA-256 conhecido. CI de branches `test/**` gera artifact, sem publicar `Latest`.

## Validação automatizada

Aprovados: sintaxe de todos os scripts, ShellCheck 0.11.0 (`-x -S warning`), sete suítes shell, três casos unittest do parser GRUB e smoke tests do AppImage completo (versão, diagnóstico, aplicação dry-run e rejeição de LAVD).

Os cenários de segurança incluem: reversão sem snapshot, backup ausente/corrompido, modificação externa, falha após iniciar alterações, erro inesperado, recuperação parcial com nova tentativa, SIGKILL, concorrência, falta de espaço e preservação de swap/arquivos de terceiros. Os testes usam roots temporários e mocks; nenhum tweak é aplicado ao host.

## Teste no Steam Deck

1. Execute o AppImage em Modo Desktop e abra Diagnóstico.
2. Aplique ZRAM; acompanhe as etapas e confirme o resultado. Reinicie e confira novamente o diagnóstico.
3. Se houver pelo menos 9 GiB livres, teste ZSWAP, confirme backing swap e reinicie.
4. Alterne entre os perfis e restaure o baseline; confira que o swap/configurações anteriores foram preservados.
5. Compare a mesma cena dos jogos, com alimentação, resolução, limite de FPS e cache equivalentes. Meça frametime e consumo, além do FPS médio.

A validação gráfica em KDE/Wayland, reinicialização e FPS real em LCD/OLED depende de aparelho físico e não foi executada no ambiente de build. Benchmark integrado, perfis automáticos por jogo e controle TDP/GPU continuam propostas futuras; não foram introduzidos ajustes não medidos nesta versão.

O build local não publica assets na release de produção. O AppImage gerado e seu checksum estão em `dist/`.
