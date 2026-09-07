#!/bin/bash
set -euo pipefail

WEBMIN_PASSWORD="${WEBMIN_PASSWORD:-changeme}"

echo "[entrypoint] Configuration du mot de passe Webmin (utilisateur root)..."
/usr/share/webmin/changepass.pl /etc/webmin root "${WEBMIN_PASSWORD}" >/dev/null 2>&1 || true

echo "[entrypoint] Verification de la syntaxe BIND9..."
named-checkconf /etc/bind/named.conf

echo "[entrypoint] Ajustement des permissions sur /etc/bind/zones..."
chown -R root:bind /etc/bind/zones 2>/dev/null || true
chmod -R 750 /etc/bind/zones 2>/dev/null || true

echo "[entrypoint] Demarrage de supervisord (named + webmin)..."
exec /usr/bin/supervisord -n -c /etc/supervisor/conf.d/supervisord.conf
