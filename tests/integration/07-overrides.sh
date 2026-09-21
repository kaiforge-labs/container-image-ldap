#!/usr/bin/env bash
# Overrides: Anwendung, eigener Pfad, Idempotenz, Fehlerbehandlung
# shellcheck source=../lib.sh
source "$(dirname "$0")/../lib.sh"

section "Gueltige Overrides ueber LDAP_OVERRIDES_DIR"
start_ldap ldap "${TLS_OPTS[@]}" \
  -v "$FIXTURES/overrides/valid:/custom:ro" -e LDAP_OVERRIDES_DIR=/custom
wait_healthy ldap
assert_contains "Overrides im Log" "Lade Override 10-loglevel.ldif" docker logs "$(cname ldap)"
assert_contains "olcLogLevel ueberschrieben" "olcLogLevel: stats" config_attr ldap olcLogLevel
assert_ok "Eintrag aus Override angelegt" \
  ldap_admin ldap ldapsearch -LLL -b "ou=override,$BASE" -s base dn

load_testdata ldap
assert_contains "Override-ACL: alice sieht sich selbst" "uid=alice" \
  ldap_user ldap alice ldapsearch -LLL -b "uid=alice,ou=people,$BASE" -s base dn
assert_not_contains "Override-ACL: alice sieht bob nicht" "uid=bob" \
  ldap_user ldap alice ldapsearch -LLL -b "uid=bob,ou=people,$BASE" -s base dn

section "Idempotenz beim Neustart"
restart_ldap ldap
assert_contains "olcLogLevel nach Neustart" "olcLogLevel: stats" config_attr ldap olcLogLevel
assert_not_contains "Override-ACL bleibt nach Neustart" "uid=bob" \
  ldap_user ldap alice ldapsearch -LLL -b "uid=bob,ou=people,$BASE" -s base dn

section "Fehlerhafter Override"
start_ldap ldap-b "${TLS_OPTS[@]}" -v "$FIXTURES/overrides/invalid:/etc/ldap/overrides.d:ro"
expect_startup_failure "Fehlerhafter Override bricht Start ab" ldap-b \
  "Override 10-broken.ldif fehlgeschlagen"

finish
