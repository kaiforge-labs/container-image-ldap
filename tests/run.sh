#!/usr/bin/env bash
# Fuehrt alle oder ausgewaehlte Integrationstests aus
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
export IMAGE="${IMAGE:-ldap-debian:test}"

[ -f "$DIR/fixtures/certs/ca.crt" ] || "$DIR/fixtures/gen-certs.sh"
if [ "${BUILD:-1}" = 1 ]; then docker build -t "$IMAGE" "$DIR/.."; fi

tests=("$@")
[ ${#tests[@]} -gt 0 ] || tests=("$DIR"/integration/*.sh)

failed=()
for t in "${tests[@]}"; do
  printf '\n######## %s ########\n' "$(basename "$t")"
  bash "$t" || failed+=("$(basename "$t")")
done

echo
if [ ${#failed[@]} -eq 0 ]; then
  echo "Alle ${#tests[@]} Testdateien erfolgreich"
else
  printf 'Fehlgeschlagen: %s\n' "${failed[@]}"
  exit 1
fi
