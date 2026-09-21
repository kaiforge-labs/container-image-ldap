# ldap-debian

OpenLDAP-Container auf Basis von Debian (trixie-slim) mit verpflichtendem TLS,
optionalem mTLS, Docker Secrets, gehärteten Standardeinstellungen,
Backup/Restore und Replikation.

## Features

- **TLS verpflichtend:** LDAPS (636) und StartTLS (389), Klartext-Binds werden abgelehnt, mindestens TLS 1.2
- **Automatisches Self-Signed-Zertifikat**, wenn kein eigenes Zertifikat eingebunden ist
- **mTLS** mit konfigurierbarer Client-Zertifikatsprüfung
- **Docker Secrets** für alle Passwörter, Rotation per Neustart
- **Härtung:** keine anonymen Binds, Authentifizierung erforderlich, restriktive ACLs, Argon2-Hashing (falls im Paket verfügbar)
- **Overlays:** `memberof` und `refint`
- **Overrides:** eigene LDIFs überschreiben alle Presets bei jedem Start
- **Backup & Restore** über `slapcat`/`slapadd`
- **Replikation:** Provider/Consumer und Multi-Provider
- **Healthcheck** für Docker, Compose und Kubernetes

## Schnellstart

```bash
cd examples
mkdir -p secrets
openssl rand -base64 24 | tr -d '\n' > secrets/ldap_admin_password
docker compose up -d

docker compose cp ldap:/etc/ldap/certs/server.crt .
LDAPTLS_CACERT=./server.crt ldapwhoami -x -H ldaps://localhost \
  -D cn=admin,dc=example,dc=org -W
```

## Konfiguration

| Variable | Standard | Beschreibung |
|---|---|---|
| `LDAP_DOMAIN` | `example.org` | Domain, daraus ergibt sich die Base-DN |
| `LDAP_ORG` | `Example Inc` | Organisationsname |
| `LDAP_ADMIN_PASSWORD_FILE` | `/run/secrets/ldap_admin_password` | Secret mit dem Admin-Passwort |
| `LDAP_TLS_CERT_FILE` | `/etc/ldap/certs/server.crt` | Serverzertifikat inkl. Zwischenzertifikaten |
| `LDAP_TLS_KEY_FILE` | `/etc/ldap/certs/server.key` | Privater Schlüssel (unverschlüsselt) |
| `LDAP_TLS_CA_FILE` | System-Bundle | CAs zur Prüfung von Client-Zertifikaten |
| `LDAP_TLS_VERIFY_CLIENT` | `never` | `never`, `allow`, `try` oder `demand` |
| `LDAP_TLS_ENFORCE` | `true` | Klartext-Verbindungen ablehnen |
| `LDAP_TLS_HOSTNAME` | ldap.$LDAP_DOMAIN | CN/SAN des Self-Signed-Zertifikats |
| `LDAP_TLS_DAYS` | `365` | Gültigkeit des Self-Signed-Zertifikats |
| `LDAP_OVERRIDES_DIR` | `/etc/ldap/overrides.d` | Verzeichnis für Override-LDIFs |
| `LDAP_LOG_LEVEL` | `0` | Debug-Level von slapd |
| `LDAP_RESTORE_FROM` | – | Backup-Verzeichnis für Restore bei leeren Volumes |
| `LDAP_BACKUP_DIR` | `/var/backups/ldap` | Zielverzeichnis für `ldap-backup` |
| `LDAP_BACKUP_KEEP_DAYS` | `14` | Aufbewahrungsdauer der Backups |
| `LDAP_REPLICATION_MODE` | `none` | `none`, `provider`, `consumer`, `multi-provider` |
| `LDAP_SERVER_ID` | – | Eindeutige ID (1–4095), nur Multi-Provider |
| `LDAP_REPLICATION_PEERS` | – | Kommagetrennte `ldaps://`-URLs der Peers |
| `LDAP_REPLICATION_BIND_DN` | – | DN des Replikations-Accounts (`cn=...,<Base-DN>`) |
| `LDAP_REPLICATION_PASSWORD_FILE` | `/run/secrets/ldap_replication_password` | Secret des Replikations-Accounts |
| `LDAP_REPLICATION_CA_FILE` | System-Bundle | CAs zur Prüfung der Peer-Zertifikate |
| `LDAP_REPLICATION_SEED` | `true` (Consumer: `false`) | Ob dieser Knoten die Daten initialisiert |

### Volumes und Ports

| Pfad | Inhalt |
|---|---|
| `/etc/ldap/slapd.d` | Konfiguration (`cn=config`) |
| `/var/lib/ldap` | Datenbank |
| `/etc/ldap/certs` | Zertifikate (inkl. generiertem Self-Signed) |
| `/var/backups/ldap` | Backups |

Ports: `389` (LDAP mit StartTLS), `636` (LDAPS).

## TLS

Ohne eingebundenes Zertifikat wird beim ersten Start ein Self-Signed-Zertifikat
für ldap.<Domain> erzeugt und im Volume `/etc/ldap/certs` abgelegt. Zusätzlich
im Zertifikat enthalten sind der Container-Hostname, localhost und 127.0.0.1.
Clients müssen den Server also unter ldap.example.org erreichen, sonst schlägt
die Namensprüfung fehl. Zum Erneuern `server.crt` und `server.key` löschen und
neu starten.

Eigene Zertifikate können an beliebigen Pfaden eingebunden werden, auch
read-only. Das Image kopiert sie intern mit passenden Rechten für slapd.
Die komplette Kette gehört in `LDAP_TLS_CERT_FILE`.

### mTLS

`LDAP_TLS_CA_FILE` ist der Trust Store für **Client**-Zertifikate. Standardmäßig
wird das System-Bundle verwendet; für eine interne CA die Datei einbinden oder
das Image erweitern und `update-ca-certificates` ausführen.

```yaml
environment:
  LDAP_TLS_VERIFY_CLIENT: demand
  LDAP_TLS_CA_FILE: /tls/client-ca.crt
```

## Secrets

Passwörter werden ausschließlich aus Dateien gelesen. Das Admin-Passwort wird
bei jedem Start neu gesetzt: Secret ändern und neu starten genügt zur Rotation.
Abschließende Zeilenumbrüche werden ignoriert.

## Härtung (Standard)

- Anonyme Binds deaktiviert, alle Operationen erfordern Authentifizierung
- TLS 1.2 als Mindestversion, Klartext abgelehnt (`LDAP_TLS_ENFORCE`)
- ACLs: `userPassword` nur für den Eigentümer, alle anderen Daten für authentifizierte Benutzer lesbar
- Passwort-Hashes mit Argon2, sofern das Modul vorhanden ist, sonst SSHA

Hinweis: `olcPasswordHash` greift nur bei `ldappasswd`. Passwörter daher nicht im
Klartext per `ldapadd` setzen.

## Overrides

Alle `*.ldif` in `LDAP_OVERRIDES_DIR` werden bei **jedem** Start nach den Presets
in alphabetischer Reihenfolge per `ldapmodify` angewendet und können damit jede
Voreinstellung überschreiben.

- LDIFs müssen `changetype` enthalten und idempotent sein (bevorzugt `replace`)
- Die Fehler "existiert bereits" und "existiert nicht" (16, 20, 68) werden toleriert, alle anderen Fehler brechen den Start ab
- Die ACL-Regel für `cn=peercred` (root via ldapi) muss erhalten bleiben, sonst funktionieren Healthcheck und Konfiguration nicht
- Overlay-DNs enthalten einen Index, z. B. `olcOverlay={0}memberof,olcDatabase={1}mdb,cn=config`

Beispiel: [`examples/overrides/10-acl.ldif`](examples/overrides/10-acl.ldif)

## Backup & Restore

```bash
# Backup (z. B. per Host-Cron)
docker compose exec -T ldap ldap-backup
```

Backups enthalten Passwort-Hashes und im Config-Teil das Replikationspasswort
im Klartext. Daher extern verschlüsselt ablegen (z. B. restic oder age).

Restore: Container mit **leeren** Volumes und
`LDAP_RESTORE_FROM=/var/backups/ldap/<Zeitstempel>` starten. Danach die Variable
wieder entfernen.

## Replikation

Repliziert werden die Daten, nicht `cn=config`. Env-Variablen und Overrides
müssen daher auf allen Knoten gleich sein (bis auf Server-ID, Peers und
Zertifikate). Der Replikations-Account wird auf dem Seed-Knoten automatisch
angelegt und sein Passwort bei jedem Start synchronisiert.

| Modus | Beschreibung |
|---|---|
| `provider` | Liefert Daten an Consumer |
| `consumer` | Read-only, Schreibzugriffe erhalten ein Referral zum Provider |
| `multi-provider` | Alle Knoten beschreibbar |

Voraussetzungen:

- Genau ein Knoten mit `LDAP_REPLICATION_SEED=true`, alle anderen starten leer (oder per Restore aus einem Backup)
- Zertifikate, die zu den Peer-URLs passen, und eine gemeinsame CA in `LDAP_REPLICATION_CA_FILE`
- Zeitsynchronisation (NTP) auf allen Hosts
- Replikationspasswort ohne `"` und `\`

```yaml
ldap1:
  environment:
    LDAP_REPLICATION_MODE: multi-provider
    LDAP_SERVER_ID: "1"
    LDAP_REPLICATION_PEERS: ldaps://ldap2.example.org
    LDAP_REPLICATION_BIND_DN: cn=replicator,dc=example,dc=org
    LDAP_REPLICATION_CA_FILE: /tls/ca.crt
ldap2:
  environment:
    LDAP_REPLICATION_MODE: multi-provider
    LDAP_SERVER_ID: "2"
    LDAP_REPLICATION_PEERS: ldaps://ldap1.example.org
    LDAP_REPLICATION_BIND_DN: cn=replicator,dc=example,dc=org
    LDAP_REPLICATION_CA_FILE: /tls/ca.crt
    LDAP_REPLICATION_SEED: "false"
```

Status prüfen: `contextCSN` muss auf allen Knoten übereinstimmen.

```bash
docker exec ldap1 ldapsearch -Q -Y EXTERNAL -H ldapi:/// \
  -b dc=example,dc=org -s base contextCSN
```

Bekannte Einschränkung: `memberof` kann bei Multi-Provider Probleme machen.
Als Alternative bietet sich `dynlist` per Override an.

## Healthcheck

Der Container ist erst healthy, wenn die Konfigurationsphase abgeschlossen ist
und slapd über `ldapi:///` antwortet.

## Entwicklung

Voraussetzungen: Docker, Bash, OpenSSL, optional ShellCheck.

```bash
make lint                # ShellCheck + Hadolint
make test                # Image bauen, Test-PKI erzeugen, alle Tests
make test TESTS=tests/integration/05-hardening.sh
```

Jeder Test startet eigene Container in einem isolierten Netzwerk und räumt
danach auf. Bei Fehlern werden die Container-Logs ausgegeben.

## CI/CD

- **ci.yml** (Pull Requests): Lint, Build, Trivy-Scan, Integrationstests parallel pro Testdatei
- **release.yml** (main, Tags `v*`, wöchentlich): führt CI aus und veröffentlicht Multi-Arch-Images (amd64/arm64) mit SBOM und Provenance in der GitHub Container Registry
  - Tag `v1.2.3` → `1.2.3`, `1.2`, `1`, `latest`
  - `main` und wöchentlicher Rebuild → `edge` (enthält aktuelle Debian-Sicherheitsupdates)

## Lizenz

Siehe [LICENSE](LICENSE).
