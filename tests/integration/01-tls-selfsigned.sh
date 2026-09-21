#!/usr/bin/env bash
# Self-Signed-Zertifikat, TLS-Erzwingung, LDAPS, StartTLS, TLS-Mindestversion
# shellcheck source=../lib.sh
source "$(dirname "$0")/../lib.sh"

section "Start ohne eigene Zertifikate"
start_ldap ldap
wait_healthy ldap
assert_ok "Self-Signed-Zertifikat erzeugt" dexec ldap test -s /etc/ldap/certs/server.crt
assert_contains "Hostname als SAN enthalten" "DNS:ldap" \
  dexec ldap openssl x509 -in /etc/ldap/certs/server.crt -noout -ext subjectAltName
assert_ok "CA-Datei ist das System-Bundle" \
  dexec ldap cmp /etc/ldap/tls-runtime/ca.crt /etc/ssl/certs/ca-certificates.crt

docker cp "$(cname ldap):/etc/ldap/certs/server.crt" "$WORK/server.crt"
export CLIENT_CA=/work/server.crt

section "Verbindungen"
assert_ok "Bind ueber LDAPS" ldap_admin ldap.example.org ldapwhoami
assert_ok "Bind ueber StartTLS" \
  client ldapwhoami -x -ZZ -H ldap://ldap.example.org -D "$ADMIN_DN" -w "$ADMIN_PW"
assert_contains "Klartext-Bind abgelehnt" "Confidentiality required" \
  client ldapwhoami -x -H ldap://ldap.example.org -D "$ADMIN_DN" -w "$ADMIN_PW"
assert_contains "Falsches Passwort abgelehnt" "Invalid credentials" \
  client ldapwhoami -x -H ldaps://ldap.example.org -D "$ADMIN_DN" -w falsch
assert_contains "FQDN als SAN enthalten" "DNS:ldap.example.org" \
  dexec ldap openssl x509 -in /etc/ldap/certs/server.crt -noout -ext subjectAltName
assert_contains "Container-Hostname als SAN enthalten" "DNS:ldap," \
  dexec ldap openssl x509 -in /etc/ldap/certs/server.crt -noout -ext subjectAltName
assert_fail "Client lehnt fremde CA ab" \
  with_ca /fixtures/certs/ca.crt ldap_admin ldap ldapwhoami
assert_ok "TLS 1.2 akzeptiert" \
  client openssl s_client -connect ldap.example.org:636 -tls1_2 -CAfile /work/server.crt -verify_return_error
assert_fail "TLS 1.1 abgelehnt" \
  client openssl s_client -connect ldap.example.org:636 -tls1_1 -cipher 'DEFAULT:@SECLEVEL=0'

section "Zertifikat bleibt ueber Neustarts erhalten"
before="$(dexec ldap sha256sum /etc/ldap/certs/server.crt)"
restart_ldap ldap
assert_ok "Gleiches Zertifikat nach Neustart" \
  test "$before" = "$(dexec ldap sha256sum /etc/ldap/certs/server.crt)"
unset CLIENT_CA

section "LDAP_TLS_ENFORCE=false"
start_ldap ldap-b "${TLS_OPTS[@]}" -e LDAP_TLS_ENFORCE=false
wait_healthy ldap-b
assert_ok "Klartext-Bind erlaubt" \
  client ldapwhoami -x -H ldap://ldap-b -D "$ADMIN_DN" -w "$ADMIN_PW"

finish
