#!/usr/bin/env bash
# Debian 13 Minimal -> Debian Sid + Niri Git, SDDM e ambiente leve.
# Rode como usuario normal depois de instalar sudo e git.
set -Eeuo pipefail
export LC_ALL=C
umask 022

STATE="$HOME/.local/state/supiidu-bootstrap"
mkdir -p "$STATE"
LOG="$STATE/run-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
trap 'code=$?; echo "[ERRO] Linha $LINENO, codigo $code. Log: $LOG" >&2' ERR
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { echo "[ERRO] $*" >&2; exit 1; }
ask() { whiptail --title "Supiidu | Debian Sid" --yesno "$1" 17 78; }

[[ $EUID -ne 0 ]] || die "Execute como seu usuario normal (sem sudo antes do bash)."
[[ -t 0 ]] || die "Abra este script em um terminal interativo."
command -v sudo >/dev/null || die "Instale e configure sudo antes."
command -v git >/dev/null || die "Instale git antes."
command -v apt-get >/dev/null || die "APT ausente."
. /etc/os-release
[[ $ID == debian ]] || die "Somente Debian."
[[ $VERSION_CODENAME == trixie || $VERSION_CODENAME == sid ]] || die "Esperava Debian Trixie ou Sid."
[[ $(dpkg --print-architecture) == amd64 ]] || die "Perfil testado apenas para amd64."
[[ $(ps -p 1 -o comm=) == systemd ]] || die "Precisa do systemd como init."

cat <<'BANNER'
===========================================================
         Debian Sid + Niri Git / Supiidu
===========================================================
- Sem Nix, AUR, GNOME Shell, Plasma Desktop ou DMS.
- Instala APT minimal, migra para Sid e configura Dux Labs.
- Instala SDDM, Mesa Intel, PipeWire, Niri e shell leve.
- Super+R launcher; Super+D redimensionar.
- Faz backup de fontes APT. Nao formata nem reinicia.
BANNER
echo "Sid pode quebrar durante transicoes de bibliotecas."
echo "O Dux Labs e um repositorio de terceiros e exige confianca na chave dele."
read -r -p "Digite INSTALAR para continuar (ou Ctrl+C): " OK
[[ $OK == INSTALAR ]] || die "Cancelado."
sudo -v

step "1/7 Desativar pacotes recomendados ANTES de instalar qualquer pacote"
printf '%s\n' 'APT::Install-Recommends "false";' 'APT::Install-Suggests "false";' |
  sudo tee /etc/apt/apt.conf.d/99-supiidu-no-recommends >/dev/null
sudo apt-get update
sudo env DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends install \
  whiptail curl gnupg ca-certificates

ask "Deseja migrar integralmente para Debian Sid?

Use um Debian Minimal recem-instalado; salve seus arquivos antes.
Os repositorios atuais serao arquivados. O upgrade nao tem rollback automatico." || die "Cancelado."

BACKUP="/var/backups/supiidu-sid-$(date +%Y%m%d-%H%M%S)"
sudo install -d -m 0700 "$BACKUP"
step "2/7 Repositorios oficiais Debian Sid (backup: $BACKUP)"
if [[ $VERSION_CODENAME != sid ]]; then
  if [[ -f /etc/apt/sources.list ]]; then
    sudo mv /etc/apt/sources.list "$BACKUP/sources.list"
  fi
  shopt -s nullglob
  for src in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    sudo mv "$src" "$BACKUP/$(basename "$src")"
  done
  shopt -u nullglob
  sudo tee /etc/apt/sources.list.d/debian-sid.sources >/dev/null <<'SID'
Types: deb
URIs: https://deb.debian.org/debian/
Suites: sid
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
SID
else
  if grep -RqsE '^Suites:[[:space:]]*(trixie|forky)' /etc/apt/sources.list.d 2>/dev/null; then
    die "Ha repositorios Stable/Testing no sistema Sid; revise as fontes manualmente."
  fi
fi

sudo apt-get update
SIM="$STATE/upgrade-preview.log"
sudo apt-get -s --no-install-recommends full-upgrade > "$SIM"
REMOVALS=$(grep -c '^Remv ' "$SIM" || true)
echo "Simulacao: $SIM | Remocoes: $REMOVALS"
grep '^Remv ' "$SIM" || true
if grep -Eq '^Remv (apt|bash|dpkg|sudo|systemd|systemd-sysv|linux-image-amd64|grub-pc|grub-efi-amd64|coreutils)([[:space:]]|$)' "$SIM"; then
  die "A simulacao remove componentes criticos. Nao executarei o upgrade."
fi
ask "Simulacao de full-upgrade concluida.

Pacotes previstos para remocao: $REMOVALS
Arquivo de revisao: $SIM

Voce aceita essas mudancas e autoriza o upgrade completo para Sid?" || die "Upgrade cancelado."
step "Migrando para Sid (nao interrompa o dpkg)"
sudo env DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends full-upgrade
sudo dpkg --audit
step "Migracao concluida."

step "3/7 Repositorio Dux Labs (Debian_Unstable)"
ask "Autoriza adicionar o repositorio de TERCEIROS Dux Labs para instalar niri-git?
Ele nao e mantido nem auditado pela equipe do Debian." || die "Repositorio Dux nao autorizado."

KEY="$(mktemp)"
GPGKEY="$(mktemp)"
trap 'rm -f "$KEY" "$GPGKEY"' EXIT
curl -fL --retry 3 --connect-timeout 15 \
  'https://download.opensuse.org/repositories/home:duxlabs-dev:dux-repo/Debian_Unstable/Release.key' \
  -o "$KEY"
gpg --batch --show-keys --with-fingerprint "$KEY"
ask "A impressao digital da chave apareceu no terminal.
Autoriza instalar esta chave no APT (Signed-By exclusivo do Dux Labs)?" || die "Chave rejeitada."
gpg --batch --yes --dearmor -o "$GPGKEY" "$KEY"
sudo install -d -m 0755 /etc/apt/keyrings
sudo install -m 0644 "$GPGKEY" /etc/apt/keyrings/duxlabs-sid.gpg
sudo tee /etc/apt/sources.list.d/duxlabs-sid.sources >/dev/null <<'DUX'
Types: deb
URIs: https://download.opensuse.org/repositories/home:/duxlabs-dev:/dux-repo/Debian_Unstable/
Suites: /
Signed-By: /etc/apt/keyrings/duxlabs-sid.gpg
DUX
rm -f "$KEY" "$GPGKEY"
trap - EXIT
sudo apt-get update
CANDIDATE=$(apt-cache policy niri-git | awk '/Candidate:/ {print $2; exit}')
[[ -n $CANDIDATE && $CANDIDATE != "(none)" ]] ||
  die "niri-git sem versao disponivel neste momento. Verifique o repo Dux."

step "4/7 Simulando Niri Git, SDDM e servicos essenciais"
PKGS=(
  niri-git sddm sddm-theme-debian-elarun
  alacritty fuzzel waybar mako-notifier swaylock
  dbus-user-session xdg-desktop-portal-gnome xdg-desktop-portal-gtk
  mesa-vulkan-drivers libgl1-mesa-dri libegl1 libgbm1 intel-media-va-driver
  network-manager iwd
  pipewire wireplumber pipewire-pulse pipewire-alsa pipewire-jack
  alsa-utils rtkit brightnessctl playerctl
  tlp neovim
)
DESKTOP_SIM="$STATE/desktop-preview.log"
sudo apt-get -s --no-install-recommends install "${PKGS[@]}" > "$DESKTOP_SIM"
if grep -Eq '^Inst (gnome-shell|gnome-session|plasma-desktop|plasma-workspace|gdm3|dms|dms-git)([[:space:]]|$)' "$DESKTOP_SIM"; then
  grep -E '^Inst (gnome-shell|gnome-session|plasma-desktop|plasma-workspace|gdm3|dms|dms-git)([[:space:]]|$)' "$DESKTOP_SIM" || true
  die "Um desktop completo seria instalado; interrompendo."
fi
if grep -q '^Remv ' "$DESKTOP_SIM"; then
  grep '^Remv ' "$DESKTOP_SIM"
  die "Ha remocoes imprevistas. Revise $DESKTOP_SIM."
fi
echo "Simulacao sem GNOME Shell, Plasma Desktop, DMS ou remocoes."
ask "Deseja instalar Niri Git + SDDM, driver Intel, rede, PipeWire, TLP e interface provisoria Waybar/Fuzzel?
As recomendacoes opcionais do APT continuam desativadas." || die "Instalacao de desktop cancelada."
sudo env DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends install "${PKGS[@]}"

step "5/7 NetworkManager + iwd, TLP e SDDM"
sudo install -d -m 0755 /etc/NetworkManager/conf.d
printf '%s\n' '[device]' 'wifi.backend=iwd' |
  sudo tee /etc/NetworkManager/conf.d/10-wifi-backend.conf >/dev/null
sudo systemctl enable NetworkManager.service
sudo systemctl enable tlp.service
echo "Nota: confira /etc/network/interfaces se Wi-Fi estiver gerenciado pelo ifupdown."

step "6/7 Configuracao Niri simples (sem shell pesada)"
mkdir -p "$HOME/.config/niri"
CONFIG="$HOME/.config/niri/config.kdl"
if [[ -e $CONFIG ]]; then
  cp -a "$CONFIG" "$STATE/config-before-$(date +%Y%m%d-%H%M%S).kdl"
fi
cat > "$CONFIG" <<'KDL'
// Niri + shell temporaria, pronta para ser substituida por Amane.
spawn-at-startup "waybar"
spawn-at-startup "mako"
layout { gaps 10 }
window-rule {
    geometry-corner-radius 10
    clip-to-geometry true
}
binds {
    Mod+Shift+Slash { show-hotkey-overlay; }
    Mod+T { spawn "alacritty"; }
    Mod+R { spawn "fuzzel"; }
    Mod+D { switch-preset-column-width; }
    Mod+Q { close-window; }
    Mod+Left { focus-column-left; }
    Mod+Right { focus-column-right; }
    Mod+Up { focus-window-up; }
    Mod+Down { focus-window-down; }
    Mod+Shift+Left { move-column-left; }
    Mod+Shift+Right { move-column-right; }
    Mod+Alt+L { spawn "swaylock"; }
    Mod+Shift+E { quit; }
    XF86AudioRaiseVolume { spawn "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "5%+"; }
    XF86AudioLowerVolume { spawn "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "5%-"; }
    XF86AudioMute { spawn "wpctl" "set-mute" "@DEFAULT_AUDIO_SINK@" "toggle"; }
    XF86MonBrightnessUp { spawn "brightnessctl" "set" "+5%"; }
    XF86MonBrightnessDown { spawn "brightnessctl" "set" "5%-"; }
}
KDL
niri --version
niri validate --config "$CONFIG" ||
  die "Niri nao validou a configuracao. SDDM ainda NAO foi habilitado."
if ! find /usr/share/wayland-sessions -maxdepth 1 -iname '*niri*.desktop' -print -quit 2>/dev/null | grep -q .; then
  die "Sessao Niri ausente em /usr/share/wayland-sessions: SDDM nao sera ativado."
fi
sudo systemctl enable sddm.service

step "7/7 Instalacao finalizada"
echo "Debian Sid + Niri Git + SDDM prontos!"
echo "Atalhos: Super+R launcher | Super+D resize | Super+T terminal."
echo "Shell provisoria: Waybar/Mako. Nenhum DMS instalado."
echo "APT sem recommends/suggests. Rede: NetworkManager + iwd."
echo "Reinicie manualmente quando quiser: systemctl reboot"
echo "Log: $LOG"
echo "Backup APT: $BACKUP"
echo "A GPU NVIDIA nao foi desativada por software; use iGPU-only na BIOS."
echo "Rust e Amane serao instalados em uma etapa posterior."
