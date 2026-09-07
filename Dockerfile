FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Empeche les paquets Debian/Ubuntu de tenter de demarrer leurs services
# pendant le build de l'image (il n'y a pas d'init system dans le conteneur).
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
    && chmod +x /usr/sbin/policy-rc.d

# BIND9 + outils DNS + dependances Webmin
RUN apt-get update && apt-get install -y --no-install-recommends \
        bind9 \
        bind9utils \
        bind9-doc \
        dnsutils \
        supervisor \
        curl \
        ca-certificates \
        perl \
        libnet-ssleay-perl \
        libauthen-pam-perl \
        libpam-runtime \
        libio-pty-perl \
        apt-transport-https \
        gnupg2 \
    && rm -rf /var/lib/apt/lists/*

# Installation de Webmin via le script officiel de gestion des depots
RUN curl -fsSL -o /tmp/setup-repos.sh https://raw.githubusercontent.com/webmin/webmin/master/setup-repos.sh \
    && sh /tmp/setup-repos.sh -f \
    && apt-get update \
    && apt-get install -y --no-install-recommends webmin \
    && rm -rf /var/lib/apt/lists/* /tmp/setup-repos.sh

# Configuration BIND9 (surchargee par les volumes du docker-compose)
COPY config/named.conf.options /etc/bind/named.conf.options
COPY config/named.conf.local /etc/bind/named.conf.local
COPY zones/ /etc/bind/zones/

RUN mkdir -p /etc/bind/zones \
    && chown -R root:bind /etc/bind/zones \
    && chmod -R 750 /etc/bind/zones

COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 53/tcp 53/udp 10000/tcp

ENTRYPOINT ["/entrypoint.sh"]
