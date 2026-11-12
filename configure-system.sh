#!/usr/bin/env bash
# Arch Linux + Niri + Suzuha/Amane + TLP + Obsidian
# Execute como usuario comum depois do primeiro login no Niri.
set -Eeuo pipefail

if [[ "$EUID" -eq 0 ]]; then
  echo "Execute como usuario comum, SEM sudo." >&2
  exit 1
fi
if ! command -v pacman >/dev/null || ! command -v niri >/dev/null; then
  echo "Este instalador exige Arch Linux com Niri ja instalado." >&2
  exit 1
fi
mkdir -p "$HOME/.local/state"
LOG="$HOME/.local/state/configure-system.log"
exec > >(tee -a "$LOG") 2>&1
trap 'code=$?; echo "ERRO na linha $LINENO: $BASH_COMMAND (codigo $code)"; echo "Veja $LOG"' ERR
echo "== Arch + Niri + Amane/Suzuha + TLP + Obsidian =="
sudo -v

echo "[1/7] Gerenciadores de energia conflitantes"
for svc in power-profiles-daemon.service tuned.service tuned-ppd.service; do
  sudo systemctl disable --now "$svc" >/dev/null 2>&1 || true
done
for pkg in power-profiles-daemon tuned-ppd; do
  if pacman -Qq "$pkg" >/dev/null 2>&1; then
    sudo pacman -Rns --noconfirm "$pkg"
  fi
done

echo "[2/7] Pacotes oficiais e dependencias"
sudo pacman -Syu --needed --noconfirm \
  git base-devel rustup python pkgconf curl niri \
  obsidian tlp tlp-pd upower pciutils \
  wayland libxkbcommon fontconfig freetype2 expat \
  vulkan-icd-loader libpulse pam \
  cava ffmpeg libnotify brightnessctl \
  ttf-jetbrains-mono-nerd ttf-nerd-fonts-symbols ttf-material-icons

echo "[3/7] TLP: balanced na tomada e power-saver na bateria"
sudo install -d -m 755 /etc/tlp.d
printf '%s\n' \
  '# Lenovo IdeaPad Gaming 3i: perfis automaticos' \
  'TLP_AUTO_SWITCH=1' \
  'TLP_PROFILE_AC=BAL' \
  'TLP_PROFILE_BAT=SAV' \
  | sudo tee /etc/tlp.d/90-ideapad-battery.conf >/dev/null
sudo systemctl enable --now tlp.service
sudo systemctl enable --now tlp-pd.service
sudo tlp start
sudo tlp-stat -s || true

echo "[4/7] Rust e Amane"
export PATH="$HOME/.cargo/bin:$PATH"
rustup toolchain install stable --profile minimal
rustup default stable
mkdir -p "$HOME/.local/src"
AMANE_SRC="$HOME/.local/src/amane"
if [[ -d "$AMANE_SRC/.git" ]]; then
  git -C "$AMANE_SRC" pull --ff-only
elif [[ ! -e "$AMANE_SRC" ]]; then
  git clone --depth 1 https://github.com/MystiaFin/amane.git "$AMANE_SRC"
else
  echo "Nao vou sobrescrever $AMANE_SRC" >&2
  exit 1
fi
(cd "$AMANE_SRC" && ./install.sh)
AMANE="$HOME/.cargo/bin/amane"
test -x "$AMANE"

echo "[5/7] Fontes do Suzuha"
FONT_DIR="$HOME/.local/share/fonts/suzuha"
mkdir -p "$FONT_DIR"
download_font() {
  local url="$1" name="$2"
  if [[ ! -s "$FONT_DIR/$name" ]]; then
    if ! curl -fLsS --retry 2 --connect-timeout 12 --max-time 60 \
        -o "$FONT_DIR/$name" "$url"; then
      rm -f "$FONT_DIR/$name"
      echo "AVISO: nao baixei $name. Pode faltar algum glifo."
    fi
  fi
}
download_font "https://raw.githubusercontent.com/google/fonts/main/ofl/poppins/Poppins-Regular.ttf" "Poppins-Regular.ttf"
download_font "https://raw.githubusercontent.com/google/fonts/main/ofl/poppins/Poppins-SemiBold.ttf" "Poppins-SemiBold.ttf"
download_font "https://cdnjs.cloudflare.com/ajax/libs/MaterialDesign-Webfont/7.4.47/fonts/materialdesignicons-webfont.ttf" "materialdesignicons-webfont.ttf"
fc-cache -f "$FONT_DIR" || true

echo "[6/7] Suzuha: clone e compilacao"
SUZUHA="$HOME/.config/amane"
mkdir -p "$HOME/.config"
if [[ -d "$SUZUHA/.git" ]]; then
  origin="$(git -C "$SUZUHA" remote get-url origin)"
  if [[ "$origin" != *"MystiaFin/suzuha"* ]]; then
    echo "Repositorio existente diferente em $SUZUHA; nao sobrescrevi." >&2
    exit 1
  fi
  git -C "$SUZUHA" pull --ff-only
elif [[ ! -e "$SUZUHA" ]]; then
  git clone --depth 1 https://github.com/MystiaFin/suzuha.git "$SUZUHA"
else
  echo "$SUZUHA ja existe; faca backup antes de continuar." >&2
  exit 1
fi
"$AMANE" compile

echo "[7/7] Keybinds Niri e autostart, com backup"
NIRI_CONFIG="$HOME/.config/niri/config.kdl"
mkdir -p "$(dirname "$NIRI_CONFIG")"
if [[ ! -f "$NIRI_CONFIG" ]]; then
  if [[ -f /etc/niri/config.kdl ]]; then
    cp /etc/niri/config.kdl "$NIRI_CONFIG"
  else
    echo "config.kdl nao encontrado. Nenhum atalho foi editado." >&2
    exit 1
  fi
fi
BACKUP="$NIRI_CONFIG.bak-$(date +%Y%m%d-%H%M%S)"
cp -a "$NIRI_CONFIG" "$BACKUP"
python3 - "$NIRI_CONFIG" "$AMANE" <<'PY'
import json
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
amane = sys.argv[2]
data = path.read_text(encoding="utf-8")
start = re.search(r"(?m)^[ \t]*binds[ \t]*\{[ \t]*$", data)
if not start:
    raise SystemExit("Bloco binds nao encontrado; config preservado.")
def find_closing_brace(text, pos):
    depth = 1
    in_string = False
    escaped = False
    in_comment = False
    for i in range(pos, len(text)):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if in_comment:
            if ch == "\n":
                in_comment = False
            continue
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            continue
        if ch == "/" and nxt == "/":
            in_comment = True
            continue
        if ch == '"':
            in_string = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return i
    raise SystemExit("Bloco binds incompleto; config preservado.")

a = start.end()
b = find_closing_brace(data, a)
body = data[a:b]
# Remove os conflitos de Mod/Super+D e Mod/Super+R do Niri padrao.
body = re.sub(
    r"(?m)^[ \t]*(?:Mod|Super)\+(?:D|R)(?=[ \t])[^\n]*\{[^\n]*\}[ \t]*(?://[^\n]*)?\n?",
    "", body
)
if re.search(r"(?m)^[ \t]*(?:Mod|Super)\+(?:D|R)(?=[ \t])", body):
    raise SystemExit("Atalho multiline conflitante detectado; nao foi editado.")
new = (
    "\n    // Adicionado por configure-system.sh\n"
    f'    Super+R hotkey-overlay-title="Suzuha launcher" '
    f'{{ spawn {json.dumps(amane)} "ipc" "call" "launcher" "toggle"; }}\n'
    '    Super+D hotkey-overlay-title="Resize coluna" '
    '{ switch-preset-column-width; }\n'
)
data = data[:a] + new + body + data[b:]
# Evita duas barras, preservando a linha anterior como comentario.
data = re.sub(
    r'(?m)^([ \t]*)(spawn-at-startup[ \t]+"waybar"[^\n]*)$',
    r'\1// Desativado (Suzuha substitui Waybar): \2', data
)
# Nao duplica autostart ao reexecutar.
data = re.sub(
    r'(?m)^[ \t]*spawn-at-startup[ \t]+"[^"\n]*/\.cargo/bin/amane"[ \t]+"run"[ \t]*\n?',
    "", data
)
data += f'\nspawn-at-startup {json.dumps(amane)} "run"\n'
path.write_text(data, encoding="utf-8")
PY
if ! niri validate --config "$NIRI_CONFIG"; then
  echo "Config invalido; restaurando backup $BACKUP"
  cp -a "$BACKUP" "$NIRI_CONFIG"
  exit 1
fi

echo "=== PRONTO ==="
echo "Super+R: launcher integrado do Suzuha"
echo "Super+D: alterna larguras da coluna (resize Niri)"
echo "Obsidian: abra com 'obsidian'"
echo "TLP: BAL na tomada; SAV na bateria"
echo "Backup do Niri: $BACKUP"
if printenv NIRI_SOCKET >/dev/null 2>&1; then
  "$AMANE" run || echo "Amane ja esta rodando ou precisa de uma nova sessao."
else
  echo "Entre na sessao Niri para iniciar a shell automaticamente."
fi
echo "A GTX 1650 nao foi desativada: verifique seu runtime suspend depois."
lspci | grep -Ei 'vga|3d|display' || true
echo "Log: $LOG"
