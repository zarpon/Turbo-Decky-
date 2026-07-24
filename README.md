**Português** | [English](README.en.md)

# Contribua se puder

Caso goste do resultado obtido com esse aplicativo, considere fazer uma doação de qualquer valor para o pix jorgezarpon@msn.com

# Turbo-Decky-
 Otimização do SteamOs 

O APP deve funcionar em qualquer aparelho que utiliza o SteamOs e também distribuições baseadas em arch linux. 

# O que é o Turbo Decky?

O Turbo Decky é um utilitário criado para melhorar o desempenho do SteamOS (usado no Steam Deck) e deixar o sistema mais rápido, fluido e estável — especialmente em jogos.

Ele faz ajustes automáticos no sistema para aproveitar melhor a memória, o processador, o armazenamento e a placa de vídeo.
Essas otimizações são seguras, reversíveis e voltadas para quem quer mais desempenho sem precisar entender de configurações técnicas.


---

# O que ele faz?

O Turbo Decky aplica uma série de melhorias internas, como:

Acelera o carregamento de jogos e reduz micro travamentos.

Faz com que o sistema gerencie melhor a memória (RAM).

Usa o Zswap, que ajuda a evitar quedas de desempenho quando a RAM está cheia.

Ajusta a forma como o SteamOS grava e lê arquivos, tornando o sistema mais ágil.

Otimiza o comportamento da placa de vídeo (AMDGPU).

Desativa serviços do sistema que consomem recursos desnecessariamente.

Ajusta limites do sistema para evitar gargalos em jogos.

Permite a instalação de um Kernel Customizado para melhor desempenho.

O Turbo Decky permite a instalação do Kernel Customizado Charcoal-vulcano.
Essa é uma Versão customizada do kernel desenvolvido por V10lator.
Atenção! A compatibilidade do Kernel atualmente é apenas com a versão 3.8.* do SteamOs, canal estável. 

Esse é o github do charcoal Kernel: https://github.com/V10lator/linux-charcoal

Tudo é feito automaticamente — basta escolher a opção e deixar o script trabalhar.

# Como Instalar e Executar

## Método recomendado: AppImage

1. No Steam Deck, entre no **Modo Desktop**.
2. Baixe o arquivo mais recente:

   **[Baixar TurboDecky-x86_64.AppImage](https://github.com/zarpon/Turbo-Decky-/releases/download/Latest/TurboDecky-x86_64.AppImage)**

3. No Dolphin, clique com o botão direito no arquivo, abra **Propriedades > Permissões** e marque **É executável**.
4. Abra o AppImage com dois cliques.
5. Escolha a otimização desejada. A senha administrativa será solicitada somente quando a ação precisar alterar o sistema.
6. Reinicie o Steam Deck depois de aplicar ou reverter otimizações que alterem memória, GRUB ou kernel.

## Instalação pelo terminal

```bash
curl --fail --location --retry 3 \
  -o TurboDecky-x86_64.AppImage \
  https://github.com/zarpon/Turbo-Decky-/releases/download/Latest/TurboDecky-x86_64.AppImage
chmod +x TurboDecky-x86_64.AppImage
./TurboDecky-x86_64.AppImage
```

## Verificar a integridade do download

```bash
curl --fail --location --retry 3 \
  -O https://github.com/zarpon/Turbo-Decky-/releases/download/Latest/TurboDecky-x86_64.AppImage.sha256
sha256sum -c TurboDecky-x86_64.AppImage.sha256
```

O workflow do repositório recompila, testa e publica automaticamente o AppImage e seu SHA-256 na Release `Latest` após alterações aprovadas na branch `main`.

## Persistência após reiniciar

As configurações aplicadas são persistentes em uma reinicialização normal:

- sysctl em `/etc/sysctl.d/99-turbodecky.conf`;
- THP, KSM e MGLRU em `/etc/tmpfiles.d/99-turbodecky-memory.conf`;
- ZRAM em `/etc/systemd/zram-generator.conf.d/00-turbodecky.conf`;
- ZSWAP e parâmetros de kernel em `/etc/default/grub`;
- swapfile ZSWAP em `/etc/fstab`;
- regras udev, limites, variáveis de ambiente e estados systemd;
- SCX LAVD e `fstrim.timer` quando ativados.

Uma atualização do SteamOS pode substituir configurações, pacotes ou o kernel e exigir nova aplicação. A reversão restaura o snapshot capturado antes da primeira aplicação; a restauração do kernel é uma ação separada.

# Agradecimentos

Agradecemos a toda a comunidade Linux, especialmente desenvolvedores como o time do sdweak e cryoutilities que foram grande inspiração para esse projeto. 

Sinceros Agradecimentos á V10lator pelo desenvolvimento de seu Kernel Customizado para o Steam Deck.
