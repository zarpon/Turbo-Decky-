# Turbo-Decky-
Script de otimização do SteamOs 

O script deve funcionar em qualquer aparelho que utiliza o SteamOs e também distribuições baseadas em arch linux. 

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

O Turbo Decky agora permite a instalação do Kernel Customizado Charcoal.
Esse kernel foi desenvolvido por V10lator. Todos os creditos, bem como os agradecimentos são para o desenvolvedor.
Atenção, testei a compatibilidade do Kernel Apenas com a versão 3.7.* do SteamOs, se você está no canal principal e usa o SteamOs 3.8 ou 3.9 não Garanto que irá funcionar. Instale por sua conta e Risco!

Esse é o changelog da versão mais recente do Kernel:

Add WiFi patches from OpenWRT
Change maximum allowed CPU frequency on Steam Deck from 3.5 to 4.2 GHz (as requested on Reddit)
Add NTSYNC (from CachyOS)
Add wait on multiple futexes opcode for fsync (from tkg)
Add ADIOS
Add Binder module (for Waydroid)
Switch sheduling frequency to 1000 Hz
Switch default DRM scheduling policy to round-robin
Optimize kernel with -O3 (from tkg)
Optimize for Zen 2 (from Gentoo)
Build with LLVM + LTO
Build-in various always needed modules for LTO to shine even more
Update zstd (from CachyOS)
Disable a lot of debugging
Disable CPU mitigations
Disable sound input validation
Disable various unneeded things (open a bug report in case something you need is missing)
Switch CPU IDLE sheduler
Add some Clear Linux patches (from tkg)
Small fixes (from Gentoo)
Fix dkms with LLVM clang (from CachyOS)
Add ryzen_smu

Esse é o github do charcoal Kernel: https://github.com/V10lator/linux-charcoal


Tudo isso é feito automaticamente — basta escolher a opção e deixar o script trabalhar.

# Como Instalar e Executar

1 - Vá para o modo desktop no Steam Deck;

2 - Baixe o arquivo TurboDecky.desktop da página de Releases;

https://github.com/zarpon/Turbo-Decky-/releases/download/Latest/TurboDecky.desktop

3 - Clique e execute o arquivo.

4 - Insira a Senha de super usuário e siga as instruções no menu.

5 - Reinicie o Steam Deck!

Atenção! , é necessário reaplicar as otimizações sempre que a versão do SteamOs atualizar. 

# Agradecimentos

Agradecemos a toda a comunidade Linux, especialmente desenvolvedores como o time do sdweak e cryoutilities que foram grande inspiração para esse projeto. 

Sinceros Agradecimentos á V10lator pelo desenvolvimento de seu Kernel Customizado para o Steam Deck.

# Contribua se puder

Caso goste do resultado obtido com esse aplicativo, considere fazer uma doação de qualquer valor para o pix jorgezarpon@msn.com.

# Video com benchmark comparativo no canal do YouTube, se inscreva! 

https://youtu.be/lf2oYmHiYD8?si=Uo1esBPQuwG6jMG9
