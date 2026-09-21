#!/usr/bin/env bash
# Docker Secrets: Pflicht, Validierung, eigener Pfad, Rotation
# shellcheck source=../lib.sh
source "$(dirname "$0")/../lib.sh"

section "Fehlendes und leeres Secret"
LDAP_SECRET=none start_ldap ldap-a "${TLS_OPTS[@]}"
expect_startup_failure "Start ohne Secret bricht ab" ldap-a "Passwortdatei .* nicht lesbar"

: > "$WORK/empty"
LDAP_SECRET="$WORK/empty" start_ldap ldap-b "${TLS_OPTS[@]}"
expect_startup_failure "Leeres Secret bricht ab" ldap-b "Passwortdatei ist leer"

section "Eigener Pfad, abschliessender Zeilenumbruch"
printf 'mit-newline\n' > "$WORK/custom"
LDAP_SECRET=none start_ldap ldap-c "${TLS_OPTS[@]}" \
  -v "$WORK/custom:/secrets/custom:ro" -e LDAP_ADMIN_PASSWORD_FILE=/secrets/custom
wait_healthy ldap-c
assert_ok "Bind mit Passwort ohne Zeilenumbruch" \
  client ldapwhoami -x -H ldaps://ldap-c -D "$ADMIN_DN" -w mit-newline
docker inspect -f '{{json .Config.Env}}' "$(cname ldap-c)" > "$WORK/env.json"
assert_fail "Passwort nicht in Container-Env sichtbar" grep -q mit-newline "$WORK/env.json"

section "Passwortrotation per Neustart"
VOLS=(-v "$(vol config):/etc/ldap/slapd.d" -v "$(vol data):/var/lib/ldap")
printf 'erstes' > "$WORK/pw1"
printf 'zweites' > "$WORK/pw2"

LDAP_SECRET="$WORK/pw1" start_ldap ldap "${TLS_OPTS[@]}" "${VOLS[@]}"
wait_healthy ldap
assert_ok "Bind mit erstem Passwort" \
  client ldapwhoami -x -H ldaps://ldap -D "$ADMIN_DN" -w erstes
docker rm -f "$(cname ldap)" >/dev/null

LDAP_SECRET="$WORK/pw2" start_ldap ldap "${TLS_OPTS[@]}" "${VOLS[@]}"
wait_healthy ldap
assert_ok "Bind mit neuem Passwort" \
  client ldapwhoami -x -H ldaps://ldap -D "$ADMIN_DN" -w zweites
assert_fail "Altes Passwort ungueltig" \
  client ldapwhoami -x -H ldaps://ldap -D "$ADMIN_DN" -w erstes

finish
