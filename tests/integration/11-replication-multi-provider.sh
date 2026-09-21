#!/usr/bin/env bash
# Multi-Provider-Replikation in beide Richtungen
# shellcheck source=../lib.sh
source "$(dirname "$0")/../lib.sh"

MPR=("${TLS_OPTS[@]}" "${REPL_OPTS[@]}" -e LDAP_REPLICATION_MODE=multi-provider)

section "Start"
start_ldap ldap1 "${MPR[@]}" -e LDAP_SERVER_ID=1 -e LDAP_REPLICATION_PEERS=ldaps://ldap2
wait_healthy ldap1
start_ldap ldap2 "${MPR[@]}" -e LDAP_SERVER_ID=2 -e LDAP_REPLICATION_PEERS=ldaps://ldap1 \
  -e LDAP_REPLICATION_SEED=false
wait_healthy ldap2

assert_contains "olcServerID auf ldap2" "olcServerID: 2" config_attr ldap2 olcServerID
assert_contains "olcMultiProvider aktiv" "olcMultiProvider: TRUE" \
  config_attr ldap2 olcMultiProvider "$DB_DN"
assert_eventually "Initialer Sync auf ldap2" 60 \
  ldap_admin ldap2 ldapsearch -LLL -b "$BASE" -s base dn

section "ldap1 -> ldap2"
load_testdata ldap1
assert_eventually "User auf ldap2" 30 \
  ldap_admin ldap2 ldapsearch -LLL -b "uid=alice,ou=people,$BASE" -s base dn

section "ldap2 -> ldap1"
ldap_admin ldap2 ldapmodify -f /fixtures/ldif/modify-description.ldif >/dev/null
assert_eventually "Aenderung von ldap2 auf ldap1" 30 \
  ldap_has ldap1 "uid=alice,ou=people,$BASE" description "geaendert"
ldap_admin ldap2 ldapmodify -f /fixtures/ldif/carol.ldif >/dev/null
assert_eventually "Neuer Eintrag von ldap2 auf ldap1" 30 \
  ldap_admin ldap1 ldapsearch -LLL -b "uid=carol,ou=people,$BASE" -s base dn
assert_eventually "contextCSN identisch" 30 csn_equal ldap1 ldap2

section "Neustart eines Knotens"
restart_ldap ldap2
ldap_admin ldap1 ldapdelete "uid=bob,ou=people,$BASE"
assert_eventually "Loeschung nach Neustart repliziert" 30 \
  ldap_absent ldap2 "uid=bob,ou=people,$BASE"

section "Fehlkonfiguration"
start_ldap ldap-a "${MPR[@]}" -e LDAP_REPLICATION_PEERS=ldaps://ldap1
expect_startup_failure "Multi-Provider ohne Server-ID" ldap-a "LDAP_SERVER_ID"

finish
