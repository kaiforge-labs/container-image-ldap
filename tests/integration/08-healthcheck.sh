#!/usr/bin/env bash
# Healthcheck
# shellcheck source=../lib.sh
source "$(dirname "$0")/../lib.sh"

HEALTH_OPTS=(--health-interval=2s --health-timeout=5s --health-start-period=5s --health-retries=2)

start_ldap ldap "${TLS_OPTS[@]}"
wait_healthy ldap
assert_contains "Image definiert HEALTHCHECK" "ldapsearch" \
  docker image inspect -f '{{json .Config.Healthcheck}}' "$IMAGE"
assert_ok "Ready-Flag gesetzt" dexec ldap test -f /run/slapd/.ready

dexec ldap rm -f /run/slapd/.ready
assert_eventually "Container wird ohne Ready-Flag unhealthy" 30 health_is ldap unhealthy

finish
