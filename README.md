# claude-dev-lxc

Baut auf einem Proxmox-Node einen LXC-Container, in dem Claude Code läuft und
entwickelt wird — statt auf dem eigenen Rechner. Vom Arbeitsplatz aus verbindet sich
VS Code per Remote-SSH darauf; Editor, Terminal und die Claude-Erweiterung
laufen dann im Container.

Das Werkzeug kennt **kein Projekt**. Es baut eine leere, aber arbeitsfähige
Entwicklungsmaschine. Sprachstacks kommen als austauschbare Rezepte dazu, und
was ein einzelnes Projekt darüber hinaus braucht, bringt dieses Projekt selbst
mit.

## Warum überhaupt ein Container

- **Reichweite.** Claude darf dort großzügigere Rechte bekommen als auf dem
  Arbeitsrechner. Geht etwas schief, setzt ein Proxmox-Snapshot die Maschine zurück.
- **Unabhängig vom Deckel.** Lange Läufe überstehen einen zugeklappten Laptop.
- **Wiederholbar.** Eine neue Maschine ist ein Skriptaufruf, keine
  Nachmittagsbeschäftigung.

---

## Aufbau

| Datei | Läuft wo | Zweck |
|-------|----------|-------|
| `bootstrap.sh` | Node **oder** Container | holt das Projekt und startet den passenden Teil |
| `claude-dev.sh` | Proxmox-Node, als root | Container anlegen, Provisioning hineinreichen |
| `provision/lib.sh` | — | gemeinsame Helfer, wird eingebunden |
| `provision/base.sh` | im Container, als root | System, Benutzer, SSH, Git, Claude Code |
| `provision/php-mariadb.sh` | im Container | Rezept: PHP + MariaDB |
| `provision/node.sh` | im Container | Rezept: Node.js |
| `provision/python.sh` | im Container | Rezept: Python + pipx |

Die Skripte unter `provision/` laufen auch allein — etwa um eine bestehende
Debian-Maschine nachzurüsten:

```bash
CT_USER=dev bash provision/base.sh
bash provision/php-mariadb.sh
```

---

## Voraussetzungen

- Ein Proxmox-Node (Cluster oder Einzelinstallation), Zugriff als root
- Ein öffentlicher SSH-Schlüssel auf dem Node, üblicherweise in
  `/root/.ssh/authorized_keys`. Ohne ihn bricht das Skript ab, statt einen
  Container zu bauen, in den man sich nach dem Härten von sshd nicht mehr
  anmelden kann.
- Internetzugang von Node und Container

Fehlt der Schlüssel, vom Arbeitsplatz aus:

```bash
ssh-keygen -t ed25519          # falls noch keiner existiert
ssh-copy-id root@<node>
```

---

## Aufruf

### Ein Befehl (empfohlen)

`bootstrap.sh` holt das Projekt selbst und erkennt, wo es gelandet ist:
Ist `pct` vorhanden, läuft es auf einem Proxmox-Node und legt einen Container
an. Fehlt `pct`, richtet es die Maschine ein, auf der es gerade läuft — so
lässt sich derselbe Befehl auch in einem bereits angelegten, leeren LXC
benutzen.

Auf dem Node oder im Container, als root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/heikoboehme-dev/claude-dev-lxc/main/bootstrap.sh)"
```

Wer das Projekt in ein privates Repository geforkt hat, braucht einen
GitHub-Token mit Leserecht auf Inhalte (Fine-grained Token: *Contents: Read*)
und den Umweg über die contents-API:

```bash
export GITHUB_TOKEN=github_pat_xxxxxxxx
export GITHUB_REPO=<konto>/claude-dev-lxc
bash -c "$(curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H 'Accept: application/vnd.github.raw' \
  https://api.github.com/repos/$GITHUB_REPO/contents/bootstrap.sh)"
```

> **Wichtig:** die Form `bash -c "$(curl …)"` verwenden, **nicht** `curl | bash`.
> Nur so bleibt die Konsole für die Rückfragen nutzbar. Das Skript erkennt den
> Fall und bricht mit einem Hinweis ab, statt stumm die Vorgaben zu setzen.

### Ohne Bootstrap

Das ganze Verzeichnis auf den Node bringen und dort starten:

```bash
scp -r claude-dev-lxc root@<node>:/root/
ssh root@<node>
bash /root/claude-dev-lxc/claude-dev.sh
```

So oder so fragt es nach ID, Speicher, Netz und Größe; jede Frage hat eine
Vorgabe, die mit Enter übernommen wird. Vorgeschlagen wird ein geteilter
Speicher, falls einer vorhanden ist — nur damit lässt sich der Container später
im laufenden Betrieb auf einen anderen Node schieben.

### Mit Sprachstack

```bash
RECIPES=php-mariadb bash claude-dev.sh
RECIPES=php-mariadb,node bash claude-dev.sh
```

### Ohne Rückfragen

Alle Antworten lassen sich vorgeben; was nicht gesetzt ist, nimmt die Vorgabe:

```bash
NONINTERACTIVE=1 \
VMID=210 CT_HOSTNAME=claude-dev \
IP=192.168.1.210/24 GATEWAY=192.168.1.1 \
CT_USER=dev \
GIT_NAME="<Vorname Nachname>" GIT_EMAIL="<E-Mail>" \
RECIPES=php-mariadb \
bash claude-dev.sh
```

---

## Alle Einstellungen

| Variable | Vorgabe | Bedeutung |
|----------|---------|-----------|
| `VMID` | nächste freie | Container-ID, clusterweit eindeutig |
| `CT_HOSTNAME` | `claude-dev` | Hostname |
| `STORAGE` | geteilter, sonst erster passende | Speicher für `rootfs` |
| `TEMPLATE_STORAGE` | `local`, sonst erster passende | Speicher für die Vorlage |
| `CORES` / `MEMORY` / `SWAP` / `DISK` | 4 / 4096 / 1024 / 25 | Ausstattung |
| `BRIDGE` | `vmbr0` | Netzwerkbrücke |
| `IP` | `dhcp` | feste Adresse als CIDR, z. B. `192.168.1.210/24` |
| `GATEWAY` / `NAMESERVER` | — / Gateway | nur bei fester Adresse |
| `CT_USER` | `dev` | Arbeitsbenutzer im Container |
| `SSH_PUBKEY` | `/root/.ssh/authorized_keys` | Datei oder Schlüsseltext |
| `GIT_NAME` / `GIT_EMAIL` | — | `git config --global` im Container |
| `RECIPES` | — | Kommaliste, z. B. `php-mariadb,node` |
| `TZ_NAME` / `LANG_NAME` | `Europe/Berlin` / `de_DE.UTF-8` | Sprache und Zeit |
| `NONINTERACTIVE` | `0` | `1` unterdrückt alle Rückfragen |
| `NODE_MAJOR` | — | im Node-Rezept: Fassung aus dem NodeSource-Depot |
| `PHP_EXTRA` | — | im PHP-Rezept: zusätzliche Erweiterungen |

Nur für `bootstrap.sh`:

| Variable | Vorgabe | Bedeutung |
|----------|---------|-----------|
| `MODE` | `auto` | `node` legt einen Container an, `container` richtet die laufende Maschine ein |
| `GITHUB_REPO` | `heikoboehme-dev/claude-dev-lxc` | Quelle |
| `GITHUB_TOKEN` | — | nur für einen privaten Fork nötig |
| `REPO_URL` | — | eigener Git-Server; überschreibt die beiden darüber |
| `REPO_REF` | `main` | Branch oder Tag |
| `SRC_DIR` | `/opt/claude-dev-lxc` | wohin geklont wird |

---

## Wiederholbar

Alle Skripte legen nur an, was fehlt. Ein zweiter Lauf mit derselben `VMID`
baut keinen neuen Container, sondern richtet den vorhandenen nach. Ein von Hand
ergänzter SSH-Schlüssel wird dabei zusammengeführt, nicht ersetzt.

Weil das Werkzeug keine Projektdaten anfasst, kann es auch nichts davon
zerstören — Datenbanken und Arbeitskopien entstehen erst durch das jeweilige
Projekt.

---

## Was das Skript nicht tut

**Kein Klonen mit Token.** Der Container erzeugt einen eigenen SSH-Schlüssel
und zeigt ihn am Ende an. Den trägst du bei GitHub ein, danach klonst du
selbst. Ein Token müsste durch Prozessliste, Übergabedatei und `.git/config`
wandern — der Schlüssel bleibt dagegen im Container und wird einmal
hinterlegt.

**Kein Projekt-Setup.** Was ein Projekt an Datenbank, Konfiguration oder
Migrationen braucht, weiß nur das Projekt. Bringt es ein eigenes
Einrichtungsskript mit, hat dieses Vorrang.

**Zwei Schritte brauchen einen Browser** und bleiben deshalb von Hand:

1. **Claude Code anmelden.** `claude` im Container starten, die angezeigte URL
   im Browser öffnen, den Code zurück ins Terminal.
2. **VS Code verbinden.** Erweiterung *Remote – SSH* installieren, mit dem
   Container verbinden — und danach die Claude-Erweiterung **im Container**
   installieren (Knopf *Install in SSH: …*). Eine nur lokal installierte
   Erweiterung läuft im Container nicht mit; das ist die häufigste
   Stolperstelle.

Das Skript listet alles Offene am Ende noch einmal auf.

---

## Ein Projekt dazuholen

```bash
ssh claude-dev
git clone git@github.com:<konto>/<projekt>.git ~/projekte/<projekt>
cd ~/projekte/<projekt>
# dann das Einrichtungsskript des Projekts, z. B.:
php tools/setup_local.php
```

Der Entwicklungsserver bindet an `localhost` — VS Code leitet den Port
automatisch weiter, die Oberfläche liegt dann am Arbeitsplatz unter derselben
Adresse. Das ist besser als eine Bindung an `0.0.0.0`, weil konfigurierte
Basis-URLs (`APP_URL` und Verwandte) unverändert stimmen.

**Zwei Projekte oder Zweige gleichzeitig:** eigener Port pro Server und
`127.0.0.1` statt `localhost` für den zweiten. Cookies werden nach Hostname
unterschieden, nicht nach Port — unter derselben Adresse überschreiben sich
sonst die Sitzungen gegenseitig.

---

## Ein Rezept ergänzen

Eine neue Datei `provision/<name>.sh` nach diesem Muster:

```bash
#!/usr/bin/env bash
set -euo pipefail
HIER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$HIER/lib.sh"

msg "Mein Stack"
pakete paket-eins paket-zwei
info "fertig"
```

`lib.sh` stellt `msg`, `info`, `warn`, `die`, `pakete`, `als_user` und
`dienst_laeuft` bereit und kennt `CT_USER` und `HEIM`. Danach ist der Name
über `RECIPES=<name>` verwendbar.

---

## Danach

Rücksetzpunkt anlegen, solange alles frisch ist:

```bash
pct snapshot <VMID> grundinstallation
```

Vor einem Rollback `git status` in allen Arbeitskopien prüfen und Ungepushtes
pushen — der Rollback wirft es sonst mit weg. Der Code liegt auf GitHub und ist
darüber gesichert; Snapshot und Backup schützen die Umgebung, nicht die Arbeit.
