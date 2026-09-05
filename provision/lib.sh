#!/usr/bin/env bash
# =============================================================================
#  Gemeinsame Helfer fuer base.sh und die Rezepte.
#
#  Wird von jedem Provisioning-Skript eingebunden und laedt dabei die
#  Einstellungen, die claude-dev.sh nach /root/claude-dev.env gelegt hat.
#  Wer ein Skript von Hand aufruft, kann dieselben Werte per Umgebung setzen.
# =============================================================================

# Eigenstaendig nutzbar: Vorgaben setzen, falls das einbindende Skript nichts
# vorgibt (sonst bricht 'set -u' ab).
ENVDATEI="${ENVDATEI:-/root/claude-dev.env}"
if [[ -f "$ENVDATEI" ]]; then
  # shellcheck disable=SC1090
  source "$ENVDATEI"
fi

CT_USER="${CT_USER:-dev}"
TZ_NAME="${TZ_NAME:-Europe/Berlin}"
LANG_NAME="${LANG_NAME:-de_DE.UTF-8}"
GIT_NAME="${GIT_NAME:-}"
GIT_EMAIL="${GIT_EMAIL:-}"
HEIM="/home/$CT_USER"

export DEBIAN_FRONTEND=noninteractive

msg()  { printf '\n\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '  › %s\n' "$*"; }
warn() { printf '\033[1;33m  › %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mFehler:\033[0m %s\n' "$*" >&2; exit 1; }

# Fuehrt einen Befehl als Arbeitsbenutzer aus. Login-Shell, damit die von
# Installern ergaenzten PATH-Eintraege in ~/.bashrc auch greifen.
als_user() { su - "$CT_USER" -s /bin/bash -c "$1"; }

# Prueft, ob ein systemd-Dienst wirklich laeuft. Der Dienstname heisst je nach
# Distribution ssh oder sshd - deshalb mehrere Kandidaten.
dienst_laeuft() {
  local d
  for d in "$@"; do
    systemctl is-active --quiet "$d" 2>/dev/null && return 0
  done
  return 1
}

# Installiert Pakete leise und bricht mit klarer Meldung ab, statt eine
# halbfertige Maschine zu hinterlassen.
pakete() {
  apt-get install -y -qq "$@" >/dev/null \
    || die "Paketinstallation fehlgeschlagen: $*"
}

[[ $EUID -eq 0 ]] || die "Bitte als root im Container ausfuehren."
