#!/usr/bin/env bash
# =============================================================================
#  claude-dev-lxc - Bootstrap
#
#  Holt das Projekt auf die Maschine und startet danach den Teil, der dorthin
#  gehoert. Ein Befehl, alles Weitere laeuft allein.
#
#  Der Modus wird erkannt, nicht geraten:
#      pct vorhanden  → Proxmox-Node: legt einen Container an (claude-dev.sh)
#      pct fehlt      → Maschine selbst: richtet sie ein (provision/base.sh)
#
#  Damit funktioniert derselbe Befehl auf dem Node und in einem frisch
#  angelegten, noch leeren LXC.
#
#  Oeffentliches Repository:
#      bash -c "$(curl -fsSL https://raw.githubusercontent.com/heikoboehme-dev/claude-dev-lxc/main/bootstrap.sh)"
#
#  Privates Repository (GitHub-Token mit Leserecht auf Inhalte):
#      export GITHUB_TOKEN=ghp_xxx
#      bash -c "$(curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" \
#        -H 'Accept: application/vnd.github.raw' \
#        https://api.github.com/repos/heikoboehme-dev/claude-dev-lxc/contents/bootstrap.sh)"
#
#  Aus einem eigenen Git-Server:
#      REPO_URL=https://git.intern/claude-dev-lxc.git bash bootstrap.sh
#
#  Umgebungsvariablen:
#      GITHUB_REPO   OWNER/REPO   (Vorgabe: heikoboehme-dev/claude-dev-lxc)
#      GITHUB_TOKEN  Token fuer private Repositories
#      REPO_URL      vollstaendige Git-URL; ueberschreibt GITHUB_REPO/TOKEN
#      REPO_REF      Branch oder Tag   (Vorgabe: main)
#      SRC_DIR       Zielverzeichnis   (Vorgabe: /opt/claude-dev-lxc)
#      MODE          auto|node|container   (Vorgabe: auto)
#      RECIPES       Kommaliste der Sprachstacks, z.B. "php-mariadb,node"
#
#  Alle weiteren Einstellungen nimmt claude-dev.sh entgegen - siehe README.
# =============================================================================
set -euo pipefail

GITHUB_REPO="${GITHUB_REPO:-heikoboehme-dev/claude-dev-lxc}"
REPO_REF="${REPO_REF:-main}"
SRC_DIR="${SRC_DIR:-/opt/claude-dev-lxc}"
MODE="${MODE:-auto}"
RECIPES="${RECIPES:-}"

msg()  { printf '\n\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '  › %s\n' "$*"; }
die()  { printf '\n\033[1;31mFehler:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Bitte als root ausfuehren (sudo)."

# Bei 'curl | bash' ist die Standardeingabe das Skript selbst - Rueckfragen
# wuerden dann kommentarlos die Vorgaben nehmen, ohne dass es jemand merkt.
# Lieber abbrechen und die richtige Form nennen.
if [[ ! -t 0 && "${NONINTERACTIVE:-0}" != "1" ]]; then
  die "Keine Konsole fuer Rueckfragen verfuegbar.

  So aufrufen (beachte die Klammern - nicht 'curl | bash'):
      bash -c \"\$(curl -fsSL <URL>)\"

  Oder bewusst ohne Rueckfragen, dann gelten ueberall die Vorgaben:
      NONINTERACTIVE=1 ..."
fi

# --------------------------------------------------------- Modus bestimmen ---
case "$MODE" in
  auto)
    if command -v pct >/dev/null 2>&1; then MODE="node"; else MODE="container"; fi
    ;;
  node|container) ;;
  *) die "MODE muss auto, node oder container sein (war: $MODE)." ;;
esac

if [[ "$MODE" == "node" ]]; then
  msg "claude-dev-lxc - Bootstrap (Proxmox-Node: Container anlegen)"
else
  msg "claude-dev-lxc - Bootstrap (diese Maschine einrichten)"
  info "kein pct gefunden - es wird kein Container angelegt, sondern dieser hier eingerichtet"
fi

# --------------------------------------------------------- Grundwerkzeuge ---
if ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  info "git/curl werden nachinstalliert"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq git curl ca-certificates >/dev/null
fi

# ------------------------------------------------------------ Quelle waehlen ---
if [[ -n "${REPO_URL:-}" ]]; then
  CLONE_URL="$REPO_URL"
  info "Quelle: $REPO_URL"
elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
  CLONE_URL="https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPO}.git"
  info "Quelle: github.com/${GITHUB_REPO} (mit Token)"
else
  CLONE_URL="https://github.com/${GITHUB_REPO}.git"
  info "Quelle: github.com/${GITHUB_REPO} (oeffentlich)"
fi

# ------------------------------------------------------- Holen/Aktualisieren ---
msg "Projekt holen (Branch: $REPO_REF)"
if [[ -d "$SRC_DIR/.git" ]]; then
  git -C "$SRC_DIR" remote set-url origin "$CLONE_URL"
  git -C "$SRC_DIR" fetch --quiet --depth 1 origin "$REPO_REF" \
    || die "Konnte nicht aktualisieren. Zugangsdaten und Netzwerk pruefen."
  git -C "$SRC_DIR" checkout --quiet -B "$REPO_REF" "origin/$REPO_REF"
  info "aktualisiert: $SRC_DIR"
else
  rm -rf "$SRC_DIR"
  if ! git clone --quiet --depth 1 --branch "$REPO_REF" "$CLONE_URL" "$SRC_DIR" 2>/dev/null; then
    die "Klonen fehlgeschlagen.
  - Privates Repository? Dann GITHUB_TOKEN setzen (Recht: Inhalte lesen).
  - Eigener Git-Server? Dann REPO_URL setzen.
  - Repository und Branch korrekt? ($GITHUB_REPO, $REPO_REF)"
  fi
  info "geklont nach $SRC_DIR"
fi

# Token nicht dauerhaft in der Git-Konfiguration stehen lassen.
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  git -C "$SRC_DIR" remote set-url origin "https://github.com/${GITHUB_REPO}.git"
  info "Token aus der Repository-Konfiguration entfernt"
fi

[[ -f "$SRC_DIR/claude-dev.sh"        ]] || die "claude-dev.sh nicht gefunden - falsches Repository?"
[[ -f "$SRC_DIR/provision/base.sh"    ]] || die "provision/base.sh nicht gefunden - falsches Repository?"

# ----------------------------------------------------------------- Starten ---
if [[ "$MODE" == "node" ]]; then
  msg "Container anlegen"
  exec bash "$SRC_DIR/claude-dev.sh"
fi

# Container-Modus: diese Maschine einrichten, danach die gewaehlten Rezepte.
msg "Grundsystem einrichten"
bash "$SRC_DIR/provision/base.sh"

if [[ -n "$RECIPES" ]]; then
  IFS=',' read -r -a REZEPTE <<< "$RECIPES"
  for r in "${REZEPTE[@]}"; do
    [[ -f "$SRC_DIR/provision/$r.sh" && "$r" != "base" && "$r" != "lib" ]] \
      || die "Rezept '$r' gibt es nicht. Vorhanden: $(cd "$SRC_DIR/provision" && ls *.sh | grep -vE '^(base|lib)\.sh$' | sed 's/\.sh$//' | tr '\n' ' ')"
    msg "Rezept: $r"
    bash "$SRC_DIR/provision/$r.sh"
  done
fi

msg "Fertig"
