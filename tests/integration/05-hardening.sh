#!/usr/bin/env bash
# Haertung: anonyme Zugriffe, ACLs, Passwort-Hashing
# shellcheck source=../lib.sh
source "$(dirname "$0")/../lib.sh"

start_ldap ldap "${TLS_OPTS[@]}"
wait_healthy ldap
load_testdata ldap

section "Konfiguration"
assert_contains "Anonyme Binds deaktiviert" "olcDisallows: bind_anon" config_attr ldap olcDisallows
assert_contains "Authentifizierung erforderlich" "olcRequires: authc" \
  config_attr ldap olcRequires 'olcDatabase={-1}frontend,cn=config'
root_hash="$(config_attr ldap olcRootPW "$DB_DN" | ldif_value olcRootPW)"
assert_ok "olcRootPW ist gehasht" test "${root_hash:0:1}" = "{"

section "Anonymer Zugriff"
assert_fail "Anonymer Bind abgelehnt" client ldapwhoami -x -H ldaps://ldap
assert_fail "Anonyme Suche abgelehnt" client ldapsearch -x -H ldaps://ldap -b "$BASE"

section "ACLs"
assert_contains "alice liest bob" "uid=bob" \
  ldap_user ldap alice ldapsearch -LLL -b "uid=bob,ou=people,$BASE" -s base dn
assert_not_contains "alice liest nicht bobs Passwort" "userPassword" \
  ldap_user ldap alice ldapsearch -LLL -b "uid=bob,ou=people,$BASE" -s base userPassword
assert_contains "alice liest eigenes Passwort" "userPassword" \
  ldap_user ldap alice ldapsearch -LLL -b "uid=alice,ou=people,$BASE" -s base userPassword
assert_contains "alice darf bob nicht aendern" "Insufficient access" \
  ldap_user ldap alice ldapmodify -f /fixtures/ldif/modify-bob.ldif

section "Passwort-Hashing"
if dexec ldap sh -c 'ls /usr/lib/ldap/argon2.so*' >/dev/null 2>&1; then
  expected='{ARGON2}'
else
  expected='{SSHA}'
fi
hash="$(ldap_admin ldap ldapsearch -LLL -o ldif-wrap=no -b "uid=alice,ou=people,$BASE" \
  -s base userPassword | ldif_value userPassword)"
assert_ok "Passwort-Hash nutzt $expected" test "${hash:0:${#expected}}" = "$expected"

section "Eigenes Passwort aendern"
assert_ok "alice aendert eigenes Passwort" ldap_user ldap alice ldappasswd -s alice-neu
assert_ok "Bind mit neuem Passwort" with_pw alice-neu ldap_user ldap alice ldapwhoami
assert_fail "Altes Passwort ungueltig" ldap_user ldap alice ldapwhoami

finish
