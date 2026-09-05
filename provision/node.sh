#!/usr/bin/env bash
# =============================================================================
#  Rezept: Node.js
#
#  Installiert Node.js und npm. Vorgabe ist das Paket aus Debian - das ist die
#  Fassung, die ohne fremde Paketquelle auskommt und fuer die meisten Projekte
#  genuegt.
#
#  Braucht ein Projekt eine neuere Fassung, holt NODE_MAJOR sie aus dem
#  NodeSource-Depot:
#      NODE_MAJOR=22 bash provision/node.sh
#
#  Aufruf:  bash provision/node.sh
#           RECIPES=node bash claude-dev.sh
# =============================================================================
set -euo pipefail

HIER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HIER/lib.sh"

NODE_MAJOR="${NODE_MAJOR:-}"

msg "Node.js"

if [[ -z "$NODE_MAJOR" ]]; then
  pakete nodejs npm
  info "aus den Debian-Paketquellen"
else
  [[ "$NODE_MAJOR" =~ ^[0-9]+$ ]] || die "NODE_MAJOR muss eine Zahl sein (war: $NODE_MAJOR)."
  pakete curl ca-certificates gnupg

  # Schluessel und Quelle getrennt ablegen statt apt-key: das ist seit Debian
  # 12 der vorgesehene Weg, und der Schluessel gilt dann nur fuer diese Quelle.
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg \
    || die "NodeSource-Schluessel liess sich nicht holen."
  chmod 0644 /usr/share/keyrings/nodesource.gpg
  printf 'deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_%s.x nodistro main\n' \
    "$NODE_MAJOR" > /etc/apt/sources.list.d/nodesource.list

  apt-get update -qq
  pakete nodejs
  info "aus dem NodeSource-Depot (Hauptversion $NODE_MAJOR)"
fi

command -v node >/dev/null 2>&1 || die "node ist nach der Installation nicht aufrufbar."
info "node $(node --version), npm $(npm --version 2>/dev/null || echo 'nicht vorhanden')"

# Globale Pakete ins Heimatverzeichnis, damit 'npm i -g' ohne sudo geht und
# nichts ausserhalb des Benutzers landet.
als_user 'mkdir -p "$HOME/.npm-global" && npm config set prefix "$HOME/.npm-global"'
if ! als_user 'grep -q ".npm-global/bin" "$HOME/.profile" 2>/dev/null'; then
  als_user 'printf "\n# npm-Pakete ohne sudo\nexport PATH=\"\$HOME/.npm-global/bin:\$PATH\"\n" >> "$HOME/.profile"'
fi
info "globale npm-Pakete ohne sudo (~/.npm-global)"
