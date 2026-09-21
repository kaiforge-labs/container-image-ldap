#!/usr/bin/env bash
# Erzeugt eine Test-PKI: CA, Serverzertifikat, Client-Zertifikate
set -euo pipefail

OUT="${1:-$(cd "$(dirname "$0")" && pwd)/certs}"
HOSTS="ldap ldap-a ldap-b ldap-c provider consumer ldap1 ldap2 restored"
mkdir -p "$OUT"
cd "$OUT"

ca() { # ca <datei> <cn>
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
    -keyout "$1.key" -out "$1.crt" -subj "/CN=$2" 2>/dev/null
}

leaf() { # leaf <datei> <cn> <ca> <extensions>
  openssl req -newkey rsa:2048 -nodes -keyout "$1.key" -out "$1.csr" \
    -subj "/CN=$2" 2>/dev/null
  openssl x509 -req -in "$1.csr" -CA "$3.crt" -CAkey "$3.key" -CAcreateserial \
    -days 30 -out "$1.crt" -extfile <(printf '%s\n' "$4") 2>/dev/null
  rm -f "$1.csr"
}

ca ca "LDAP Test CA"
ca rogue-ca "Rogue Test CA"

SAN=""
for h in $HOSTS; do SAN+="DNS:$h,DNS:$h.example.org,"; done
leaf server ldap ca "subjectAltName=${SAN%,}
extendedKeyUsage=serverAuth,clientAuth"
leaf client client ca "extendedKeyUsage=clientAuth"
leaf rogue-client rogue rogue-ca "extendedKeyUsage=clientAuth"

chmod 644 ./*.key
echo "Test-Zertifikate erzeugt in $OUT"
