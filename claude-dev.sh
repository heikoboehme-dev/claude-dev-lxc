#!/usr/bin/env bash
# =============================================================================
#  claude-dev-lxc - Entwicklungscontainer auf Proxmox anlegen
#
#  Legt auf einem Proxmox-Node einen unprivilegierten LXC-Container an, in dem
#  Claude Code laeuft, und richtet ihn ein. Das Ergebnis ist eine leere, aber
#  vollstaendig arbeitsfaehige Entwicklungsmaschine - kein Projekt ist darin
#  vorausgesetzt.
#
#  Sprachstacks kommen als Rezepte dazu (provision/<name>.sh) und werden ueber
#  RECIPES ausgewaehlt. Ohne Angabe wird nur das Grundsystem eingerichtet.
#
#  Auf einem Proxmox-Node als root ausfuehren:
#      bash claude-dev.sh
#      RECIPES=php-mariadb bash claude-dev.sh
#
#  Existiert die VMID bereits, wird kein neuer Container gebaut, sondern der
#  vorhandene erneut eingerichtet. Jeder Schritt legt nur an, was fehlt.
#
#  Umgebungsvariablen - alles optional, wonach nicht gefragt wird, hat eine
#  Vorgabe. Mit NONINTERACTIVE=1 laeuft es ohne jede Rueckfrage durch.
#
#      VMID              Container-ID             (Vorgabe: naechste freie)
#      CT_HOSTNAME       Hostname                 (Vorgabe: claude-dev)
#      STORAGE           Speicher fuer rootfs     (Vorgabe: geteilter, sonst
#                                                  der erste passende)
#      TEMPLATE_STORAGE  Speicher fuer Vorlagen   (Vorgabe: local, sonst der
#                                                  erste passende)
#      CORES MEMORY SWAP DISK                     (Vorgabe: 4 / 4096 / 1024 / 25)
#      BRIDGE            Netzwerkbruecke          (Vorgabe: vmbr0)
#      IP                CIDR oder "dhcp"         (Vorgabe: dhcp)
#      GATEWAY           nur bei fester IP
#      NAMESERVER        nur bei fester IP        (Vorgabe: Gateway)
#      CT_USER           Arbeitsbenutzer          (Vorgabe: dev)
#      SSH_PUBKEY        Datei oder Schluesseltext
#                        (Vorgabe: /root/.ssh/authorized_keys des Nodes)
#      GIT_NAME GIT_EMAIL   fuer git config im Container
#      RECIPES           Kommaliste, z.B. "php-mariadb,node"
#      TZ_NAME LANG_NAME    (Vorgabe: Europe/Berlin, de_DE.UTF-8)
#      NONINTERACTIVE=1  ohne Rueckfragen
# =============================================================================
set -euo pipefail

HIER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROVDIR="$HIER/provision"

# --------------------------------------------------------------- Ausgaben ---
msg()  { printf '\n\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '  › %s\n' "$*"; }
warn() { printf '\033[1;33m  › %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mFehler:\033[0m %s\n' "$*" >&2; exit 1; }

# Fuehrt einen langen Schritt sichtbar aus: Spinner, Sekundenzaehler, und im
# Fehlerfall die letzten Ausgabezeilen. Ohne das sieht ein zwei Minuten
# laufendes pveam download nach einem Absturz aus.
run_step() {
  local label="$1"; shift
  local logfile; logfile="$(mktemp)"
  local start=$SECONDS

  "$@" >"$logfile" 2>&1 &
  local pid=$!

  if [[ -t 1 ]]; then
    local frames='|/-\' i=0
    while kill -0 "$pid" 2>/dev/null; do
      i=$(( (i + 1) % 4 ))
      printf '\r  %s %s … %ds ' "${frames:$i:1}" "$label" "$((SECONDS - start))"
      sleep 0.2
    done
  else
    printf '  › %s … ' "$label"
  fi

  local rc=0
  wait "$pid" || rc=$?
  local dur=$((SECONDS - start))

  if [[ $rc -eq 0 ]]; then
    if [[ -t 1 ]]; then printf '\r  \033[1;32m✓\033[0m %s (%ds)%*s\n' "$label" "$dur" 12 ""
    else printf 'fertig (%ds)\n' "$dur"; fi
    rm -f "$logfile"
    return 0
  fi

  if [[ -t 1 ]]; then printf '\r  \033[1;31m✗\033[0m %s (%ds)%*s\n' "$label" "$dur" 12 ""
  else printf 'FEHLGESCHLAGEN (%ds)\n' "$dur"; fi
  printf '\n\033[1;33m--- Letzte Ausgabe ---\033[0m\n'
  tail -n 30 "$logfile"
  printf '\033[1;33m----------------------\033[0m\n'
  rm -f "$logfile"
  return $rc
}

# Fragt einen Wert ab, sofern er nicht schon per Umgebungsvariable feststeht.
# Ohne Terminal oder mit NONINTERACTIVE=1 gilt kommentarlos die Vorgabe.
NONINTERACTIVE="${NONINTERACTIVE:-0}"
[[ -t 0 ]] || NONINTERACTIVE=1

ask() {
  local var="$1" frage="$2" vorgabe="${3:-}" antwort=""
  if [[ -n "${!var:-}" ]]; then return 0; fi
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    printf -v "$var" '%s' "$vorgabe"
    return 0
  fi
  read -r -p "  $frage [$vorgabe]: " antwort || true
  printf -v "$var" '%s' "${antwort:-$vorgabe}"
}

# ---------------------------------------------------------- Vorbedingungen ---
[[ $EUID -eq 0 ]] || die "Bitte als root auf einem Proxmox-Node ausfuehren."
command -v pct   >/dev/null 2>&1 || die "pct nicht gefunden - dieses Skript laeuft auf dem Proxmox-Node, nicht im Container."
command -v pvesm >/dev/null 2>&1 || die "pvesm nicht gefunden - kein Proxmox-Node?"
[[ -f "$PROVDIR/base.sh" ]] || die "provision/base.sh fehlt neben diesem Skript ($PROVDIR).
  Das ganze Projektverzeichnis gehoert auf den Node, nicht nur claude-dev.sh."

msg "claude-dev-lxc - Entwicklungscontainer auf Proxmox"

# Im Cluster ist ein fehlendes Quorum der haeufigste Grund, warum pct create
# spaeter kommentarlos haengt. Lieber hier abbrechen als dort warten.
if command -v pvecm >/dev/null 2>&1 && pvecm status >/dev/null 2>&1; then
  if pvecm status 2>/dev/null | grep -qi 'Quorate:.*No'; then
    die "Der Cluster hat kein Quorum. Erst die Nodes wieder zusammenbringen."
  fi
  info "Node: $(hostname), Cluster mit Quorum"
else
  info "Node: $(hostname), Einzelinstallation ohne Cluster"
fi

# ------------------------------------------------------------- Rezeptwahl ---
RECIPES="${RECIPES:-}"
REZEPTE=()
if [[ -n "$RECIPES" ]]; then
  IFS=',' read -r -a REZEPTE <<< "$RECIPES"
  for r in "${REZEPTE[@]}"; do
    # base.sh und lib.sh sind keine Rezepte: das eine laeuft immer, das andere
    # wird nur eingebunden.
    [[ -f "$PROVDIR/$r.sh" && "$r" != "base" && "$r" != "lib" ]] \
      || die "Rezept '$r' gibt es nicht. Vorhanden: $(cd "$PROVDIR" && ls *.sh | grep -vE '^(base|lib)\.sh$' | sed 's/\.sh$//' | tr '\n' ' ')"
  done
  info "Rezepte: ${REZEPTE[*]}"
else
  info "Rezepte: keine - nur Grundsystem (mit RECIPES=... nachruestbar)"
fi

# ------------------------------------------------------------- Speicherwahl ---
# Ein Speicher taugt fuer rootfs nur mit Inhaltstyp "rootdir", fuer Vorlagen
# nur mit "vztmpl". Beides getrennt ermitteln statt "local-lvm" zu raten.
speicher_mit_inhalt() {
  pvesm status --content "$1" 2>/dev/null | awk 'NR > 1 && $3 == "active" { print $1 }'
}

ROOTDIR_KANDIDATEN="$(speicher_mit_inhalt rootdir || true)"
[[ -n "$ROOTDIR_KANDIDATEN" ]] || die "Kein aktiver Speicher mit Inhaltstyp 'rootdir' gefunden."
VZTMPL_KANDIDATEN="$(speicher_mit_inhalt vztmpl || true)"
[[ -n "$VZTMPL_KANDIDATEN" ]] || die "Kein aktiver Speicher mit Inhaltstyp 'vztmpl' gefunden."

# Geteilte Speicher zuerst anbieten: nur damit laesst sich der Container
# spaeter im laufenden Betrieb auf einen anderen Node schieben.
#
# Ausgewertet wird genau der Block des gesuchten Speichers. Ein einfaches
# grep mit Zeilenvorschub wuerde in den naechsten Block hineinlaufen und
# dessen "shared 1" faelschlich diesem hier zuschreiben.
speicher_ist_geteilt() {
  awk -v gesucht="$1" '
    /^[a-z]+:[[:space:]]/            { imblock = ($2 == gesucht) }
    imblock && /^[[:space:]]+shared[[:space:]]+1/ { gefunden = 1 }
    END                              { exit !gefunden }
  ' /etc/pve/storage.cfg 2>/dev/null
}

STORAGE_VORGABE=""
for s in $ROOTDIR_KANDIDATEN; do
  if speicher_ist_geteilt "$s"; then STORAGE_VORGABE="$s"; break; fi
done
[[ -n "$STORAGE_VORGABE" ]] || STORAGE_VORGABE="$(head -1 <<<"$ROOTDIR_KANDIDATEN")"

TEMPLATE_STORAGE_VORGABE="$(grep -Fx 'local' <<<"$VZTMPL_KANDIDATEN" || head -1 <<<"$VZTMPL_KANDIDATEN")"

# ----------------------------------------------------------- Einstellungen ---
msg "Einstellungen"
info "verfuegbar fuer rootfs: $(tr '\n' ' ' <<<"$ROOTDIR_KANDIDATEN")"

VMID_VORGABE="$(pvesh get /cluster/nextid 2>/dev/null || echo 210)"

ask VMID             "Container-ID"                 "$VMID_VORGABE"
ask CT_HOSTNAME      "Hostname"                     "claude-dev"
ask STORAGE          "Speicher fuer rootfs"         "$STORAGE_VORGABE"
ask TEMPLATE_STORAGE "Speicher fuer die Vorlage"    "$TEMPLATE_STORAGE_VORGABE"
ask CORES            "CPU-Kerne"                    "4"
ask MEMORY           "Arbeitsspeicher in MB"        "4096"
ask SWAP             "Swap in MB"                   "1024"
ask DISK             "Festplatte in GB"             "25"
ask BRIDGE           "Netzwerkbruecke"              "vmbr0"
ask IP               "IP als CIDR oder 'dhcp'"      "dhcp"
ask CT_USER          "Arbeitsbenutzer im Container" "dev"

[[ "$VMID" =~ ^[0-9]+$ ]] || die "VMID muss eine Zahl sein (war: $VMID)."
[[ "$DISK" =~ ^[0-9]+$ ]] || die "Festplattengroesse muss eine Zahl sein (war: $DISK)."
[[ "$CT_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Ungueltiger Benutzername: $CT_USER"

if [[ "$IP" != "dhcp" ]]; then
  [[ "$IP" =~ ^[0-9.]+/[0-9]+$ ]] || die "Feste IP bitte als CIDR angeben, z.B. 192.168.1.210/24 (war: $IP)."
  ask GATEWAY    "Gateway"    "${IP%.*}.1"
  ask NAMESERVER "DNS-Server" "$GATEWAY"
fi

grep -Fxq "$STORAGE" <<<"$ROOTDIR_KANDIDATEN" || die "Speicher '$STORAGE' taugt nicht fuer rootfs. Moeglich: $(tr '\n' ' ' <<<"$ROOTDIR_KANDIDATEN")"
grep -Fxq "$TEMPLATE_STORAGE" <<<"$VZTMPL_KANDIDATEN" || die "Speicher '$TEMPLATE_STORAGE' nimmt keine Vorlagen auf. Moeglich: $(tr '\n' ' ' <<<"$VZTMPL_KANDIDATEN")"

# ------------------------------------------------------------ SSH-Schluessel ---
# Ohne oeffentlichen Schluessel kaeme man nach dem Haerten von sshd nicht mehr
# hinein. Deshalb wird hier abgebrochen statt spaeter im Container.
SSH_PUBKEY="${SSH_PUBKEY:-/root/.ssh/authorized_keys}"
PUBKEY_DATEI="$(mktemp)"
ENVDATEI="$(mktemp)"
PROVTAR="$(mktemp --suffix=.tar.gz)"
trap 'rm -f "$PUBKEY_DATEI" "$ENVDATEI" "$PROVTAR"' EXIT

if [[ -f "$SSH_PUBKEY" ]]; then
  grep -E '^(ssh-|ecdsa-|sk-)' "$SSH_PUBKEY" > "$PUBKEY_DATEI" || true
elif [[ "$SSH_PUBKEY" =~ ^(ssh-|ecdsa-|sk-) ]]; then
  printf '%s\n' "$SSH_PUBKEY" > "$PUBKEY_DATEI"
fi

[[ -s "$PUBKEY_DATEI" ]] || die "Kein oeffentlicher SSH-Schluessel gefunden.
  Erwartet wurde: $SSH_PUBKEY
  Am Arbeitsplatz erzeugen (falls noch keiner da ist) und auf den Node bringen:
      ssh-keygen -t ed25519
      ssh-copy-id root@$(hostname -I 2>/dev/null | awk '{print $1}')
  Oder den Schluessel direkt uebergeben:
      SSH_PUBKEY='ssh-ed25519 AAAA...' bash $0"

info "SSH-Schluessel: $(wc -l < "$PUBKEY_DATEI" | tr -d ' ') Stueck"

# ----------------------------------------------------------- Container bauen ---
if pct status "$VMID" >/dev/null 2>&1; then
  msg "Container $VMID besteht bereits - er wird nur neu eingerichtet"
  info "angelegt wird nichts, vorhandene Daten bleiben unberuehrt"
  if [[ "$(pct status "$VMID" | awk '{print $2}')" != "running" ]]; then
    run_step "Container starten" pct start "$VMID"
  fi
else
  msg "Vorlage bereitstellen"
  run_step "Vorlagenliste aktualisieren" pveam update

  VORLAGE="$(pveam available --section system 2>/dev/null \
             | awk '{print $2}' | grep -E '^debian-13-standard' | sort -V | tail -1 || true)"
  [[ -n "$VORLAGE" ]] || die "Keine Debian-13-Vorlage gefunden. 'pveam available --section system' zeigt, was es gibt."

  if pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk '{print $1}' | grep -qF "$VORLAGE"; then
    info "Vorlage bereits vorhanden: $VORLAGE"
  else
    run_step "Vorlage laden ($VORLAGE)" pveam download "$TEMPLATE_STORAGE" "$VORLAGE"
  fi

  msg "Container $VMID anlegen"
  NETZ="name=eth0,bridge=$BRIDGE"
  if [[ "$IP" == "dhcp" ]]; then
    NETZ="$NETZ,ip=dhcp"
  else
    NETZ="$NETZ,ip=$IP,gw=$GATEWAY"
  fi

  PCT_ARGS=(
    "$VMID" "$TEMPLATE_STORAGE:vztmpl/$VORLAGE"
    --hostname     "$CT_HOSTNAME"
    --cores        "$CORES"
    --memory       "$MEMORY"
    --swap         "$SWAP"
    --rootfs       "$STORAGE:$DISK"
    --net0         "$NETZ"
    --unprivileged 1
    --features     nesting=1,keyctl=1
    --onboot       1
    --ssh-public-keys "$PUBKEY_DATEI"
    --description  "claude-dev-lxc - Entwicklungsumgebung"
  )
  [[ "$IP" != "dhcp" ]] && PCT_ARGS+=(--nameserver "$NAMESERVER")

  run_step "pct create" pct create "${PCT_ARGS[@]}"
  run_step "Container starten" pct start "$VMID"
fi

# ------------------------------------------------- Auf Netz und Shell warten ---
msg "Auf den Container warten"
bereit=0
for _ in $(seq 1 60); do
  if pct exec "$VMID" -- true >/dev/null 2>&1; then bereit=1; break; fi
  sleep 2
done
[[ $bereit -eq 1 ]] || die "Container $VMID antwortet nicht auf 'pct exec'. 'pct status $VMID' und die Konsole pruefen."
info "Shell antwortet"

netz=0
for _ in $(seq 1 45); do
  if pct exec "$VMID" -- getent hosts deb.debian.org >/dev/null 2>&1; then netz=1; break; fi
  sleep 2
done
[[ $netz -eq 1 ]] || die "Keine Namensaufloesung im Container. Bei fester IP Gateway und DNS pruefen, bei DHCP den Server."
info "Netz und Namensaufloesung stehen"

# ------------------------------------------- Provisioning hineinreichen ---
# pct exec reicht keine Umgebung durch, deshalb eine Datei. pct push kann nur
# einzelne Dateien, deshalb das Verzeichnis als Archiv.
{
  printf 'CT_USER=%q\n'   "$CT_USER"
  printf 'GIT_NAME=%q\n'  "${GIT_NAME:-}"
  printf 'GIT_EMAIL=%q\n' "${GIT_EMAIL:-}"
  printf 'TZ_NAME=%q\n'   "${TZ_NAME:-Europe/Berlin}"
  printf 'LANG_NAME=%q\n' "${LANG_NAME:-de_DE.UTF-8}"
} > "$ENVDATEI"

tar -czf "$PROVTAR" -C "$HIER" provision

run_step "Einstellungen uebertragen" pct push "$VMID" "$ENVDATEI" /root/claude-dev.env      --perms 0600
run_step "Provisioning uebertragen"  pct push "$VMID" "$PROVTAR"  /root/provision.tar.gz    --perms 0600
run_step "Provisioning auspacken"    pct exec "$VMID" -- tar -xzf /root/provision.tar.gz -C /root

# ------------------------------------------------------------- Einrichten ---
msg "Grundsystem einrichten"
info "das dauert einige Minuten - die Ausgabe kommt aus dem Container"
printf '\n'
pct exec "$VMID" -- bash /root/provision/base.sh

for r in ${REZEPTE[@]+"${REZEPTE[@]}"}; do
  msg "Rezept: $r"
  pct exec "$VMID" -- bash "/root/provision/$r.sh"
done

pct exec "$VMID" -- rm -f /root/provision.tar.gz

# ------------------------------------------------------------ Ruecksetzpunkt ---
# Das Skript laeuft auf dem Node und kann den Snapshot selbst setzen, statt
# ihn dem Leser aufzutragen - der Schritt wurde in der Praxis sonst vergessen.
# Nur beim ersten Mal; ein Nachziehlauf ueberschreibt keinen bestehenden Stand.
if pct listsnapshot "$VMID" 2>/dev/null | grep -q "grundinstallation"; then
  info "Snapshot 'grundinstallation' besteht bereits - bleibt unveraendert"
elif pct snapshot "$VMID" grundinstallation >/dev/null 2>&1; then
  msg "Ruecksetzpunkt gesetzt"
  info "Snapshot 'grundinstallation' angelegt - zuruecksetzen mit: pct rollback $VMID grundinstallation"
else
  warn "Snapshot liess sich nicht anlegen - der Speicher '$STORAGE' unterstuetzt vermutlich keine Snapshots"
fi

# --------------------------------------------------------------- Abschluss ---
CT_IP="$(pct exec "$VMID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
[[ -n "$CT_IP" ]] || CT_IP="<IP unbekannt>"

# Der GitHub-Schluessel wird hier NOCH EINMAL ausgegeben statt auf "siehe
# oben" zu verweisen: im Ausgabestrom des Provisionings wurde er uebersehen.
GITHUB_KEY_ANZEIGE="$(pct exec "$VMID" -- su - "$CT_USER" -s /bin/bash -c 'cat "$HOME/.ssh/id_ed25519.pub"' 2>/dev/null || true)"

msg "Fertig"
cat <<ENDE

  Container $VMID ($CT_HOSTNAME) laeuft auf $(hostname), erreichbar unter $CT_IP

  Am Arbeitsplatz in ~/.ssh/config eintragen:

      Host $CT_HOSTNAME
          HostName $CT_IP
          User $CT_USER

  Was jetzt noch von Hand kommt - beides braucht dich im Browser:

  1) Claude Code anmelden
         ssh $CT_HOSTNAME
         claude
     Die angezeigte URL im Browser oeffnen, Code zurueck ins Terminal.

  2) VS Code verbinden
     Erweiterung "Remote - SSH" installieren, dann Cmd+Shift+P →
     "Remote-SSH: Connect to Host" → $CT_HOSTNAME.
     Wichtig: die Claude-Erweiterung anschliessend IM CONTAINER
     installieren - in der Erweiterungsansicht der Knopf
     "Install in SSH: $CT_HOSTNAME".

  3) GitHub-Schluessel des Containers eintragen
     (github.com → Settings → SSH and GPG keys → New SSH key),
     danach laesst sich klonen:

     ${GITHUB_KEY_ANZEIGE:-<liess sich nicht auslesen - im Container: cat ~/.ssh/id_ed25519.pub>}

  Der Snapshot 'grundinstallation' ist gesetzt (siehe oben). Vor
  riskanten Experimenten einen weiteren anlegen:
         pct snapshot $VMID vor-experiment

ENDE
