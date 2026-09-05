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
  OFFEN+=("SSH-Schluessel nach $HEIM/.ssh/authorized_keys legen, dann sshd haerten")
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
printf '\n  Offen bleibt:\n\n'
n=1
for punkt in ${OFFEN[@]+"${OFFEN[@]}"}; do
  printf '  %d) %s\n\n' "$n" "$punkt"
  n=$((n + 1))
done
