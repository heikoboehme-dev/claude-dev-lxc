#!/usr/bin/env bash
# =============================================================================
#  Grundsystem des Entwicklungscontainers
#
#  Laeuft IM Container als root. Normalerweise wird es von claude-dev.sh
#  hineingereicht; von Hand geht auch, etwa um eine bestehende Debian-Maschine
#  nachzuruesten:
#      CT_USER=dev bash provision/base.sh
#
#  Richtet ein: Systemaktualisierung, Sprache und Zeitzone, Arbeitsbenutzer mit
#  sudo, SSH nur per Schluessel, Grundwerkzeuge, Git samt eigenem Schluessel
#  fuer GitHub, und Claude Code.
#
#  Kein Projekt und kein Sprachstack - die kommen als Rezepte daneben.
#
#  Jeder Schritt legt nur an, was fehlt. Ein zweiter Lauf aendert nichts an
#  bereits Eingerichtetem.
# =============================================================================
set -euo pipefail

HIER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HIER/lib.sh"

OFFEN=()   # sammelt, was am Ende noch von Hand zu tun ist

# ------------------------------------------------------------ Grundsystem ---
msg "Grundsystem"
info "Paketquellen und Aktualisierung - das dauert ein paar Minuten ohne Ausgabe"
apt-get update -qq
apt-get -y -qq full-upgrade >/dev/null
info "System aktuell"

pakete sudo git curl ca-certificates ripgrep unzip tmux jq \
       less locales openssh-server
info "Grundwerkzeuge installiert"

# Sprache und Zeitzone. Eine Maschine mit C-Locale zeigt bei allem, was durch
# Umlaute laeuft, Fehler an, die keine sind.
if ! grep -qE "^${LANG_NAME}" /etc/locale.gen 2>/dev/null; then
  sed -i "s/^# *${LANG_NAME}/${LANG_NAME}/; s/^# *en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
  locale-gen >/dev/null
fi
update-locale LANG="$LANG_NAME" >/dev/null
ln -sf "/usr/share/zoneinfo/$TZ_NAME" /etc/localtime
printf '%s\n' "$TZ_NAME" > /etc/timezone
info "Locale $LANG_NAME, Zeitzone $TZ_NAME"

# --------------------------------------------------------------- Benutzer ---
msg "Arbeitsbenutzer $CT_USER"
if id -u "$CT_USER" >/dev/null 2>&1; then
  info "besteht bereits"
else
  # Ohne Passwort: hereingekommen wird per SSH-Schluessel, und sshd wird
  # weiter unten auf genau das eingeschraenkt.
  adduser --disabled-password --gecos "" "$CT_USER" >/dev/null
  info "angelegt"
fi
usermod -aG sudo "$CT_USER"

# sudo ohne Passwortabfrage. Das Konto hat bewusst kein Passwort, mit dem es
# sich bestaetigen koennte. Vertretbar, weil der Zugang ausschliesslich ueber
# den SSH-Schluessel laeuft und die Maschine eine Wegwerf-Entwicklungsumgebung
# mit Snapshot dahinter ist. Wer das nicht will, setzt hinterher ein Passwort
# (passwd $CT_USER) und loescht /etc/sudoers.d/90-$CT_USER.
SUDOERS="/etc/sudoers.d/90-$CT_USER"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$CT_USER" > "$SUDOERS"
chmod 0440 "$SUDOERS"
visudo -cf "$SUDOERS" >/dev/null || { rm -f "$SUDOERS"; die "sudoers-Eintrag fehlerhaft, wurde zurueckgenommen."; }
info "sudo ohne Passwortabfrage eingerichtet"

# Schluessel, die pct create nach /root gelegt hat, an den Benutzer
# weiterreichen. Zusammengefuehrt statt ersetzt: ein spaeter von Hand
# ergaenzter Schluessel soll einen zweiten Lauf ueberleben.
if [[ -s /root/.ssh/authorized_keys ]]; then
  install -d -m 0700 -o "$CT_USER" -g "$CT_USER" "$HEIM/.ssh"
  ZIEL="$HEIM/.ssh/authorized_keys"
  TMPKEYS="$(mktemp)"
  cat /root/.ssh/authorized_keys "$ZIEL" 2>/dev/null | grep -E '^(ssh-|ecdsa-|sk-)' | sort -u > "$TMPKEYS"
  install -m 0600 -o "$CT_USER" -g "$CT_USER" "$TMPKEYS" "$ZIEL"
  rm -f "$TMPKEYS"
  info "SSH-Schluessel uebernommen ($(wc -l < "$ZIEL" | tr -d ' ') Stueck)"
fi

# --------------------------------------------------------------------- SSH ---
msg "SSH"
systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || true
if dienst_laeuft ssh sshd; then
  info "Dienst laeuft"
else
  warn "SSH-Dienst laeuft nicht"
  OFFEN+=("SSH pruefen: systemctl status ssh")
fi

# Fehlt noch ein Schluessel und sitzt jemand an der Konsole, wird er hier
# durchgefuehrt statt vertroestet: Schluessel einfuegen, das Skript prueft,
# schreibt und haertet direkt im Anschluss. Der Node-Weg (pct create) fuellt
# authorized_keys automatisch, dann erscheint diese Abfrage gar nicht.
if [[ ! -s "$HEIM/.ssh/authorized_keys" && -t 0 && "${NONINTERACTIVE:-0}" != "1" ]]; then
  msg "SSH-Schluessel hinterlegen"
  info "Auf dem Arbeitsplatz in einem zweiten Terminal anzeigen und kopieren:"
  info "    cat ~/.ssh/id_ed25519.pub 2>/dev/null || cat ~/.ssh/id_rsa.pub"
  info "Die ausgegebene Zeile hier einfuegen. Leere Eingabe ueberspringt den Schritt."
  while true; do
    printf '\n'
    ZEILE=""
    read -r -p "  Oeffentlicher Schluessel: " ZEILE || break
    if [[ -z "$ZEILE" ]]; then
      break
    fi
    if [[ "$ZEILE" =~ ^(ssh-|ecdsa-|sk-)[A-Za-z0-9@.-]*[[:space:]] ]]; then
      install -d -m 0700 -o "$CT_USER" -g "$CT_USER" "$HEIM/.ssh"
      printf '%s\n' "$ZEILE" >> "$HEIM/.ssh/authorized_keys"
      chown "$CT_USER:$CT_USER" "$HEIM/.ssh/authorized_keys"
      chmod 0600 "$HEIM/.ssh/authorized_keys"
      info "uebernommen ($(wc -l < "$HEIM/.ssh/authorized_keys" | tr -d ' ') Schluessel insgesamt)"
      info "weiteren Schluessel einfuegen oder mit leerer Eingabe fortfahren"
    else
      warn "Das sieht nicht nach einem oeffentlichen Schluessel aus - erwartet wird eine Zeile, die mit ssh-, ecdsa- oder sk- beginnt (die .pub-Datei, nie die private)."
    fi
  done
fi

if [[ -s "$HEIM/.ssh/authorized_keys" ]]; then
  # Erst haerten, wenn ein Schluessel wirklich hinterlegt ist. Sonst waere der
  # Container nur noch ueber 'pct enter' vom Node aus erreichbar.
  install -d -m 0755 /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/10-claude-dev.conf <<'CONF'
# Von claude-dev-lxc/provision/base.sh erzeugt.
# Anmeldung ausschliesslich per Schluessel, kein root ueber SSH.
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
CONF
  if sshd -t 2>/dev/null; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    if dienst_laeuft ssh sshd; then
      info "nur Schluessel-Anmeldung, root gesperrt"
    else
      warn "Dienst nach dem Neuladen nicht aktiv"
      OFFEN+=("SSH pruefen: systemctl status ssh")
    fi
  else
    rm -f /etc/ssh/sshd_config.d/10-claude-dev.conf
    warn "sshd-Konfiguration waere fehlerhaft gewesen - Haertung zurueckgenommen"
    OFFEN+=("sshd von Hand haerten: PermitRootLogin no, PasswordAuthentication no")
  fi
else
  warn "kein SSH-Schluessel hinterlegt - Haertung uebersprungen"
  # Ein fertiges Mac-Kommando kann hier nicht stehen: um vom Arbeitsplatz aus
  # etwas in den Container zu schreiben, braeuchte es bereits einen Login -
  # den gibt es ohne Schluessel gerade nicht. Deshalb der kuerzeste Weg von
  # Hand, mit allem vorausgefuellt, was diese Maschine ueber sich weiss.
  CT_IP_HINWEIS="$(hostname -I 2>/dev/null | awk '{print $1}')"
  OFFEN+=("Deinen SSH-Schluessel hinterlegen, damit die Anmeldung als '$CT_USER' klappt.

     Auf dem Arbeitsplatz die oeffentliche Haelfte anzeigen und kopieren:
         cat ~/.ssh/id_ed25519.pub 2>/dev/null || cat ~/.ssh/id_rsa.pub

     Die ausgegebene Zeile hier im Container statt DEINE_ZEILE einsetzen:
         install -d -m700 -o $CT_USER -g $CT_USER $HEIM/.ssh && echo 'DEINE_ZEILE' >> $HEIM/.ssh/authorized_keys && chown $CT_USER:$CT_USER $HEIM/.ssh/authorized_keys && chmod 600 $HEIM/.ssh/authorized_keys && echo OK

     Test vom Arbeitsplatz:
         ssh $CT_USER@${CT_IP_HINWEIS:-<container-ip>}

     Danach die sshd-Haertung nachholen (dieses Skript erneut laufen lassen -
     es haertet, sobald ein Schluessel liegt).")
fi

# --------------------------------------------------------------------- Git ---
msg "Git"
if [[ -n "$GIT_NAME" ]]; then
  als_user "git config --global user.name $(printf '%q' "$GIT_NAME")"
  info "user.name gesetzt"
fi
if [[ -n "$GIT_EMAIL" ]]; then
  als_user "git config --global user.email $(printf '%q' "$GIT_EMAIL")"
  info "user.email gesetzt"
fi

# Eigener Schluessel des Containers fuer GitHub. Bewusst kein Token-basiertes
# Klonen im Skript: ein Token muesste durch Prozessliste und Dateien wandern,
# der Schluessel bleibt dagegen im Container und wird einmal eingetragen.
if als_user '[ -f "$HOME/.ssh/id_ed25519" ]'; then
  info "Schluessel fuer GitHub besteht bereits"
else
  als_user "ssh-keygen -t ed25519 -N '' -C $(printf '%q' "claude-dev-$(hostname)") -f \"\$HOME/.ssh/id_ed25519\"" >/dev/null
  info "Schluessel fuer GitHub erzeugt"
fi
als_user "mkdir -p \"\$HOME/projekte\""
GITHUB_KEY="$(als_user 'cat "$HOME/.ssh/id_ed25519.pub"')"
OFFEN+=("Diesen Schluessel bei GitHub eintragen (Settings → SSH and GPG keys):

      $GITHUB_KEY
")

# ------------------------------------------------------------- Claude Code ---
msg "Claude Code"
if als_user 'command -v claude >/dev/null 2>&1 || [ -x "$HOME/.local/bin/claude" ]'; then
  info "bereits installiert"
else
  als_user 'curl -fsSL https://claude.ai/install.sh | bash' >/dev/null \
    || die "Claude Code liess sich nicht installieren."
  info "installiert"
fi
VERSION="$(als_user 'claude --version 2>/dev/null || "$HOME/.local/bin/claude" --version 2>/dev/null' || true)"
if [[ -n "$VERSION" ]]; then
  info "$VERSION"
else
  warn "Version liess sich nicht ermitteln"
fi
OFFEN+=("Claude Code anmelden: 'claude' starten, angezeigte URL im Browser oeffnen")

# --------------------------------------------------------------- Abschluss ---
msg "Grundsystem fertig"

# Liegt ein Schluessel, ist der Weg vom Arbeitsplatz frei - dann gleich die
# fertigen Eintraege mitgeben, statt sie den Leser zusammensuchen zu lassen.
if [[ -s "$HEIM/.ssh/authorized_keys" ]]; then
  CT_IP_ANZEIGE="$(hostname -I 2>/dev/null | awk '{print $1}')"
  cat <<VERBINDUNG
  ------------------------------------------------------------------
  Verbindung vom Arbeitsplatz

  Diesen Befehl auf dem Arbeitsrechner ins Terminal einfuegen. Er legt
  ~/.ssh/config an, falls die Datei fehlt, und ergaenzt sonst nur den
  Eintrag - ein zweiter Aufruf aendert nichts:

      mkdir -p ~/.ssh && chmod 700 ~/.ssh && { grep -qs 'Host $(hostname)' ~/.ssh/config || printf '\nHost $(hostname)\n    HostName ${CT_IP_ANZEIGE:-<container-ip>}\n    User $CT_USER\n' >> ~/.ssh/config; } && chmod 600 ~/.ssh/config && echo OK

  Testen:      ssh $(hostname)

  VS Code anbinden - bei Remote-Arbeit teilt sich VS Code in die
  Oberflaeche (Arbeitsrechner) und die Arbeitshaelfte (dieser
  Container); Erweiterungen, die etwas tun sollen, gehoeren in die
  Arbeitshaelfte:

    1. Erweiterung "Remote - SSH" (Microsoft) installieren, falls
       sie fehlt.
    2. Cmd/Strg+Shift+P -> "Remote-SSH: Connect to Host"
       -> $(hostname). Im neuen Fenster steht unten links
       "SSH: $(hostname)" - erst dann weiter.
    3. In DIESEM Fenster die Erweiterungsansicht oeffnen
       (Puzzle-Symbol links, oder Cmd/Strg+Shift+X). Die Liste ist
       jetzt zweigeteilt: "Local - Installed" und
       "SSH: $(hostname) - Installed".
    4. Im lokalen Teil die Claude-Erweiterung suchen und auf ihrer
       Kachel den Knopf "Install in SSH: $(hostname)" druecken.
       Der Knopf existiert nur im verbundenen Fenster aus Schritt 2.
    5. Kontrolle: Claude erscheint im Abschnitt "SSH: $(hostname)".
       Ab jetzt laeuft alles, was Claude tut, in diesem Container.

  Einmalig statt Schritt 3-4, fuer alle kuenftigen Container: auf dem
  Arbeitsrechner in den VS-Code-Einstellungen unter
  "Remote.SSH: Default Extensions" den Eintrag
      anthropic.claude-code
  ergaenzen - dann installiert VS Code die Erweiterung bei der ersten
  Verbindung zu jedem Host von selbst. (Das kann kein Skript in diesem
  Container erledigen: die Erweiterung gehoert in den VS-Code-Server,
  und den legt erst die erste Verbindung an.)
  ------------------------------------------------------------------

VERBINDUNG
fi

# Die offenen Punkte kommen als LETZTES auf den Schirm - insbesondere der
# GitHub-Schluessel stand frueher davor und scrollte hinter den langen
# Verbindungshinweisen aus dem Blickfeld; genau so wurde er einmal uebersehen.
printf '\n  Offen bleibt - der Reihe nach:\n\n'
n=1
for punkt in ${OFFEN[@]+"${OFFEN[@]}"}; do
  printf '  %d) %s\n\n' "$n" "$punkt"
  n=$((n + 1))
done
