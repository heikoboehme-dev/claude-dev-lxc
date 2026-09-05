#!/usr/bin/env bash
# =============================================================================
#  Rezept: PHP und MariaDB
#
#  Installiert PHP mit den Erweiterungen, die klassische PHP-Anwendungen
#  brauchen, und eine lokale MariaDB. Legt bewusst keine Datenbank und keinen
#  Datenbankbenutzer an - das gehoert zum jeweiligen Projekt und dessen
#  eigenem Einrichtungsskript.
#
#  Aufruf:  bash provision/php-mariadb.sh
#           RECIPES=php-mariadb bash claude-dev.sh
#
#  Zusaetzliche Erweiterungen ueber PHP_EXTRA:
#           PHP_EXTRA="php-gd php-bcmath" bash provision/php-mariadb.sh
# =============================================================================
set -euo pipefail

HIER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HIER/lib.sh"

PHP_EXTRA="${PHP_EXTRA:-}"

msg "PHP und MariaDB"
# shellcheck disable=SC2086
pakete php-cli php-mysql php-mbstring php-curl php-xml php-zip \
       php-intl php-gd mariadb-server mariadb-client $PHP_EXTRA

systemctl enable --now mariadb >/dev/null 2>&1 || true
if dienst_laeuft mariadb mysql mariadbd; then
  info "MariaDB laeuft"
else
  warn "MariaDB laeuft nicht - 'systemctl status mariadb' pruefen"
fi

info "PHP $(php -r 'echo PHP_VERSION;')"

# Diese sechs braucht praktisch jede PHP-Anwendung; fehlt eine, ist die
# Maschine unbrauchbar und das soll hier auffallen, nicht spaeter im Projekt.
#
# Mit Wiederholung: direkt nach dem apt-Lauf legen die dpkg-Trigger die
# Modul-Verknuepfungen unter conf.d/ noch um. Trifft die Pruefung dieses
# Fenster, meldet 'php -m' eine gerade angefasste Erweiterung kurz als fehlend
# - beobachtet, mit je wechselnder Erweiterung. Deshalb bis zu fuenfmal mit
# einer Sekunde Pause, bevor der Abbruch als echter Befund gilt. 'php -m' wird
# je Versuch nur einmal aufgerufen und das Ergebnis durchsucht.
NOETIG="pdo_mysql fileinfo mbstring openssl curl json"
for versuch in 1 2 3 4 5; do
  GELADEN="$(php -m 2>/dev/null)"
  FEHLEND=""
  for ext in $NOETIG; do
    grep -qix "$ext" <<<"$GELADEN" || FEHLEND="$FEHLEND $ext"
  done
  [[ -z "$FEHLEND" ]] && break
  [[ $versuch -lt 5 ]] && sleep 1
done
[[ -z "$FEHLEND" ]] || die "PHP-Erweiterungen fehlen dauerhaft:$FEHLEND"
info "alle ueblichen PHP-Erweiterungen vorhanden"

cat <<ENDE

  Datenbank fuer ein Projekt anlegen - MariaDB authentifiziert root ueber den
  Unix-Socket, deshalb genuegt sudo ohne Passwort:

      sudo mysql <<'SQL'
      CREATE DATABASE \`meinprojekt_dev\`
          CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
      CREATE USER 'meinprojekt'@'localhost' IDENTIFIED BY '<passwort>';
      GRANT ALL PRIVILEGES ON \`meinprojekt_dev\`.* TO 'meinprojekt'@'localhost';
      SQL

  Bringt das Projekt ein eigenes Einrichtungsskript mit, hat dieses Vorrang.

ENDE
