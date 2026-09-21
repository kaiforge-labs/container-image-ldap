#!/usr/bin/env bash
# Gemeinsame Hilfsfunktionen fuer die Integrationstests
# shellcheck disable=SC2034
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/tests/fixtures"
IMAGE="${IMAGE:-ldap-debian:test}"
RUN_ID="lt-$(basename "$0" .sh)-$$"
NET="$RUN_ID"
WORK="$(mktemp -d)"
chmod 777 "$WORK"
FAILED=0

BASE="dc=example,dc=org"
ADMIN_DN="cn=admin,$BASE"
ADMIN_PW="$(cat "$FIXTURES/secrets/admin_password")"
REPL_DN="cn=replicator,$BASE"
REPL_PW="$(cat "$FIXTURES/secrets/replication_password")"
DB_DN='olcDatabase={1}mdb,cn=config'

HEALTH_OPTS=(--health-interval=2s --health-timeout=5s --health-start-period=60s --health-retries=3)
TLS_OPTS=(-v "$FIXTURES/certs:/tls:ro"
          -e LDAP_TLS_CERT_FILE=/tls/server.crt
          -e LDAP_TLS_KEY_FILE=/tls/server.key)
REPL_SECRET=(-v "$FIXTURES/secrets/replication_password:/run/secrets/ldap_replication_password:ro")
REPL_OPTS=("${REPL_SECRET[@]}"
           -e "LDAP_REPLICATION_BIND_DN=$REPL_DN"
           -e LDAP_REPLICATION_CA_FILE=/tls/ca.crt)

# ---------- Ausgabe ----------
section() { printf '\n== %s\n' "$*"; }
pass()    { printf '  [OK]   %s\n' "$*"; }
failt()   { printf '  [FAIL] %s\n' "$*"; FAILED=1; }
# shellcheck disable=SC2001 # ${var//search/replace} kann keine mehrzeilige Prefix-Ersetzung
indent()  { sed 's/^/         /' <<<"$1"; }
finish() {
  if [ "$FAILED" -eq 0 ]; then printf '\nErgebnis: OK\n'; exit 0; fi
  printf '\nErgebnis: FEHLGESCHLAGEN\n'; exit 1
}

# ---------- Aufraeumen ----------
cleanup() {
  local rc=$? c
  if [ "$rc" -ne 0 ]; then
    for c in $(docker ps -aq --filter "label=ldaptest=$RUN_ID"); do
      printf '\n----- Logs %s -----\n' "$(docker inspect -f '{{.Name}}' "$c")"
      docker logs --tail 100 "$c" 2>&1 || true
    done
  fi
  docker ps -aq --filter "label=ldaptest=$RUN_ID" | xargs -r docker rm -fv >/dev/null
  docker volume ls -q --filter "label=ldaptest=$RUN_ID" | xargs -r docker volume rm >/dev/null
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT
docker network create --label "ldaptest=$RUN_ID" "$NET" >/dev/null

# ---------- Container ----------
cname() { echo "$RUN_ID-$1"; }
dexec() { docker exec "$(cname "$1")" "${@:2}"; }

vol() { # vol <name> -> Volume anlegen, Namen ausgeben
  local v="$RUN_ID-$1"
  docker volume inspect "$v" >/dev/null 2>&1 \
    || docker volume create --label "ldaptest=$RUN_ID" "$v" >/dev/null
  echo "$v"
}

start_ldap() { # start_ldap <name> [docker-run-optionen...]; LDAP_SECRET=none|<datei>
  local name="$1" secret=()
  shift
  if [ "${LDAP_SECRET:-}" != none ]; then
    secret=(-v "${LDAP_SECRET:-$FIXTURES/secrets/admin_password}:/run/secrets/ldap_admin_password:ro")
  fi
  docker run -d --name "$(cname "$name")" --hostname "$name" \
    --network "$NET" --network-alias "$name" --network-alias "$name.example.org" \
    -l "ldaptest=$RUN_ID" \
    "${HEALTH_OPTS[@]}" "${secret[@]}" "$@" "$IMAGE" >/dev/null
}

wait_healthy() { # wait_healthy <name> [timeout]
  local c state=""
  c="$(cname "$1")"
  for _ in $(seq "${2:-120}"); do
    state="$(docker inspect -f '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$c")"
    case "$state" in
      running/healthy) pass "$1 ist healthy"; return 0 ;;
      exited/*|dead/*) break ;;
    esac
    sleep 1
  done
  failt "$1 wurde nicht healthy ($state)"
  exit 1
}

restart_ldap() { docker restart "$(cname "$1")" >/dev/null; wait_healthy "$1"; }
health_is()    { [ "$(docker inspect -f '{{.State.Health.Status}}' "$(cname "$1")")" = "$2" ]; }

expect_startup_failure() { # <beschreibung> <name> <log-regex>
  local desc="$1" pattern="$3" c state="" logs
  c="$(cname "$2")"
  for _ in $(seq 60); do
    state="$(docker inspect -f '{{.State.Status}}' "$c")"
    [ "$state" = exited ] && break
    sleep 1
  done
  logs="$(docker logs "$c" 2>&1)"
  if [ "$state" = exited ] && grep -qE -- "$pattern" <<<"$logs"; then
    pass "$desc"
  else
    failt "$desc (Status: $state)"; indent "$logs"
  fi
  docker rm -fv "$c" >/dev/null
}

# ---------- LDAP-Clients ----------
client() { # Fuehrt ein Kommando in einem Client-Container im Testnetz aus
  local extra=()
  if [ -n "${CLIENT_CERT:-}" ]; then
    extra=(-e "LDAPTLS_CERT=$CLIENT_CERT" -e "LDAPTLS_KEY=$CLIENT_KEY")
  fi
  docker run --rm --network "$NET" --entrypoint "" \
    -v "$FIXTURES:/fixtures:ro" -v "$WORK:/work" \
    -e "LDAPTLS_CACERT=${CLIENT_CA:-/fixtures/certs/ca.crt}" -e LDAPTLS_REQCERT=demand \
    "${extra[@]}" "$IMAGE" "$@"
}
with_ca()     { CLIENT_CA="$1" "${@:2}"; }
with_client() { CLIENT_CERT="/fixtures/certs/$1.crt" CLIENT_KEY="/fixtures/certs/$1.key" "${@:2}"; }
with_pw()     { USER_PW="$1" "${@:2}"; }

ldap_admin() { # ldap_admin <host> <tool> [args]
  local h="$1" t="$2"; shift 2
  client "$t" -x -H "ldaps://$h" -D "$ADMIN_DN" -w "$ADMIN_PW" "$@"
}
ldap_user() { # ldap_user <host> <uid> <tool> [args]
  local h="$1" u="$2" t="$3"; shift 3
  client "$t" -x -H "ldaps://$h" -D "uid=$u,ou=people,$BASE" -w "${USER_PW:-$u-pw}" "$@"
}

load_testdata() { # load_testdata <host>
  ldap_admin "$1" ldapadd -f /fixtures/ldif/users.ldif >/dev/null
  for u in alice bob; do
    ldap_admin "$1" ldappasswd -s "$u-pw" "uid=$u,ou=people,$BASE" >/dev/null
  done
}

ldap_has() { # ldap_has <host> <dn> <attr> <regex>
  ldap_admin "$1" ldapsearch -LLL -o ldif-wrap=no -b "$2" -s base "$3" | grep -qE -- "$4"
}
ldap_absent() { # ldap_absent <host> <dn>
  local out
  out="$(ldap_admin "$1" ldapsearch -LLL -b "$2" -s base dn 2>&1)" || true
  grep -q "No such object" <<<"$out"
}
config_attr() { # config_attr <host> <attr> [dn]
  dexec "$1" ldapsearch -Q -Y EXTERNAL -H ldapi:/// -LLL -o ldif-wrap=no \
    -b "${3:-cn=config}" -s base "$2"
}
ldif_value() { # ldif_value <attr> - liest LDIF von stdin, dekodiert Base64
  local line
  while IFS= read -r line; do
    case "$line" in
      "$1:: "*) base64 -d <<<"${line#*:: }"; echo ;;
      "$1: "*)  echo "${line#*: }" ;;
    esac
  done
}
csn() {
  dexec "$1" ldapsearch -Q -Y EXTERNAL -H ldapi:/// -LLL -b "$BASE" -s base contextCSN \
    | grep '^contextCSN' | sort
}
csn_equal() { local a b; a="$(csn "$1")"; b="$(csn "$2")"; [ -n "$a" ] && [ "$a" = "$b" ]; }

# ---------- Assertions ----------
assert_ok() { # <beschreibung> <cmd...>
  local desc="$1" out; shift
  if out="$("$@" 2>&1)"; then pass "$desc"; else failt "$desc"; indent "$out"; fi
}
assert_fail() {
  local desc="$1" out; shift
  if out="$("$@" 2>&1)"; then failt "$desc (unerwartet erfolgreich)"; indent "$out"; else pass "$desc"; fi
}
assert_contains() { # <beschreibung> <regex> <cmd...>
  local desc="$1" pattern="$2" out; shift 2
  out="$("$@" 2>&1)" || true
  if grep -qE -- "$pattern" <<<"$out"; then pass "$desc"; else failt "$desc"; indent "$out"; fi
}
assert_not_contains() {
  local desc="$1" pattern="$2" out; shift 2
  out="$("$@" 2>&1)" || true
  if grep -qE -- "$pattern" <<<"$out"; then failt "$desc"; indent "$out"; else pass "$desc"; fi
}
assert_eventually() { # <beschreibung> <timeout-s> <cmd...>
  local desc="$1" timeout="$2" out=""; shift 2
  for _ in $(seq "$timeout"); do
    if out="$("$@" 2>&1)"; then pass "$desc"; return 0; fi
    sleep 1
  done
  failt "$desc (Timeout nach ${timeout}s)"; indent "$out"
}
