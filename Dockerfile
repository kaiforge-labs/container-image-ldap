FROM debian:trixie-slim

LABEL org.opencontainers.image.title="ldap-debian" \
      org.opencontainers.image.description="OpenLDAP auf Debian mit TLS, mTLS, Backup und Replikation"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        slapd ldap-utils ca-certificates openssl && \
    rm -rf /var/lib/apt/lists/* /etc/ldap/slapd.d/* /var/lib/ldap/* && \
    mkdir -p /etc/ldap/certs /etc/ldap/overrides.d /var/backups/ldap

COPY --chmod=755 scripts/entrypoint.sh /entrypoint.sh
COPY --chmod=755 scripts/ldap-backup /usr/local/bin/ldap-backup

VOLUME ["/etc/ldap/slapd.d", "/var/lib/ldap", "/etc/ldap/certs", "/var/backups/ldap"]
EXPOSE 389 636

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD ["/bin/sh", "-c", "test -f /run/slapd/.ready && ldapsearch -Q -Y EXTERNAL -H ldapi:/// -b cn=config -s base dn >/dev/null || exit 1"]

ENTRYPOINT ["/entrypoint.sh"]
