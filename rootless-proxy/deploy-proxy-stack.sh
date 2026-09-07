#!/usr/bin/env bash
set -euo pipefail

# deploy-proxy-stack.sh
#
# Déploie Nginx Proxy Manager + Dockhand dans /app/proxy, exécutés par le
# Docker rootless de l'utilisateur dédié (voir install-docker-rootless.sh).
# Seul Nginx Proxy Manager publie des ports sur l'hôte (80/443/81) : Dockhand
# reste uniquement accessible via le réseau docker interne, afin que tout le
# trafic passe bien par ce proxy.
#
# Usage :
#   sudo ./deploy-proxy-stack.sh [nom_utilisateur]
#
# À lancer après install-docker-rootless.sh, depuis le dossier du dépôt
# (rootless-proxy/).

DOCKER_USER="${1:-dockerapp}"
APP_DIR="/app"
PROXY_DIR="${APP_DIR}/proxy"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { echo -e "\n\033[1;32m==> $*\033[0m"; }
err()  { echo -e "\033[1;31mErreur : $*\033[0m" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "Ce script doit être exécuté en root (sudo)."
id "${DOCKER_USER}" &>/dev/null || err "Utilisateur ${DOCKER_USER} introuvable. Lancez d'abord install-docker-rootless.sh."

USER_UID="$(id -u "${DOCKER_USER}")"
USER_HOME="$(getent passwd "${DOCKER_USER}" | cut -d: -f6)"
SOCK="/run/user/${USER_UID}/docker.sock"

[[ -S "${SOCK}" ]] || err "Le socket Docker rootless ${SOCK} n'existe pas. Le service docker de ${DOCKER_USER} tourne-t-il ? (systemctl --user status docker)"

# 1. Arborescence /app/proxy -------------------------------------------------
log "Préparation de ${PROXY_DIR}"
mkdir -p "${PROXY_DIR}"/{npm/data,npm/letsencrypt,dockhand/data}

cp "${SCRIPT_DIR}/docker-compose.yml" "${PROXY_DIR}/docker-compose.yml"
echo "DOCKER_SOCK=${SOCK}" > "${PROXY_DIR}/.env"

chown -R "${DOCKER_USER}:${DOCKER_USER}" "${APP_DIR}"

# 2. (optionnel) ouverture du pare-feu ufw -----------------------------------
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  log "Ouverture des ports 80/443/81 dans ufw"
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 81/tcp   # interface d'admin NPM — à restreindre à votre IP en prod
fi

# 3. Déploiement via Docker Compose, en tant qu'utilisateur rootless --------
log "Démarrage de la stack (nginx-proxy-manager + dockhand)"
su - "${DOCKER_USER}" -c "
  export XDG_RUNTIME_DIR=/run/user/${USER_UID}
  export DOCKER_HOST=unix:///run/user/${USER_UID}/docker.sock
  export PATH=${USER_HOME}/bin:\${PATH}
  cd ${PROXY_DIR}
  docker compose pull
  docker compose up -d
"

log "Stack déployée."
cat <<EOF

Nginx Proxy Manager :
  - Admin        : http://<IP_DE_LA_VM>:81
  - Identifiants par défaut : admin@example.com / changeme
    (à changer immédiatement à la première connexion)
  - HTTP/HTTPS   : ports 80 et 443 de la VM

Dockhand :
  - N'est PAS exposé directement sur l'hôte.
  - Dans Nginx Proxy Manager, créez un "Proxy Host" (Hosts > Proxy Hosts)
    avec comme "Forward Hostname / IP" : dockhand, et "Forward Port" : 3000.
  - Attachez-y un certificat SSL (Let's Encrypt) si le nom de domaine
    pointe déjà vers la VM.

Fichiers déployés dans : ${PROXY_DIR}
EOF
