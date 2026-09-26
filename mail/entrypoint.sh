#!/bin/bash
set -euo pipefail

log() { echo "[entrypoint] $*"; }
die() { echo "[entrypoint] ERREUR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Variables (voir .env.example pour la documentation)
# ---------------------------------------------------------------------------
: "${MAIL_HOSTNAME:?MAIL_HOSTNAME doit etre defini (ex: mail.example.com)}"
: "${MAIL_DOMAINS:?MAIL_DOMAINS doit etre defini (ex: example.com,example.org)}"
: "${LDAP_BASE_DN:?LDAP_BASE_DN doit etre defini (ex: dc=example,dc=com)}"
: "${LDAP_BIND_DN:?LDAP_BIND_DN doit etre defini}"
: "${LDAP_BIND_PASSWORD:?LDAP_BIND_PASSWORD doit etre defini}"

# Liste des domaines : "a.com, b.org" -> "a.com b.org"
MAIL_DOMAINS="$(echo "${MAIL_DOMAINS}" | tr ',;' '  ' | xargs)"
export MAIL_PRIMARY_DOMAIN="${MAIL_PRIMARY_DOMAIN:-${MAIL_DOMAINS%% *}}"
export MAIL_DOMAINS_POSTFIX="${MAIL_DOMAINS// /, }"
export MAIL_HOSTNAME
export MAIL_RELAYHOST="${MAIL_RELAYHOST:-}"
export MAIL_EXTRA_MYNETWORKS="${MAIL_EXTRA_MYNETWORKS:-}"
export MAIL_MESSAGE_SIZE_LIMIT="${MAIL_MESSAGE_SIZE_LIMIT:-52428800}"

export LDAP_URI="${LDAP_URI:-ldap://openldap:389}"
export LDAP_BASE_DN LDAP_BIND_DN LDAP_BIND_PASSWORD
export LDAP_USER_BASE="${LDAP_USER_BASE:-ou=users,${LDAP_BASE_DN}}"
export LDAP_USER_OBJECTCLASS="${LDAP_USER_OBJECTCLASS:-inetOrgPerson}"
export LDAP_MAIL_ATTRIBUTE="${LDAP_MAIL_ATTRIBUTE:-mail}"
export LDAP_LOGIN_ATTRIBUTE="${LDAP_LOGIN_ATTRIBUTE:-uid}"
export LDAP_MAIL_GROUP_DN="${LDAP_MAIL_GROUP_DN:-cn=mail,ou=groups,${LDAP_BASE_DN}}"
# Filtre d'appartenance au groupe "mail" ajoute a toutes les requetes LDAP.
# Par defaut : overlay memberOf (groupOfNames / groupOfUniqueNames).
export LDAP_GROUP_FILTER="${LDAP_GROUP_FILTER:-(memberOf=${LDAP_MAIL_GROUP_DN})}"
LDAP_START_TLS="${LDAP_START_TLS:-no}"
case "${LDAP_START_TLS,,}" in
    yes|true|1) export LDAP_START_TLS_POSTFIX=yes LDAP_START_TLS_DOVECOT=yes ;;
    *)          export LDAP_START_TLS_POSTFIX=no  LDAP_START_TLS_DOVECOT=no ;;
esac

export SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/mail-certs/fullchain.pem}"
export SSL_KEY_FILE="${SSL_KEY_FILE:-/etc/mail-certs/privkey.pem}"
DKIM_SELECTOR="${DKIM_SELECTOR:-mail}"
DKIM_KEY_BITS="${DKIM_KEY_BITS:-2048}"

export DOVECOT_AUTH_VERBOSE="${DOVECOT_AUTH_VERBOSE:-yes}"
export DOVECOT_AUTH_DEBUG="${DOVECOT_AUTH_DEBUG:-no}"

# Seules ces variables sont remplacees dans les templates : les "$variable"
# propres a Postfix/Dovecot (ex: $mydomain, ${data_directory}) sont conservees.
TEMPLATE_VARS='${MAIL_HOSTNAME} ${MAIL_PRIMARY_DOMAIN} ${MAIL_DOMAINS_POSTFIX}
${MAIL_RELAYHOST} ${MAIL_EXTRA_MYNETWORKS} ${MAIL_MESSAGE_SIZE_LIMIT}
${LDAP_URI} ${LDAP_BIND_DN} ${LDAP_BIND_PASSWORD} ${LDAP_USER_BASE}
${LDAP_USER_OBJECTCLASS} ${LDAP_MAIL_ATTRIBUTE} ${LDAP_LOGIN_ATTRIBUTE}
${LDAP_GROUP_FILTER} ${LDAP_START_TLS_POSTFIX} ${LDAP_START_TLS_DOVECOT}
${SSL_CERT_FILE} ${SSL_KEY_FILE} ${DOVECOT_AUTH_VERBOSE} ${DOVECOT_AUTH_DEBUG}'

render() { envsubst "${TEMPLATE_VARS}" < "$1" > "$2"; }

# ---------------------------------------------------------------------------
# Certificat TLS
# ---------------------------------------------------------------------------
if [ ! -s "${SSL_CERT_FILE}" ] || [ ! -s "${SSL_KEY_FILE}" ]; then
    log "Aucun certificat trouve (${SSL_CERT_FILE}) : generation d'un certificat AUTO-SIGNE."
    log "  -> en production, montez un certificat valide (ex: Let's Encrypt)."
    export SSL_CERT_FILE=/etc/ssl/mail/selfsigned.crt
    export SSL_KEY_FILE=/etc/ssl/mail/selfsigned.key
    mkdir -p /etc/ssl/mail
    if [ ! -s "${SSL_CERT_FILE}" ]; then
        openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
            -subj "/CN=${MAIL_HOSTNAME}" \
            -addext "subjectAltName=DNS:${MAIL_HOSTNAME}" \
            -keyout "${SSL_KEY_FILE}" -out "${SSL_CERT_FILE}" >/dev/null 2>&1
        chmod 600 "${SSL_KEY_FILE}"
    fi
fi

# ---------------------------------------------------------------------------
# Postfix
# ---------------------------------------------------------------------------
log "Configuration de Postfix (${MAIL_HOSTNAME}, domaines : ${MAIL_DOMAINS})"
echo "${MAIL_HOSTNAME}" > /etc/mailname
for f in main.cf master.cf ldap-virtual-mailbox-maps.cf ldap-sender-login-maps.cf; do
    render "/templates/postfix/${f}" "/etc/postfix/${f}"
done
chown root:postfix /etc/postfix/ldap-*.cf
chmod 640 /etc/postfix/ldap-*.cf

# Alias virtuels optionnels (fichier monte depuis l'hote)
if [ -f /etc/mail-config/virtual_aliases ]; then
    cp /etc/mail-config/virtual_aliases /etc/postfix/virtual_aliases
else
    : > /etc/postfix/virtual_aliases
fi

# Resolution DNS pour les processus Postfix
mkdir -p /var/spool/postfix/etc
cp -f /etc/resolv.conf /etc/hosts /etc/services /var/spool/postfix/etc/ 2>/dev/null || true
postfix set-permissions >/dev/null 2>&1 || true
postfix check

# ---------------------------------------------------------------------------
# Dovecot
# ---------------------------------------------------------------------------
log "Configuration de Dovecot (LDAP : ${LDAP_URI}, groupe : ${LDAP_GROUP_FILTER})"
render /templates/dovecot/dovecot.conf /etc/dovecot/dovecot.conf
render /templates/dovecot/dovecot-ldap.conf.ext /etc/dovecot/dovecot-ldap.conf.ext
chown root:dovecot /etc/dovecot/dovecot-ldap.conf.ext
chmod 640 /etc/dovecot/dovecot-ldap.conf.ext
mkdir -p /var/mail/vhosts
chown vmail:vmail /var/mail/vhosts
doveconf -n >/dev/null

# ---------------------------------------------------------------------------
# OpenDKIM : une cle par domaine, generee si absente
# ---------------------------------------------------------------------------
log "Configuration d'OpenDKIM (selecteur : ${DKIM_SELECTOR})"
render /templates/opendkim/opendkim.conf /etc/opendkim.conf
mkdir -p /etc/opendkim/keys /run/opendkim
: > /etc/opendkim/KeyTable
: > /etc/opendkim/SigningTable
printf '127.0.0.1\n::1\nlocalhost\n%s\n' "${MAIL_HOSTNAME}" > /etc/opendkim/TrustedHosts
for net in ${MAIL_EXTRA_MYNETWORKS}; do echo "${net}" >> /etc/opendkim/TrustedHosts; done

for domain in ${MAIL_DOMAINS}; do
    keydir="/etc/opendkim/keys/${domain}"
    mkdir -p "${keydir}"
    if [ ! -s "${keydir}/${DKIM_SELECTOR}.private" ]; then
        log "  Generation de la cle DKIM ${DKIM_KEY_BITS} bits pour ${domain}"
        opendkim-genkey -b "${DKIM_KEY_BITS}" -h sha256 -r -s "${DKIM_SELECTOR}" -d "${domain}" -D "${keydir}"
    fi
    echo "${DKIM_SELECTOR}._domainkey.${domain} ${domain}:${DKIM_SELECTOR}:${keydir}/${DKIM_SELECTOR}.private" >> /etc/opendkim/KeyTable
    echo "*@${domain} ${DKIM_SELECTOR}._domainkey.${domain}" >> /etc/opendkim/SigningTable
done
chown -R opendkim:opendkim /etc/opendkim /run/opendkim
chmod 700 /etc/opendkim/keys
find /etc/opendkim/keys -name '*.private' -exec chmod 600 {} +

# ---------------------------------------------------------------------------
# Verification de la connexion LDAP (non bloquante)
# ---------------------------------------------------------------------------
ldap_tls_opt=""
[ "${LDAP_START_TLS_POSTFIX}" = "yes" ] && ldap_tls_opt="-ZZ"
if count=$(ldapsearch -x -LLL ${ldap_tls_opt} -o nettimeout=5 -H "${LDAP_URI}" \
        -D "${LDAP_BIND_DN}" -w "${LDAP_BIND_PASSWORD}" -b "${LDAP_USER_BASE}" \
        "(&(objectClass=${LDAP_USER_OBJECTCLASS})${LDAP_GROUP_FILTER})" "${LDAP_MAIL_ATTRIBUTE}" 2>/dev/null \
        | grep -c "^${LDAP_MAIL_ATTRIBUTE}:"); then
    log "LDAP OK : ${count} compte(s) mail trouve(s) dans le groupe."
else
    log "ATTENTION : LDAP injoignable ou aucun membre du groupe mail trouve (${LDAP_URI})."
fi

# ---------------------------------------------------------------------------
# Enregistrements DNS a publier (a copier dans la zone BIND9)
# ---------------------------------------------------------------------------
{
    echo "; ==== Enregistrements DNS a ajouter pour le serveur mail ===="
    for domain in ${MAIL_DOMAINS}; do
        echo "; --- zone ${domain}"
        echo "@                        IN MX 10 ${MAIL_HOSTNAME}."
        echo "@                        IN TXT \"v=spf1 mx -all\""
        echo "_dmarc                   IN TXT \"v=DMARC1; p=quarantine; rua=mailto:postmaster@${domain}\""
        cat "/etc/opendkim/keys/${domain}/${DKIM_SELECTOR}.txt"
    done
} | tee /etc/opendkim/keys/DNS-RECORDS.txt

log "Demarrage de supervisord (rsyslog, opendkim, dovecot, postfix)..."
exec /usr/bin/supervisord -n -c /etc/supervisor/conf.d/supervisord.conf
