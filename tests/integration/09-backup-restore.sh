#!/usr/bin/env bash
# Backup, Aufbewahrung und Restore
# shellcheck source=../lib.sh
source "$(dirname "$0")/../lib.sh"

BACKUP="$(vol backup)"

section "Backup"
start_ldap ldap "${TLS_OPTS[@]}" -v "$BACKUP:/var/backups/ldap"
wait_healthy ldap
load_testdata ldap

dexec ldap sh -c 'mkdir -p /var/backups/ldap/20000101-000000 &&
  touch -d "30 days ago" /var/backups/ldap/20000101-000000'
assert_ok "ldap-backup laeuft" dexec ldap ldap-backup
latest="$(dexec ldap sh -c 'ls -1 /var/backups/ldap | sort | tail -n1')"

assert_ok "config.ldif.gz vorhanden" dexec ldap test -s "/var/backups/ldap/$latest/config.ldif.gz"
assert_ok "data.ldif.gz vorhanden" dexec ldap test -s "/var/backups/ldap/$latest/data.ldif.gz"
assert_contains "Backup enthaelt Testdaten" "uid=alice" \
  dexec ldap sh -c "zcat /var/backups/ldap/$latest/data.ldif.gz"
assert_contains "Backup nur fuer root lesbar" "^700$" \
  dexec ldap stat -c '%a' "/var/backups/ldap/$latest"
assert_fail "Alte Backups entfernt" dexec ldap test -e /var/backups/ldap/20000101-000000

section "Restore in neue Instanz"
start_ldap restored "${TLS_OPTS[@]}" -v "$BACKUP:/var/backups/ldap:ro" \
  -e "LDAP_RESTORE_FROM=/var/backups/ldap/$latest"
wait_healthy restored
assert_contains "Log meldet Restore" "Restore aus" docker logs "$(cname restored)"
assert_contains "Daten wiederhergestellt" "uid=alice" \
  ldap_admin restored ldapsearch -LLL -b "ou=people,$BASE" dn
assert_ok "User-Passwort funktioniert" ldap_user restored alice ldapwhoami
assert_contains "Overlays wiederhergestellt" "memberOf: cn=devs" \
  ldap_admin restored ldapsearch -LLL -b "uid=alice,ou=people,$BASE" -s base memberOf

section "Restore aus fehlendem Pfad"
start_ldap ldap-a "${TLS_OPTS[@]}" -v "$BACKUP:/var/backups/ldap:ro" \
  -e LDAP_RESTORE_FROM=/var/backups/ldap/gibt-es-nicht
expect_startup_failure "Fehlendes Backup bricht ab" ldap-a "config.ldif.gz fehlt"

finish
