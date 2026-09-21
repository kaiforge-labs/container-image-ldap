#!/usr/bin/env bash
# Client-Zertifikatspruefung (mTLS)
# shellcheck source=../lib.sh
source "$(dirname "$0")/../lib.sh"

MTLS_OPTS=("${TLS_OPTS[@]}" -e LDAP_TLS_CA_FILE=/tls/ca.crt)

section "VerifyClient=demand"
start_ldap ldap "${MTLS_OPTS[@]}" -e LDAP_TLS_VERIFY_CLIENT=demand
wait_healthy ldap
assert_contains "olcTLSVerifyClient gesetzt" "olcTLSVerifyClient: demand" \
  config_attr ldap olcTLSVerifyClient
assert_fail "Ohne Client-Zertifikat abgelehnt" ldap_admin ldap ldapwhoami
assert_ok "Mit gueltigem Client-Zertifikat" with_client client ldap_admin ldap ldapwhoami
assert_fail "Client-Zertifikat fremder CA abgelehnt" \
  with_client rogue-client ldap_admin ldap ldapwhoami
assert_contains "SASL EXTERNAL liefert Zertifikats-DN" "dn:cn=client" \
  with_client client client ldapwhoami -Q -Y EXTERNAL -H ldaps://ldap

section "VerifyClient=try"
start_ldap ldap-b "${MTLS_OPTS[@]}" -e LDAP_TLS_VERIFY_CLIENT=try
wait_healthy ldap-b
assert_ok "Ohne Client-Zertifikat erlaubt" ldap_admin ldap-b ldapwhoami
assert_ok "Mit gueltigem Client-Zertifikat" with_client client ldap_admin ldap-b ldapwhoami
assert_fail "Ungueltiges Client-Zertifikat abgelehnt" \
  with_client rogue-client ldap_admin ldap-b ldapwhoami

section "Ungueltiger Wert"
start_ldap ldap-c "${TLS_OPTS[@]}" -e LDAP_TLS_VERIFY_CLIENT=vielleicht
expect_startup_failure "Ungueltiger Wert bricht ab" ldap-c "LDAP_TLS_VERIFY_CLIENT muss"

finish
