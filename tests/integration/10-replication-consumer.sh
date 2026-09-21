#!/usr/bin/env bash
# Replikation Provider -> Consumer
# shellcheck source=../lib.sh
source "$(dirname "$0")/../lib.sh"

section "Start"
start_ldap provider "${TLS_OPTS[@]}" "${REPL_OPTS[@]}" -e LDAP_REPLICATION_MODE=provider
wait_healthy provider
start_ldap consumer "${TLS_OPTS[@]}" "${REPL_OPTS[@]}" \
  -e LDAP_REPLICATION_MODE=consumer -e LDAP_REPLICATION_PEERS=ldaps://provider
wait_healthy consumer

assert_contains "syncprov auf Provider aktiv" "syncprov" \
  dexec provider ldapsearch -Q -Y EXTERNAL -H ldapi:/// -LLL -b "$DB_DN" -s one dn
assert_ok "Replikations-Account angelegt" ldap_admin provider ldapsearch -LLL -b "$REPL_DN" -s base dn
assert_ok "Replikations-Account kann sich anmelden" \
  client ldapwhoami -x -H ldaps://provider -D "$REPL_DN" -w "$REPL_PW"
assert_eventually "Basiseintrag auf Consumer" 60 \
  ldap_admin consumer ldapsearch -LLL -b "$BASE" -s base dn

section "Datenreplikation"
load_testdata provider
assert_contains "Replikator liest Passwoerter" "userPassword" \
  client ldapsearch -x -LLL -H ldaps://provider -D "$REPL_DN" -w "$REPL_PW" \
  -b "uid=alice,ou=people,$BASE" -s base userPassword
assert_eventually "Neuer User auf Consumer" 30 \
  ldap_admin consumer ldapsearch -LLL -b "uid=alice,ou=people,$BASE" -s base dn
assert_eventually "User-Passwort auf Consumer gueltig" 30 ldap_user consumer alice ldapwhoami

ldap_admin provider ldapmodify -f /fixtures/ldif/modify-description.ldif >/dev/null
assert_eventually "Aenderung auf Consumer" 30 \
  ldap_has consumer "uid=alice,ou=people,$BASE" description "geaendert"

ldap_admin provider ldapdelete "uid=bob,ou=people,$BASE"
assert_eventually "Loeschung auf Consumer" 30 ldap_absent consumer "uid=bob,ou=people,$BASE"
assert_eventually "contextCSN identisch" 30 csn_equal provider consumer

section "Consumer ist read-only"
assert_contains "Schreibzugriff liefert Referral" "Referral|ldaps://provider" \
  ldap_admin consumer ldapmodify -f /fixtures/ldif/modify-description.ldif

section "Fehlkonfigurationen"
start_ldap ldap-a "${TLS_OPTS[@]}" "${REPL_OPTS[@]}" -e LDAP_REPLICATION_MODE=consumer
expect_startup_failure "Consumer ohne Peers" ldap-a "LDAP_REPLICATION_PEERS fehlt"

start_ldap ldap-b "${TLS_OPTS[@]}" "${REPL_SECRET[@]}" -e LDAP_REPLICATION_MODE=provider \
  -e "LDAP_REPLICATION_BIND_DN=uid=repl,$BASE"
expect_startup_failure "Bind-DN ohne cn=" ldap-b "muss mit cn= beginnen"

printf 'a"b' > "$WORK/badpw"
start_ldap ldap-c "${TLS_OPTS[@]}" -e LDAP_REPLICATION_MODE=provider \
  -e "LDAP_REPLICATION_BIND_DN=$REPL_DN" \
  -v "$WORK/badpw:/run/secrets/ldap_replication_password:ro"
expect_startup_failure "Passwort mit Anfuehrungszeichen" ldap-c "darf kein"

start_ldap ldap-a "${TLS_OPTS[@]}" -e LDAP_REPLICATION_MODE=irgendwas
expect_startup_failure "Ungueltiger Modus" ldap-a "LDAP_REPLICATION_MODE muss"

finish
