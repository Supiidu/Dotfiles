# Dotfiles — Debian Sid + Niri

Bootstrap interativo para reinstalar um **Debian 13 Minimal** e migrar para **Debian Sid**, usando **systemd**, **APT**, **Niri Git** (pacotes Dux Labs) e **SDDM**.

Sem Nix, AUR, GNOME Shell, Plasma Desktop ou DMS. A shell temporária é Waybar + Mako + Fuzzel; a futura shell em Rust/Amane será trabalhada separadamente.

## Instalação

1. Instale o Debian 13 Netinst **sem ambiente gráfico**, com rede funcionando.
2. Instale e configure `sudo` para seu usuário e instale `git`.
3. Como usuário normal, abra um terminal/TTY e execute:

```bash
git clone https://github.com/Supiidu/Dotfiles.git && bash Dotfiles/configure-system.sh
```

O script usa uma interface em terminal com **Whiptail**, instalada apenas depois de desabilitar os pacotes recomendados no APT. Ele pede confirmação para migrar ao Sid, confiar no repositório externo e instalar o desktop.

**Leia antes de aceitar:** mudar do Stable para o Sid é um upgrade de distribuição e não tem rollback automático. Faça backup dos dados pessoais. O script guarda as fontes APT anteriores em `/var/backups`, mas isso **não** é um backup completo do sistema.

## O que automatiza

- Grava `APT::Install-Recommends "false"` e `APT::Install-Suggests "false"` **antes de instalar outros pacotes**.
- Arquiva as fontes APT existentes, configura só o repositório Debian Sid e simula `apt-get full-upgrade` antes de pedir autorização.
- Instala a chave GPG do [Dux Labs](https://duxlabs.dev/docs/repo/) exclusivamente para o repositório `Debian_Unstable`, com `Signed-By`.
- Simula a instalação do Niri Git, SDDM e demais pacotes sem recomendações; bloqueia instalação de GNOME Shell, Plasma Desktop ou DMS.
- Instala Mesa Intel, NetworkManager com backend iwd, PipeWire, TLP, terminal Alacritty, Fuzzel, Waybar, Mako, portais Wayland e ferramentas básicas.
- Cria uma configuração Niri com **Super+R** (Fuzzel), **Super+D** (largura da coluna), **Super+T** (Alacritty), **Super+Q** (fechar) e **Super+Shift+E** (sair).
- Valida o arquivo KDL e a sessão Wayland antes de habilitar o SDDM.

O script **não reinicia automaticamente**, não particiona discos, não desativa a NVIDIA por software e não instala Amane/Suzuha por enquanto.

Ao terminar, reinicie com:

```bash
systemctl reboot
```

Logs e simulações: `~/.local/state/supiidu-bootstrap/`.

## Se a migração apresentar um erro

Não reinicie imediatamente. Leia o log e a simulação, verifique o APT com `sudo dpkg --audit` e corrija qualquer pacote incompleto antes de seguir. **Não force** remoções de pacotes essenciais. O script interrompe a execução se a simulação mostrar remoções críticas.

## Referências

- [Debian Unstable — instalação recomendada](https://wiki.debian.org/DebianUnstable)
- [Dux Labs — repositório Debian Unstable](https://duxlabs.dev/docs/repo/)
- [Niri — primeiros passos](https://niri-wm.github.io/niri/Getting-Started.html)
