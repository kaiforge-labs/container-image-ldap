# Changelog

Alle nennenswerten Änderungen an diesem Projekt werden in dieser Datei
dokumentiert.

Das Format orientiert sich an [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
dieses Projekt folgt [Semantic Versioning](https://semver.org/lang/de/).

## [Unreleased]

### Added

- OpenLDAP-Container auf Basis von Debian trixie-slim mit verpflichtendem TLS
  (LDAPS 636, StartTLS 389, mindestens TLS 1.2), automatischem
  Self-Signed-Zertifikat, mTLS, Docker Secrets, Härtung (keine anonymen
  Binds, restriktive ACLs, Argon2-Hashing falls verfügbar), Overlays
  `memberof`/`refint`, Overrides über `LDAP_OVERRIDES_DIR`, Backup/Restore
  über `slapcat`/`slapadd` und Replikation (`provider`, `consumer`,
  `multi-provider`) — siehe [README](README.md) für Details
- Healthcheck über `ldapi:///` plus Ready-Flag
- Integrationstest-Suite (`tests/`, 11 Testdateien) und CI/CD über GitHub
  Actions (Lint, Build, Trivy-Scan, Multi-Arch-Release nach GHCR)
- MIT-Lizenz

### Fixed

- `olcSecurity: tls=1` blockierte `ldapi:///`-Zugriffe (SASL EXTERNAL)
  sobald TLS-Erzwingung aktiv war und brach damit sowohl die eigene
  Entrypoint-Konfiguration als auch den Healthcheck. Ersetzt durch
  `olcSecurity: ssf=128` zusammen mit `olcLocalSSF: 128`
- `olcMultiProvider` wurde beim Deaktivieren der Replikation explizit auf
  `FALSE` gesetzt statt gelöscht, wodurch OpenLDAP die Datenbank fälschlich
  als Replikations-Shadow behandelte und jeden Schreibzugriff mit
  "shadow context; no update referral" ablehnte — auch ohne aktive
  Replikation
- `make lint` schlug fehl: zwei ShellCheck-Falsch-Positive (SC2001,
  SC2329) sowie ein fehlendes `.hadolint.yaml` in der containerisierten
  Hadolint-Ausführung, wodurch der dokumentierte DL3008-Ausschluss nie
  griff
- `docker volume create -l` scheiterte an neueren Docker-CLI-Versionen
  (kein `-l`-Kurzflag für `volume create`); auf `--label` umgestellt

### Changed

- Paketversionen im Dockerfile werden mit Major.Minor-Präfix und
  `*`-Suffix gepinnt (z. B. `slapd=2.6.*`) statt DL3008 zu ignorieren —
  Sicherheitsupdates innerhalb der gepinnten Version werden bei Rebuilds
  weiterhin gezogen, ein Sprung auf eine neue Minor-/Major-Version aber
  nicht mehr stillschweigend
- `HEALTHCHECK CMD` von Shell- auf JSON/Exec-Form umgestellt (verhält sich
  identisch, behebt DL3025)
