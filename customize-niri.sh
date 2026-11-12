#!/usr/bin/env bash
# Visual leve para Niri + Suzuha, sem perder Super+R / Super+D.
# Execute como usuario normal, DEPOIS de concluir configure-system.sh.
set -Eeuo pipefail

if [[ "$EUID" -eq 0 ]]; then
  echo "ERRO: execute com seu usuario, nao como root." >&2
  exit 1
fi
if ! command -v niri >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "ERRO: Niri e Python 3 sao necessarios." >&2
  exit 1
fi

MAIN="$HOME/.config/niri/config.kdl"
BINDS="$MAIN"
AMANE="$HOME/.cargo/bin/amane"
if [[ ! -f "$MAIN" ]]; then
  echo "ERRO: $MAIN nao existe. Nenhum arquivo alterado." >&2
  exit 1
fi
if [[ ! -x "$AMANE" ]]; then
  echo "ERRO: Amane nao instalado em $AMANE. Termine configure-system.sh antes." >&2
  exit 1
fi
if grep -Eq '^[[:space:]]*include[[:space:]]+"dms/binds.kdl"' "$MAIN"; then
  BINDS="$HOME/.config/niri/dms/binds.kdl"
fi
if [[ ! -f "$BINDS" ]]; then
  echo "ERRO: arquivo de atalhos nao encontrado: $BINDS" >&2
  exit 1
fi

BACKUP="$HOME/.local/state/niri-appearance/backups/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$BACKUP"
cp -a "$MAIN" "$BACKUP/config.kdl"
if [[ "$BINDS" != "$MAIN" ]]; then
  cp -a "$BINDS" "$BACKUP/binds.kdl"
fi

echo "[1/3] Ajustando cantos, espacamento, overlay e teclas..."
if ! python3 - "$MAIN" "$BINDS" "$AMANE" <<'PY'
from pathlib import Path
import json
import re
import sys

main_file = Path(sys.argv[1])
bind_file = Path(sys.argv[2])
amane = sys.argv[3]
main = main_file.read_text(encoding="utf-8")
binds = bind_file.read_text(encoding="utf-8")

def close_brace(s, start):
    depth = 1
    quoted = escaped = comment = False
    for i in range(start, len(s)):
        ch = s[i]
        nxt = s[i+1] if i+1 < len(s) else ""
        if comment:
            if ch == "\n": comment = False
            continue
        if quoted:
            if escaped: escaped = False
            elif ch == "\\": escaped = True
            elif ch == '"': quoted = False
            continue
        if ch == "/" and nxt == "/": comment = True; continue
        if ch == '"': quoted = True
        elif ch == "{": depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0: return i
    raise ValueError("Bloco KDL com chaves incompletas")

# Os arquivos gerados pelo DMS nao devem receber as mudancas visuais.
# O bloco fica no config.kdl, DEPOIS dos includes de layout do DMS.
begin = "// BEGIN customize-niri-appearance"
end = "// END customize-niri-appearance"
pattern = r"(?ms)^" + re.escape(begin) + r"\n.*?^" + re.escape(end) + r"\n?"
main = re.sub(pattern, "", main)

# Desativa somente o pop-up de ajuda dos atalhos na inicializacao.
overlay = re.search(r"(?m)^[ \t]*hotkey-overlay[ \t]*\{", main)
if overlay:
    close = close_brace(main, overlay.end())
    if not re.search(r"(?m)^[ \t]*skip-at-startup\b", main[overlay.end():close]):
        main = main[:overlay.end()] + "\n    skip-at-startup\n" + main[overlay.end():]
else:
    main += "\nhotkey-overlay {\n    skip-at-startup\n}\n"

# 18px arredondado, espacamento moderado, sem blur ou sombras adicionais.
main += (
    "\n" + begin + "\n"
    "// Aparencia com consumo grafico leve\n"
    "layout {\n"
    "    gaps 10\n"
    "}\n"
    "window-rule {\n"
    "    geometry-corner-radius 18\n"
    "    clip-to-geometry true\n"
    "}\n"
    + end + "\n"
)

# Altera SOMENTE Mod+R e Mod+D dentro do bloco ativo de binds.
m = re.search(r"(?m)^[ \t]*binds[ \t]*\{", binds)
if not m:
    raise ValueError("Bloco binds nao encontrado")
start, finish = m.end(), close_brace(binds, m.end())
section = binds[start:finish]
lines = section.splitlines(keepends=True)
filtered = []
i = 0
while i < len(lines):
    line = lines[i]
    if re.match(r"^\s*(?:Mod|Super)\+(?:R|D)(?=\s)", line):
        # Alcanca tambem a acao quando o bloco tem varias linhas.
        block = line
        depth = line.count("{") - line.count("}")
        i += 1
        while depth > 0 and i < len(lines):
            block += lines[i]
            depth += lines[i].count("{") - lines[i].count("}")
            i += 1
        continue
    filtered.append(line)
    i += 1
new_keys = (
    "\n    // Super+R e Super+D (preservados pelo customize-niri.sh)\n"
    f'    Mod+R hotkey-overlay-title="Suzuha Launcher" '
    f'{{ spawn {json.dumps(amane)} "ipc" "call" "launcher" "toggle"; }}\n'
    '    Mod+D hotkey-overlay-title="Resize Column" '
    '{ switch-preset-column-width; }\n'
)
binds = binds[:start] + new_keys + "".join(filtered) + binds[finish:]

# Se os dois arquivos forem o mesmo, evita sobrescrever edicoes.
if main_file == bind_file:
    m2 = re.search(r"(?m)^[ \t]*binds[ \t]*\{", main)
    if not m2:
        raise ValueError("Bloco binds desapareceu do config.kdl")
    z = close_brace(main, m2.end())
    main = main[:m2.end()] + new_keys + "".join(filtered) + main[z:]
    main_file.write_text(main, encoding="utf-8")
else:
    bind_file.write_text(binds, encoding="utf-8")
    main_file.write_text(main, encoding="utf-8")
PY
then
  echo "ERRO ao editar; restaurando backup."
  cp -a "$BACKUP/config.kdl" "$MAIN"
  if [[ "$BINDS" != "$MAIN" ]]; then cp -a "$BACKUP/binds.kdl" "$BINDS"; fi
  exit 1
fi

echo "[2/3] Validando sintaxe do Niri..."
if ! niri validate --config "$MAIN"; then
  echo "ERRO: validacao falhou. Restaurando os arquivos originais..."
  cp -a "$BACKUP/config.kdl" "$MAIN"
  if [[ "$BINDS" != "$MAIN" ]]; then cp -a "$BACKUP/binds.kdl" "$BINDS"; fi
  exit 1
fi

echo "[3/3] Desativando OSD do DMS (somente se Suzuha estiver compilado)..."
# O Niri nao tem OSD de volume proprio; esse tipo de pop-up vem de uma shell.
# Suzuha nao precisa do servico DMS. Nao desativamos se a compilacao nao terminou.
if [[ -x "$HOME/.cache/amane/amane-shell" ]] && grep -q 'spawn-at-startup.*amane.*run' "$MAIN"; then
  DROPIN="$HOME/.config/systemd/user/niri.service.d/dms.conf"
  if [[ -f "$DROPIN" ]] && grep -q 'Wants=dms.service' "$DROPIN"; then
    cp -a "$DROPIN" "$BACKUP/dms.conf"
    rm "$DROPIN"
  fi
  USER_UNIT="$HOME/.config/systemd/user/dms.service"
  if [[ ! -e "$USER_UNIT" && ! -L "$USER_UNIT" ]]; then
    mkdir -p "$(dirname "$USER_UNIT")"
    ln -s /dev/null "$USER_UNIT"
  fi
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  echo "DMS bloqueado para a proxima sessao (sem mexer no Suzuha)."
else
  echo "Nao mexi no DMS: shell Suzuha ainda nao foi confirmada como pronta."
fi

echo "========== PERSONALIZACAO PRONTA =========="
echo "Cantos arredondados: 18px | espacamento: 10px"
echo "Ajuda de hotkeys escondida na inicializacao"
echo "Super+R: launcher Suzuha | Super+D: resize coluna"
echo "Nenhum pacote foi instalado ou removido."
echo "Backup: $BACKUP"
echo "Se o Niri estiver aberto, a mudanca de config normalmente e aplicada automaticamente."
