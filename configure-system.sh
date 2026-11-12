#!/usr/bin/env bash
# configure-system.sh — Arch Linux + Niri + Amane/Suzuha + TLP + Obsidian
# Versao 2: limpeza segura, instalacao upstream, compatibilidade com mixer antigo.
set -Eeuo pipefail

if [[ "$EUID" -eq 0 ]]; then
  echo "ERRO: entre como seu usuario normal; nao execute como root." >&2
  exit 1
fi
if ! command -v pacman >/dev/null || ! command -v niri >/dev/null; then
  echo "ERRO: Arch Linux com Niri instalado e necessario." >&2
  exit 1
fi

STATE="$HOME/.local/state/configure-system"
BACKUP="$STATE/backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$STATE" "$BACKUP"
LOG="$STATE/install.log"
exec > >(tee -a "$LOG") 2>&1
trap 'rc=$?; echo "[ERRO] Linha $LINENO, codigo $rc. Log: $LOG" >&2' ERR
export PATH="$HOME/.cargo/bin:$PATH"

echo "== configure-system v2 =="
echo "Backup: $BACKUP"
echo "Log: $LOG"
echo "Nunca apaga o Arch, seus arquivos pessoais ou o Niri."
sudo -v

# Pacotes mantidos: nao desinstala bibliotecas que outros aplicativos usam.
echo "[1/7] Instalando dependencias oficiais"
for svc in power-profiles-daemon.service tuned.service tuned-ppd.service; do
  sudo systemctl disable --now "$svc" >/dev/null 2>&1 || true
done
# Usamos TLP sem tlp-pd para evitar disputa de perfil com outros servicos.
sudo pacman -Syu --needed --noconfirm \
  git base-devel rustup gcc pkgconf curl python \
  wayland libxkbcommon fontconfig freetype2 expat \
  vulkan-icd-loader libpulse pam \
  obsidian firefox tlp \
  brightnessctl playerctl cava ffmpeg libnotify \
  ttf-jetbrains-mono-nerd ttf-nerd-fonts-symbols

echo "[2/7] TLP: balanced na tomada, power-saver na bateria"
sudo install -d -m 755 /etc/tlp.d
printf '%s\n' \
  '# Perfil do Lenovo IdeaPad Gaming 3i configurado por configure-system.sh' \
  'TLP_AUTO_SWITCH=1' \
  'TLP_PROFILE_AC=BAL' \
  'TLP_PROFILE_BAT=SAV' \
  | sudo tee /etc/tlp.d/90-ideapad-battery.conf >/dev/null
sudo systemctl enable tlp.service
sudo tlp start
sudo tlp-stat -s || true

echo "[3/7] Limpando Amane/Suzuha da instalacao anterior"
AMANE_SRC="$HOME/.local/src/amane"
SUZUHA="$HOME/.config/amane"
for spec in "amane:$AMANE_SRC:MystiaFin/amane" "suzuha:$SUZUHA:MystiaFin/suzuha"; do
  name="$(printf '%s' "$spec" | cut -d: -f1)"
  folder="$(printf '%s' "$spec" | cut -d: -f2)"
  expected="$(printf '%s' "$spec" | cut -d: -f3)"
  if [[ -e "$folder" ]]; then
    if [[ ! -d "$folder/.git" ]]; then
      echo "ERRO: $folder nao e um clone Git; nao vou apagar arquivos desconhecidos." >&2
      exit 1
    fi
    origin="$(git -C "$folder" remote get-url origin)"
    if [[ "$origin" != *"$expected"* ]]; then
      echo "ERRO: origem inesperada ($origin). Preservando $folder." >&2
      exit 1
    fi
    mv "$folder" "$BACKUP/$name-previous"
    echo "Instalacao anterior guardada em $BACKUP/$name-previous"
  fi
done

# Estes diretorios sao especificos da antiga instalacao Amane.
if [[ -d "$HOME/.cache/amane" ]]; then
  mv "$HOME/.cache/amane" "$BACKUP/amane-cache-previous"
fi
if [[ -d "$HOME/.local/share/fonts/suzuha" ]]; then
  mv "$HOME/.local/share/fonts/suzuha" "$BACKUP/suzuha-fonts-previous"
fi
if [[ -f "$HOME/.local/state/amane/config-path" ]]; then
  mv "$HOME/.local/state/amane/config-path" "$BACKUP/amane-config-path-previous"
fi
# A versao anterior podia ter mascarado o DMS mesmo sem compilar Suzuha.
DMS_MASK="$HOME/.config/systemd/user/dms.service"
if [[ -L "$DMS_MASK" ]] && [[ "$(readlink "$DMS_MASK")" == /dev/null ]]; then
  rm "$DMS_MASK"
fi
if command -v cargo >/dev/null; then
  cargo uninstall amane-cli 2>/dev/null || true
fi
if [[ -f "$HOME/.cargo/bin/amane" ]]; then
  mv "$HOME/.cargo/bin/amane" "$BACKUP/amane-cli-previous"
fi

echo "[4/7] Instalando Amane do GitHub via instalador oficial"
rustup toolchain install stable --profile minimal
rustup default stable
mkdir -p "$HOME/.local/src"
git clone --depth 1 https://github.com/MystiaFin/amane.git "$AMANE_SRC"
(cd "$AMANE_SRC" && ./install.sh)
AMANE="$HOME/.cargo/bin/amane"
if [[ ! -x "$AMANE" ]]; then
  echo "ERRO: CLI do Amane nao foi criado em $AMANE" >&2
  exit 1
fi

echo "[5/7] Instalando Suzuha e corrigindo API de mixer incompativel"
mkdir -p "$HOME/.config"
git clone --depth 1 https://github.com/MystiaFin/suzuha.git "$SUZUHA"
if [[ ! -f "$SUZUHA/src/mixer.rs" ]]; then
  echo "ERRO: estrutura inesperada do Suzuha; parei sem alterar o Niri." >&2
  exit 1
fi
cp "$SUZUHA/src/mixer.rs" "$BACKUP/mixer-original.rs"
# Na versao atual do Amane nao existe AudioApp nem Audio::apps().
# A shell inteira pode compilar sem esse painel: preserva os nomes que o launcher usa.
if grep -q 'AudioApp' "$SUZUHA/src/mixer.rs"; then
  cat > "$SUZUHA/src/mixer.rs" <<'RUST'
pub const MIXER_ICON: &str = "\u{f1543}";
pub fn open() {}
pub fn ipc(_: &[String]) -> String {
    String::from("O mixer por aplicativo esta indisponivel nesta versao")
}
RUST
  echo "Compatibilidade: mixer por aplicativo temporariamente desativado."
fi
echo "Compilando Suzuha (sem inicializar a shell no TTY)"
"$AMANE" compile

echo "[6/7] Fontes Poppins e Material Design (nao bloqueantes)"
FONT_DIR="$HOME/.local/share/fonts/suzuha"
mkdir -p "$FONT_DIR"
download_font() {
  if ! curl -fLsS --retry 1 --connect-timeout 10 --max-time 30 \
      "$1" -o "$FONT_DIR/$2"; then
    rm -f "$FONT_DIR/$2"
    echo "[AVISO] Nao foi possivel baixar a fonte $2"
  fi
}
download_font 'https://raw.githubusercontent.com/google/fonts/main/ofl/poppins/Poppins%5Bwght%5D.ttf' 'Poppins-Variable.ttf'
download_font 'https://cdnjs.cloudflare.com/ajax/libs/MaterialDesign-Webfont/7.4.47/fonts/materialdesignicons-webfont.ttf' 'materialdesignicons-webfont.ttf'
fc-cache -f "$FONT_DIR" || true

echo "[7/7] Configurando Niri, atalhos e startup APOS compilacao"
MAIN="$HOME/.config/niri/config.kdl"
if [[ ! -f "$MAIN" ]]; then
  echo "ERRO: $MAIN nao existe; nao alterei a sessao grafica." >&2
  exit 1
fi
cp -a "$MAIN" "$BACKUP/niri-config-before.kdl"
BINDS="$MAIN"
if grep -Eq '^[[:space:]]*include[[:space:]]+"dms/binds.kdl"' "$MAIN"; then
  BINDS="$HOME/.config/niri/dms/binds.kdl"
fi
if [[ ! -f "$BINDS" ]]; then
  echo "ERRO: arquivo de atalhos do Niri nao encontrado: $BINDS" >&2
  exit 1
fi
if [[ "$BINDS" != "$MAIN" ]]; then
  cp -a "$BINDS" "$BACKUP/niri-binds-before.kdl"
fi

python3 - "$MAIN" "$BINDS" "$AMANE" <<'PY'
import pathlib
import re
import sys
import json

main_path, binds_path = map(pathlib.Path, sys.argv[1:3])
amane = sys.argv[3]
main = main_path.read_text(encoding="utf-8")
binds = binds_path.read_text(encoding="utf-8")
m = re.search(r"(?m)^[ \t]*binds[ \t]*\{[ \t]*$", binds)
if m is None:
    raise SystemExit("Nenhum bloco 'binds {' encontrado; parei sem salvar.")

def end_brace(content, pos):
    depth, quote, escape, comment = 1, False, False, False
    for i in range(pos, len(content)):
        ch = content[i]
        nx = content[i + 1] if i + 1 < len(content) else ""
        if comment:
            if ch == "\n": comment = False
            continue
        if quote:
            if escape: escape = False
            elif ch == "\\": escape = True
            elif ch == '"': quote = False
            continue
        if ch == "/" and nx == "/": comment = True; continue
        if ch == '"': quote = True
        elif ch == "{": depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0: return i
    raise ValueError("Chaves KDL incompletas")

a = m.end()
b = end_brace(binds, a)
body = binds[a:b]
# Os binds do perfil Niri+DMS sao linhas ou blocos de varias linhas.
# Removemos so binds que disputam Mod+D/R ou dependem do DMS removido.
lines = body.splitlines(keepends=True)
kept, i = [], 0
while i < len(lines):
    line = lines[i]
    if re.match(r"^\s*(?://|$)", line):
        kept.append(line)
        i += 1
        continue
    if not re.match(r"^\s*[A-Za-z0-9_+/-]+(?:\s|$)", line) or "{" not in line:
        kept.append(line)
        i += 1
        continue
    node = line
    i += 1
    depth = line.count("{") - line.count("}")
    while depth > 0 and i < len(lines):
        node += lines[i]
        depth += lines[i].count("{") - lines[i].count("}")
        i += 1
    if re.match(r"^\s*(Mod|Super)\+(D|R)(?=\s)", node):
        continue
    if binds_path != main_path and 'spawn "dms"' in node:
        continue
    kept.append(node)

extras = (
    '\n    // configure-system.sh v2\n'
    f'    Mod+R hotkey-overlay-title="Suzuha Launcher" '
    f'{{ spawn {json.dumps(amane)} "ipc" "call" "launcher" "toggle"; }}\n'
    '    Mod+D hotkey-overlay-title="Resize Column" '
    '{ switch-preset-column-width; }\n'
)
if binds_path != main_path:
    extras += (
        '    Mod+Alt+L { spawn ' + json.dumps(amane) + ' "ipc" "call" "lock"; }\n'
        '    Mod+Comma { spawn ' + json.dumps(amane) + ' "ipc" "call" "settings"; }\n'
        '    XF86AudioRaiseVolume { spawn "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "3%+"; }\n'
        '    XF86AudioLowerVolume { spawn "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "3%-"; }\n'
        '    XF86AudioMute { spawn "wpctl" "set-mute" "@DEFAULT_AUDIO_SINK@" "toggle"; }\n'
        '    XF86AudioMicMute { spawn "wpctl" "set-mute" "@DEFAULT_AUDIO_SOURCE@" "toggle"; }\n'
        '    XF86MonBrightnessUp { spawn "brightnessctl" "set" "+5%"; }\n'
        '    XF86MonBrightnessDown { spawn "brightnessctl" "set" "5%-"; }\n'
        '    XF86AudioPlay { spawn "playerctl" "play-pause"; }\n'
        '    XF86AudioPause { spawn "playerctl" "play-pause"; }\n'
        '    XF86AudioNext { spawn "playerctl" "next"; }\n'
        '    XF86AudioPrev { spawn "playerctl" "previous"; }\n'
    )
binds = binds[:a] + extras + "".join(kept) + binds[b:]
# Remove linhas de autostart de execucoes anteriores, sem apagar outros programas.
main = re.sub(r'(?m)^\s*spawn-at-startup\s+"[^"\n]*/\.cargo/bin/amane"\s+"run"\s*$', "", main)
main = re.sub(r'(?m)^(\s*spawn-at-startup\s+"waybar"[^ \n]*)$', r'// \1', main)
main += '\n// Suzuha — autostart apos compilar\n'
main += 'spawn-at-startup ' + json.dumps(amane) + ' "run"\n'
binds_path.write_text(binds, encoding="utf-8")
main_path.write_text(main, encoding="utf-8")
PY

if ! niri validate --config "$MAIN"; then
  echo "[ERRO] Niri rejeitou a configuracao; restaurando arquivos."
  cp "$BACKUP/niri-config-before.kdl" "$MAIN"
  if [[ "$BINDS" != "$MAIN" ]]; then
    cp "$BACKUP/niri-binds-before.kdl" "$BINDS"
  fi
  exit 1
fi

# Niri+DMS inicia DMS pela dependencia niri.service.d/dms.conf, NAO pela Waybar.
if [[ "$BINDS" != "$MAIN" ]]; then
  DROPIN="$HOME/.config/systemd/user/niri.service.d/dms.conf"
  if [[ -f "$DROPIN" ]]; then
    cp -a "$DROPIN" "$BACKUP/niri-dms.conf.previous"
    if grep -q 'Wants=dms.service' "$DROPIN"; then
      rm "$DROPIN"
    fi
  fi
  mkdir -p "$HOME/.config/systemd/user"
  if [[ ! -e "$DMS_MASK" && ! -L "$DMS_MASK" ]]; then
    ln -s /dev/null "$DMS_MASK"
  fi
  systemctl --user daemon-reload >/dev/null 2>&1 || true
fi

# As instalacoes anteriores foram movidas apenas para permitir recuperacao se falhasse.
# A instalacao nova compilou e o Niri validou: agora podemos apagar os artefatos antigos.
for old in amane-cache-previous amane-previous suzuha-previous suzuha-fonts-previous amane-cli-previous amane-config-path-previous; do
  if [[ -e "$BACKUP/$old" ]]; then
    rm -rf -- "$BACKUP/$old"
  fi
done
if [[ ! -x "$HOME/.cache/amane/amane-shell" ]]; then
  echo "[AVISO] Nao localizei o executavel da shell no cache (confira o log do amane)."
fi

echo "========== PRONTO =========="
echo "Amane compilado: $HOME/.cache/amane/amane-shell"
echo "Super+R = Suzuha launcher | Super+D = resize por preset"
echo "Autostart configurado. Entre novamente na sessao Niri."
echo "TLP: BAL (tomada), SAV (bateria); Obsidian e Firefox instalados."
echo "Backups: $BACKUP"
echo "Log: $LOG"
echo "OBS: Mixer por aplicativo foi desativado (API incompatível no upstream)."
