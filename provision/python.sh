#!/usr/bin/env bash
# =============================================================================
#  Rezept: Python
#
#  Installiert Python samt venv und pipx. Bewusst kein 'pip install' ausserhalb
#  einer virtuellen Umgebung: Debian verwaltet seine Python-Pakete selbst und
#  wehrt systemweite pip-Installationen seit Debian 12 ab (PEP 668). Werkzeuge
#  kommen deshalb ueber pipx, Projektabhaengigkeiten in ein venv je Projekt.
#
#  Aufruf:  bash provision/python.sh
#           RECIPES=python bash claude-dev.sh
# =============================================================================
set -euo pipefail

HIER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HIER/lib.sh"

msg "Python"
pakete python3 python3-venv python3-pip python3-dev pipx build-essential

info "$(python3 --version)"

# pipx legt seine Programme nach ~/.local/bin - der Pfad gehoert in die
# Anmeldeumgebung, sonst findet die Shell sie nicht.
als_user 'pipx ensurepath' >/dev/null 2>&1 || true
info "pipx eingerichtet (Werkzeuge: pipx install <paket>)"

cat <<'ENDE'

  Virtuelle Umgebung je Projekt:

      cd ~/projekte/meinprojekt
      python3 -m venv .venv
      source .venv/bin/activate
      pip install -r requirements.txt

ENDE
