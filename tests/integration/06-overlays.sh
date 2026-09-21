#!/usr/bin/env bash
# Overlays memberof und refint
# shellcheck source=../lib.sh
source "$(dirname "$0")/../lib.sh"

start_ldap ldap "${TLS_OPTS[@]}"
wait_healthy ldap
load_testdata ldap

MODULES_CMD=(dexec ldap ldapsearch -Q -Y EXTERNAL -H ldapi:/// -LLL -b 'cn=module{0},cn=config' olcModuleLoad)
assert_contains "Modul memberof geladen" "memberof" "${MODULES_CMD[@]}"
assert_contains "Modul refint geladen" "refint" "${MODULES_CMD[@]}"

section "memberOf"
assert_contains "alice hat memberOf" "memberOf: cn=devs,ou=groups,$BASE" \
  ldap_admin ldap ldapsearch -LLL -b "uid=alice,ou=people,$BASE" -s base memberOf

section "refint"
ldap_admin ldap ldapdelete "uid=alice,ou=people,$BASE"
# shellcheck disable=SC2329 # wird indirekt per Namen ueber assert_eventually aufgerufen
alice_not_member() {
  ! ldap_has ldap "cn=devs,ou=groups,$BASE" member "uid=alice"
}
assert_eventually "Geloeschter User aus Gruppe entfernt" 15 alice_not_member
assert_ok "bob bleibt Mitglied" ldap_has ldap "cn=devs,ou=groups,$BASE" member "uid=bob"

finish
