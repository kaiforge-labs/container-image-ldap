#!/usr/bin/env bash
# Eigene Zertifikate mit angepassten Pfaden und restriktiven Rechten
# shellcheck source=../lib.sh
source "$(dirname "$0")/../lib.sh"

cp "$FIXTURES/certs/server.crt" "$WORK/my.crt"
cp "$FIXTURES/certs/server.key" "$WORK/my.key"
chmod 600 "$WORK/my.key"

section "Eigene Zertifikate an eigenen Pfaden"
start_ldap ldap -v "$WORK:/tls:ro" \
  -e LDAP_TLS_CERT_FILE=/tls/my.crt -e LDAP_TLS_KEY_FILE=/tls/my.key
wait_healthy ldap
assert_ok "Kein Self-Signed erzeugt" dexec ldap test ! -e /etc/ldap/certs/server.crt
assert_ok "Bind mit Pruefung gegen Test-CA" ldap_admin ldap ldapwhoami
assert_contains "Server liefert Zertifikat der Test-CA" "LDAP Test CA" \
  client sh -c 'openssl s_client -connect ldap:636 </dev/null 2>/dev/null | openssl x509 -noout -issuer'
assert_contains "Key-Kopie gehoert openldap mit 600" "^600 openldap$" \
  dexec ldap stat -c '%a %U' /etc/ldap/tls-runtime/server.key

section "Fehlerfaelle"
start_ldap ldap-b -v "$WORK:/tls:ro" \
  -e LDAP_TLS_CERT_FILE=/tls/my.crt -e LDAP_TLS_KEY_FILE=/tls/fehlt.key
expect_startup_failure "Zertifikat ohne Key bricht ab" ldap-b "beide vorhanden"

start_ldap ldap-c "${TLS_OPTS[@]}" -e LDAP_TLS_CA_FILE=/tls/gibt-es-nicht.crt
expect_startup_failure "Fehlende CA-Datei bricht ab" ldap-c "CA-Datei .* nicht lesbar"

finish
