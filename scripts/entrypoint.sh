#!/bin/bash
set -euo pipefail

# ---------- Konfiguration ----------
LDAP_DOMAIN="${LDAP_DOMAIN:-example.org}"
LDAP_ORG="${LDAP_ORG:-Example Inc}"
LDAP_ADMIN_PASSWORD_FILE="${LDAP_ADMIN_PASSWORD_FILE:-/run/secrets/ldap_admin_password}"
LDAP_TLS_CERT_FILE="${LDAP_TLS_CERT_FILE:-/etc/ldap/certs/server.crt}"
LDAP_TLS_KEY_FILE="${LDAP_TLS_KEY_FILE:-/etc/ldap/certs/server.key}"
LDAP_TLS_CA_FILE="${LDAP_TLS_CA_FILE:-}"
LDAP_TLS_HOSTNAME="${LDAP_TLS_HOSTNAME:-ldap.${LDAP_DOMAIN}}"
LDAP_TLS_DAYS="${LDAP_TLS_DAYS:-365}"
LDAP_TLS_ENFORCE="${LDAP_TLS_ENFORCE:-true}"
LDAP_TLS_VERIFY_CLIENT="${LDAP_TLS_VERIFY_CLIENT:-never}"
LDAP_OVERRIDES_DIR="${LDAP_OVERRIDES_DIR:-/etc/ldap/overrides.d}"
LDAP_LOG_LEVEL="${LDAP_LOG_LEVEL:-0}"
LDAP_RESTORE_FROM="${LDAP_RESTORE_FROM:-}"

LDAP_REPLICATION_MODE="${LDAP_REPLICATION_MODE:-none}"
LDAP_SERVER_ID="${LDAP_SERVER_ID:-}"
LDAP_REPLICATION_PEERS="${LDAP_REPLICATION_PEERS:-}"
LDAP_REPLICATION_BIND_DN="${LDAP_REPLICATION_BIND_DN:-}"
LDAP_REPLICATION_PASSWORD_FILE="${LDAP_REPLICATION_PASSWORD_FILE:-/run/secrets/ldap_replication_password}"
LDAP_REPLICATION_CA_FILE="${LDAP_REPLICATION_CA_FILE:-/etc/ssl/certs/ca-certificates.crt}"
if [ "$LDAP_REPLICATION_MODE" = consumer ]; then DEFAULT_SEED=false; else DEFAULT_SEED=true; fi
LDAP_REPLICATION_SEED="${LDAP_REPLICATION_SEED:-$DEFAULT_SEED}"

TLS_RUNTIME=/etc/ldap/tls-runtime
READY_FLAG=/run/slapd/.ready
DB_DN='olcDatabase={1}mdb,cn=config'
FIRST_RUN=false
REPL_PW=""

log()     { echo "[entrypoint] $*"; }
fail()    { echo "[entrypoint] FEHLER: $*" >&2; exit 1; }
ldapmod() { ldapmodify -Q -Y EXTERNAL -H ldapi:/// "$@"; }

# LDIF von stdin anwenden; 16/20/68 (fehlt/existiert bereits) tolerieren
apply_ldif() {
  local out
  out="$(ldapmod -c 2>&1)" || true
  [ -n "$out" ] && echo "$out"
  if grep -E '^(ldap_[a-z_]+: .*\([0-9]+\)|ldapmodify: invalid format.*)$' <<<"$out" \
       | grep -qvE '\((16|20|68)\)$'; then
    return 1
  fi
}

# ---------- Validierung ----------
case "$LDAP_TLS_VERIFY_CLIENT" in
  never|allow|try|demand) ;;
  *) fail "LDAP_TLS_VERIFY_CLIENT muss never, allow, try oder demand sein" ;;
esac

IS_PROVIDER=false; IS_CONSUMER=false
case "$LDAP_REPLICATION_MODE" in
  none) ;;
  provider)       IS_PROVIDER=true ;;
  consumer)       IS_CONSUMER=true ;;
  multi-provider) IS_PROVIDER=true; IS_CONSUMER=true
    # shellcheck disable=SC2015 # reine Bedingungspruefungen ohne Nebenwirkungen, fail() beendet bei jedem Fehlerfall
    [[ "$LDAP_SERVER_ID" =~ ^[0-9]+$ ]] && [ "$LDAP_SERVER_ID" -ge 1 ] \
      && [ "$LDAP_SERVER_ID" -le 4095 ] || fail "LDAP_SERVER_ID (1-4095) fehlt" ;;
  *) fail "LDAP_REPLICATION_MODE muss none, provider, consumer oder multi-provider sein" ;;
esac

if [ "$LDAP_REPLICATION_MODE" != none ]; then
  [[ "$LDAP_REPLICATION_BIND_DN" == cn=* ]] || fail "LDAP_REPLICATION_BIND_DN muss mit cn= beginnen"
  [ -r "$LDAP_REPLICATION_PASSWORD_FILE" ] || fail "Replikations-Passwortdatei nicht lesbar"
  REPL_PW="$(cat "$LDAP_REPLICATION_PASSWORD_FILE")"
  [ -n "$REPL_PW" ] || fail "Replikations-Passwort ist leer"
  [[ "$REPL_PW" != *[\"\\]* ]] || fail "Replikations-Passwort darf kein \" oder \\ enthalten"
fi
if $IS_CONSUMER; then
  [ -n "$LDAP_REPLICATION_PEERS" ] || fail "LDAP_REPLICATION_PEERS fehlt"
fi

mkdir -p /run/slapd
chown openldap:openldap /run/slapd
rm -f "$READY_FLAG"

# ---------- Admin-Passwort aus Secret ----------
[ -r "$LDAP_ADMIN_PASSWORD_FILE" ] || fail "Passwortdatei $LDAP_ADMIN_PASSWORD_FILE nicht lesbar"
ADMIN_PW="$(cat "$LDAP_ADMIN_PASSWORD_FILE")"
[ -n "$ADMIN_PW" ] || fail "Passwortdatei ist leer"

# ---------- Erstinitialisierung oder Restore ----------
if [ -z "$(ls -A /etc/ldap/slapd.d 2>/dev/null)" ]; then
  if [ -n "$LDAP_RESTORE_FROM" ]; then
    log "Restore aus $LDAP_RESTORE_FROM"
    for part in config data; do
      [ -r "$LDAP_RESTORE_FROM/$part.ldif.gz" ] || fail "$LDAP_RESTORE_FROM/$part.ldif.gz fehlt"
    done
    [ -z "$(ls -A /var/lib/ldap 2>/dev/null)" ] || fail "/var/lib/ldap ist nicht leer"
    zcat "$LDAP_RESTORE_FROM/config.ldif.gz" | slapadd -F /etc/ldap/slapd.d -n 0
    zcat "$LDAP_RESTORE_FROM/data.ldif.gz"   | slapadd -F /etc/ldap/slapd.d -n 1 -q
  else
    FIRST_RUN=true
    log "Erstinitialisierung fuer $LDAP_DOMAIN"
    debconf-set-selections <<EOF
slapd slapd/no_configuration boolean false
slapd slapd/domain string ${LDAP_DOMAIN}
slapd shared/organization string ${LDAP_ORG}
slapd slapd/password1 password ${ADMIN_PW}
slapd slapd/password2 password ${ADMIN_PW}
slapd slapd/purge_database boolean true
slapd slapd/move_old_database boolean true
EOF
    dpkg-reconfigure -f noninteractive slapd
    if [ "$LDAP_REPLICATION_SEED" != true ]; then
      log "Kein Seed-Knoten - Datenbank bleibt leer, Daten kommen per Replikation"
      rm -rf /var/lib/ldap/*
    fi
  fi
fi

# ---------- Zertifikate ----------
if [ ! -f "$LDAP_TLS_CERT_FILE" ] && [ ! -f "$LDAP_TLS_KEY_FILE" ]; then
  log "Kein Serverzertifikat gefunden - erzeuge Self-Signed fuer $LDAP_TLS_HOSTNAME"
  mkdir -p "$(dirname "$LDAP_TLS_CERT_FILE")" "$(dirname "$LDAP_TLS_KEY_FILE")"
  openssl req -x509 -newkey rsa:4096 -nodes -days "$LDAP_TLS_DAYS" \
    -keyout "$LDAP_TLS_KEY_FILE" -out "$LDAP_TLS_CERT_FILE" \
    -subj "/CN=${LDAP_TLS_HOSTNAME}" \
    -addext "subjectAltName=DNS:${LDAP_TLS_HOSTNAME},DNS:$(hostname),DNS:localhost,IP:127.0.0.1"
elif [ ! -f "$LDAP_TLS_CERT_FILE" ] || [ ! -f "$LDAP_TLS_KEY_FILE" ]; then
  fail "Zertifikat und Key muessen beide vorhanden sein"
fi

CA_SRC="${LDAP_TLS_CA_FILE:-/etc/ssl/certs/ca-certificates.crt}"
[ -r "$CA_SRC" ] || fail "CA-Datei $CA_SRC nicht lesbar"

mkdir -p "$TLS_RUNTIME"
cp "$LDAP_TLS_CERT_FILE" "$TLS_RUNTIME/server.crt"
cp "$LDAP_TLS_KEY_FILE"  "$TLS_RUNTIME/server.key"
cp "$CA_SRC"             "$TLS_RUNTIME/ca.crt"
if $IS_CONSUMER; then
  [ -r "$LDAP_REPLICATION_CA_FILE" ] || fail "LDAP_REPLICATION_CA_FILE nicht lesbar"
  cp "$LDAP_REPLICATION_CA_FILE" "$TLS_RUNTIME/repl-ca.crt"
fi
chown -R openldap:openldap "$TLS_RUNTIME"
chmod 700 "$TLS_RUNTIME"; chmod 600 "$TLS_RUNTIME/server.key"

chown -R openldap:openldap /etc/ldap/slapd.d /var/lib/ldap

# ---------- Temporaerer slapd fuer Konfiguration ----------
/usr/sbin/slapd -h "ldapi:///" -u openldap -g openldap -F /etc/ldap/slapd.d -d 0 &
TMP_PID=$!
for i in $(seq 1 30); do
  ldapsearch -Q -Y EXTERNAL -H ldapi:/// -b cn=config -s base dn >/dev/null 2>&1 && break
  [ "$i" -eq 30 ] && fail "Temporaerer slapd startet nicht"
  sleep 1
done

# ---------- Presets: nur beim ersten Start ----------
if $FIRST_RUN; then
  MODULES="memberof refint"
  ls /usr/lib/ldap/argon2.so* >/dev/null 2>&1 && MODULES="$MODULES argon2"
  for m in $MODULES; do
    log "Lade Modul $m"
    ldapmod <<EOF
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: $m
EOF
  done

  log "Aktiviere Overlays memberof und refint"
  ldapmod <<EOF
dn: olcOverlay=memberof,${DB_DN}
changetype: add
objectClass: olcOverlayConfig
objectClass: olcMemberOf
olcOverlay: memberof
olcMemberOfRefInt: TRUE
olcMemberOfGroupOC: groupOfNames
olcMemberOfMemberAD: member
olcMemberOfMemberOfAD: memberOf

dn: olcOverlay=refint,${DB_DN}
changetype: add
objectClass: olcOverlayConfig
objectClass: olcRefintConfig
olcOverlay: refint
olcRefintAttribute: memberof member manager owner
EOF

  if [[ "$MODULES" == *argon2* ]]; then
    ldapmod <<EOF
dn: olcDatabase={-1}frontend,cn=config
changetype: modify
replace: olcPasswordHash
olcPasswordHash: {ARGON2}
EOF
  fi
fi

# ---------- Presets: bei jedem Start ----------
LOADED_MODULES="$(ldapsearch -Q -Y EXTERNAL -H ldapi:/// -LLL \
  -b 'cn=module{0},cn=config' olcModuleLoad 2>/dev/null)"
if [[ "$LOADED_MODULES" == *argon2* ]]; then
  HASH_OPTS=(-o module-path=/usr/lib/ldap -o module-load=argon2 -h '{ARGON2}')
else
  HASH_OPTS=(-h '{SSHA}')
fi
hash_pw() {
  local tmp; tmp="$(mktemp)"
  printf '%s' "$1" > "$tmp"
  slappasswd "${HASH_OPTS[@]}" -T "$tmp"
  rm -f "$tmp"
}
ROOT_HASH="$(hash_pw "$ADMIN_PW")"

REPL_BY=""
[ -n "$LDAP_REPLICATION_BIND_DN" ] && REPL_BY="by dn.exact=\"${LDAP_REPLICATION_BIND_DN}\" read "

log "Setze TLS (VerifyClient=$LDAP_TLS_VERIFY_CLIENT), Haertung und Admin-Passwort"
ldapmod <<EOF
dn: cn=config
changetype: modify
replace: olcTLSCACertificateFile
olcTLSCACertificateFile: ${TLS_RUNTIME}/ca.crt
-
replace: olcTLSCertificateFile
olcTLSCertificateFile: ${TLS_RUNTIME}/server.crt
-
replace: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: ${TLS_RUNTIME}/server.key
-
replace: olcTLSVerifyClient
olcTLSVerifyClient: ${LDAP_TLS_VERIFY_CLIENT}
-
replace: olcTLSProtocolMin
olcTLSProtocolMin: 3.3
-
replace: olcLocalSSF
olcLocalSSF: 128
-
replace: olcDisallows
olcDisallows: bind_anon

dn: olcDatabase={-1}frontend,cn=config
changetype: modify
replace: olcRequires
olcRequires: authc

dn: ${DB_DN}
changetype: modify
replace: olcRootPW
olcRootPW: ${ROOT_HASH}
-
replace: olcAccess
olcAccess: {0}to * by dn.exact=gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth manage by * break
olcAccess: {1}to attrs=userPassword by self write ${REPL_BY}by anonymous auth by * none
olcAccess: {2}to attrs=shadowLastChange by self write ${REPL_BY}by * none
olcAccess: {3}to * by self read ${REPL_BY}by users read by * none
EOF

if [ "$LDAP_TLS_ENFORCE" = "true" ]; then
  ldapmod <<EOF
dn: cn=config
changetype: modify
replace: olcSecurity
olcSecurity: ssf=128
EOF
else
  apply_ldif <<EOF || fail "olcSecurity konnte nicht entfernt werden"
dn: cn=config
changetype: modify
delete: olcSecurity
EOF
fi

# ---------- Replikation ----------
SUFFIX="$(ldapsearch -Q -Y EXTERNAL -H ldapi:/// -LLL -b "$DB_DN" -s base olcSuffix \
  | awk '/^olcSuffix:/ {print $2}')"

if $IS_PROVIDER; then
  log "Konfiguriere Provider (syncprov)"
  if [[ "$LOADED_MODULES" != *syncprov* ]]; then
    ldapmod <<EOF
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: syncprov
EOF
  fi

  OVERLAYS="$(ldapsearch -Q -Y EXTERNAL -H ldapi:/// -LLL -b "$DB_DN" -s one dn)"
  if [[ "$OVERLAYS" != *syncprov* ]]; then
    ldapmod <<EOF
dn: olcOverlay=syncprov,${DB_DN}
changetype: add
objectClass: olcOverlayConfig
objectClass: olcSyncProvConfig
olcOverlay: syncprov
olcSpCheckpoint: 100 10
olcSpSessionLog: 100
EOF
  fi

  apply_ldif <<EOF || fail "Indizes/Limits fuer Replikation"
dn: ${DB_DN}
changetype: modify
add: olcDbIndex
olcDbIndex: entryCSN eq

dn: ${DB_DN}
changetype: modify
add: olcDbIndex
olcDbIndex: entryUUID eq

dn: ${DB_DN}
changetype: modify
replace: olcLimits
olcLimits: dn.exact="${LDAP_REPLICATION_BIND_DN}" time.soft=unlimited time.hard=unlimited size.soft=unlimited size.hard=unlimited
EOF

  # Replikations-Account anlegen bzw. Passwort synchronisieren
  REPL_HASH="$(hash_pw "$REPL_PW")"
  if ldapsearch -Q -Y EXTERNAL -H ldapi:/// -b "$LDAP_REPLICATION_BIND_DN" -s base dn >/dev/null 2>&1; then
    ldapmod <<EOF
dn: ${LDAP_REPLICATION_BIND_DN}
changetype: modify
replace: userPassword
userPassword: ${REPL_HASH}
EOF
  elif [ "$LDAP_REPLICATION_SEED" = true ]; then
    REPL_CN="${LDAP_REPLICATION_BIND_DN%%,*}"; REPL_CN="${REPL_CN#cn=}"
    log "Lege Replikations-Account $LDAP_REPLICATION_BIND_DN an"
    ldapmod <<EOF
dn: ${LDAP_REPLICATION_BIND_DN}
changetype: add
objectClass: organizationalRole
objectClass: simpleSecurityObject
cn: ${REPL_CN}
description: Replikations-Account
userPassword: ${REPL_HASH}
EOF
  fi
fi

if $IS_CONSUMER; then
  log "Konfiguriere Consumer fuer $LDAP_REPLICATION_PEERS"
  SYNCREPL=""; FIRST_PEER=""; rid=0
  IFS=',' read -ra PEERS <<< "$LDAP_REPLICATION_PEERS"
  for peer in "${PEERS[@]}"; do
    peer="${peer//[[:space:]]/}"
    [ -n "$peer" ] || continue
    [ -n "$FIRST_PEER" ] || FIRST_PEER="$peer"
    rid=$((rid + 1))
    SYNCREPL+="olcSyncrepl: rid=$(printf '%03d' "$rid") provider=${peer} bindmethod=simple binddn=\"${LDAP_REPLICATION_BIND_DN}\" credentials=\"${REPL_PW}\" searchbase=\"${SUFFIX}\" type=refreshAndPersist retry=\"5 5 60 +\" timeout=3 tls_cacert=${TLS_RUNTIME}/repl-ca.crt tls_reqcert=demand"$'\n'
  done

  if [ "$LDAP_REPLICATION_MODE" = multi-provider ]; then
    apply_ldif <<EOF || fail "Multi-Provider-Konfiguration"
dn: cn=config
changetype: modify
replace: olcServerID
olcServerID: ${LDAP_SERVER_ID}

dn: ${DB_DN}
changetype: modify
delete: olcUpdateRef

dn: ${DB_DN}
changetype: modify
replace: olcSyncrepl
${SYNCREPL}-
replace: olcMultiProvider
olcMultiProvider: TRUE
EOF
  else
    ldapmod <<EOF
dn: ${DB_DN}
changetype: modify
replace: olcSyncrepl
${SYNCREPL}-
replace: olcUpdateRef
olcUpdateRef: ${FIRST_PEER}
EOF
  fi
else
  apply_ldif <<EOF || fail "Replikation konnte nicht deaktiviert werden"
dn: ${DB_DN}
changetype: modify
delete: olcUpdateRef

dn: ${DB_DN}
changetype: modify
delete: olcMultiProvider

dn: ${DB_DN}
changetype: modify
delete: olcSyncrepl
EOF
fi

unset ADMIN_PW REPL_PW

# ---------- Overrides ----------
if [ -d "$LDAP_OVERRIDES_DIR" ]; then
  shopt -s nullglob
  for f in "$LDAP_OVERRIDES_DIR"/*.ldif; do
    log "Lade Override $(basename "$f")"
    apply_ldif < "$f" || fail "Override $(basename "$f") fehlgeschlagen"
  done
fi

kill "$TMP_PID"; wait "$TMP_PID" 2>/dev/null || true

# ---------- Regulaerer Start ----------
touch "$READY_FLAG"
log "Starte slapd"
exec /usr/sbin/slapd -h "ldap:/// ldaps:/// ldapi:///" \
  -u openldap -g openldap -F /etc/ldap/slapd.d -d "$LDAP_LOG_LEVEL"
