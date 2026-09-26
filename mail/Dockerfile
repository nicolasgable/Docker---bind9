FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Empeche les paquets de tenter de demarrer leurs services pendant le build.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
    && chmod +x /usr/sbin/policy-rc.d

# Preconfiguration de Postfix pour une installation non interactive
RUN echo "postfix postfix/main_mailer_type string 'No configuration'" | debconf-set-selections \
    && echo "postfix postfix/mailname string localhost" | debconf-set-selections

RUN apt-get update && apt-get install -y --no-install-recommends \
        postfix \
        postfix-ldap \
        dovecot-core \
        dovecot-imapd \
        dovecot-lmtpd \
        dovecot-ldap \
        opendkim \
        opendkim-tools \
        rsyslog \
        supervisor \
        gettext-base \
        openssl \
        ca-certificates \
        ldap-utils \
        procps \
    && rm -rf /var/lib/apt/lists/*

# Utilisateur systeme proprietaire de toutes les boites aux lettres (virtuelles)
RUN groupadd -g 5000 vmail \
    && useradd -u 5000 -g vmail -d /var/mail/vhosts -s /usr/sbin/nologin vmail \
    && mkdir -p /var/mail/vhosts \
    && chown -R vmail:vmail /var/mail/vhosts \
    && usermod -aG opendkim postfix

COPY templates/ /templates/
COPY rsyslog.conf /etc/rsyslog.conf
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 25 = SMTP (reception), 465 = SMTPS, 587 = Submission, 143 = IMAP (STARTTLS), 993 = IMAPS
EXPOSE 25 465 587 143 993

VOLUME ["/var/mail/vhosts", "/var/spool/postfix", "/etc/opendkim/keys"]

ENTRYPOINT ["/entrypoint.sh"]
