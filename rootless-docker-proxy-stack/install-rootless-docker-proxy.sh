#!/usr/bin/env bash
#
# install-rootless-docker-proxy.sh
#
# Installe Docker en mode ROOTLESS sur une VM Ubuntu pour un utilisateur non
# privilégié, puis déploie une stack docker compose avec :
#   - Dockhand              (gestion web des conteneurs Docker)
#   - Nginx Proxy Manager   (reverse proxy / unique point d'entrée-sortie)
#
# Les deux conteneurs sont attachés à un réseau Docker externe nommé "proxy".
# Seul Nginx Proxy Manager publie des ports sur l'hôte (80/443/81) : tout le
# trafic entrant/sortant des conteneurs applicatifs transite donc par ce
# réseau et par NPM, qui agit comme unique passerelle. Dockhand n'expose
# aucun port host et n'est joignable que via NPM sur le réseau "proxy".
#
# La stack (docker-compose.yml + volumes des conteneurs) est déployée dans
# /app, dont la propriété est intégralement donnée à l'utilisateur Docker
# rootless (pas de fichiers appartenant à root dans cette arborescence).
#
# Usage :
#   sudo ./install-rootless-docker-proxy.sh [utilisateur]
#
# Si [utilisateur] est omis, l'utilisateur ciblé est celui qui a lancé sudo
# (SUDO_USER). Ce script doit être lancé avec sudo, mais Docker rootless est
# installé pour un utilisateur NORMAL (jamais pour root).

set -euo pipefail

# --------------------------------------------------------------------------
# 0. Vérifications préalables
# --------------------------------------------------------------------------

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Erreur : ce script doit être lancé avec sudo." >&2
  echo "  ex : sudo ./install-rootless-docker-proxy.sh" >&2
  exit 1
fi

TARGET_USER="${1:-${SUDO_USER:-}}"

if [[ -z "${TARGET_USER}" || "${TARGET_USER}" == "root" ]]; then
  echo "Erreur : impossible de déterminer un utilisateur non-root cible." >&2
  echo "  Lancez : sudo ./install-rootless-docker-proxy.sh <utilisateur>" >&2
  echo "  (Docker rootless ne doit jamais être installé pour root.)" >&2
  exit 1
fi

if ! id "${TARGET_USER}" &>/dev/null; then
  echo "Erreur : l'utilisateur '${TARGET_USER}' n'existe pas sur cette VM." >&2
  exit 1
fi

TARGET_UID="$(id -u "${TARGET_USER}")"
TARGET_GID="$(id -g "${TARGET_USER}")"
TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
STACK_DIR="/app"
PROXY_NETWORK="proxy"
XDG_RUNTIME_DIR="/run/user/${TARGET_UID}"
DOCKER_HOST_SOCK="unix://${XDG_RUNTIME_DIR}/docker.sock"

echo "==> Utilisateur ciblé pour Docker rootless : ${TARGET_USER} (uid ${TARGET_UID})"
echo "==> Répertoire de la stack : ${STACK_DIR}"

# --------------------------------------------------------------------------
# 1. Paquets nécessaires au mode rootless + dépôt officiel Docker
# --------------------------------------------------------------------------

echo "==> Installation des prérequis système..."
apt-get update
apt-get install -y \
  ca-certificates curl gnupg uidmap dbus-user-session \
  fuse-overlayfs slirp4netns

install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y \
  docker-ce-cli containerd.io docker-ce-rootless-extras \
  docker-buildx-plugin docker-compose-plugin

# --------------------------------------------------------------------------
# 2. Désactivation du démon Docker root (system-wide), s'il existe
# --------------------------------------------------------------------------

if systemctl list-unit-files | grep -q '^docker\.service'; then
  echo "==> Arrêt/désactivation du démon Docker root-full (docker.service)..."
  systemctl disable --now docker.service docker.socket || true
fi

# --------------------------------------------------------------------------
# 3. Autoriser la liaison de ports < 1024 en rootless (80/443/81 pour NPM)
# --------------------------------------------------------------------------

echo "==> Autorisation des ports privilégiés (>=80) pour les sockets non-root..."
cat > /etc/sysctl.d/99-rootless-docker-ports.conf <<EOF
net.ipv4.ip_unprivileged_port_start=80
EOF
sysctl --system >/dev/null

# --------------------------------------------------------------------------
# 4. Activation du "lingering" pour que le démon rootless survive au logout
# --------------------------------------------------------------------------

echo "==> Activation du lingering systemd pour ${TARGET_USER}..."
loginctl enable-linger "${TARGET_USER}"

# --------------------------------------------------------------------------
# 5. Installation de Docker rootless pour l'utilisateur cible
# --------------------------------------------------------------------------

echo "==> Installation de Docker rootless pour ${TARGET_USER}..."
sudo -u "${TARGET_USER}" env \
  XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
  PATH="/usr/bin:${PATH}" \
  dockerd-rootless-setuptool.sh install --force

# Variables d'environnement persistantes pour l'utilisateur cible
BASHRC="${TARGET_HOME}/.bashrc"
if ! grep -q "DOCKER_HOST=unix:///run/user" "${BASHRC}" 2>/dev/null; then
  cat >> "${BASHRC}" <<EOF

# --- Docker rootless ---
export PATH=/usr/bin:\$PATH
export DOCKER_HOST=${DOCKER_HOST_SOCK}
EOF
fi
chown "${TARGET_USER}:${TARGET_USER}" "${BASHRC}"

echo "==> Activation du service docker (utilisateur) au démarrage..."
sudo -u "${TARGET_USER}" env XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
  systemctl --user enable --now docker

# --------------------------------------------------------------------------
# 6. Préparation de la stack (réseau "proxy" + docker-compose.yml)
# --------------------------------------------------------------------------

echo "==> Création de l'arborescence de la stack dans ${STACK_DIR}..."
mkdir -p \
  "${STACK_DIR}/npm/data" \
  "${STACK_DIR}/npm/letsencrypt" \
  "${STACK_DIR}/dockhand/data"

cat > "${STACK_DIR}/docker-compose.yml" <<EOF
networks:
  ${PROXY_NETWORK}:
    external: true

services:
  nginx-proxy-manager:
    image: jc21/nginx-proxy-manager:latest
    container_name: npm
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "81:81"
    environment:
      - TZ=Europe/Paris
    volumes:
      - ./npm/data:/data
      - ./npm/letsencrypt:/etc/letsencrypt
    networks:
      - ${PROXY_NETWORK}

  dockhand:
    image: fnsys/dockhand:latest
    container_name: dockhand
    restart: unless-stopped
    environment:
      - TZ=Europe/Paris
    volumes:
      - ./dockhand/data:/app/data
      - ${XDG_RUNTIME_DIR}/docker.sock:/var/run/docker.sock:ro
    networks:
      - ${PROXY_NETWORK}
EOF

# /app appartient entièrement à l'utilisateur Docker rootless.
chown -R "${TARGET_USER}:${TARGET_GID}" "${STACK_DIR}"

# --------------------------------------------------------------------------
# 7. Création du réseau "proxy" et démarrage de la stack
# --------------------------------------------------------------------------

run_as_user() {
  sudo -u "${TARGET_USER}" env \
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
    DOCKER_HOST="${DOCKER_HOST_SOCK}" \
    PATH="/usr/bin:${PATH}" \
    "$@"
}

echo "==> Création du réseau Docker externe '${PROXY_NETWORK}'..."
if ! run_as_user docker network inspect "${PROXY_NETWORK}" &>/dev/null; then
  run_as_user docker network create "${PROXY_NETWORK}"
else
  echo "    Réseau '${PROXY_NETWORK}' déjà présent."
fi

echo "==> Démarrage de la stack (Dockhand + Nginx Proxy Manager)..."
run_as_user docker compose -f "${STACK_DIR}/docker-compose.yml" up -d

echo "==> État des conteneurs :"
run_as_user docker compose -f "${STACK_DIR}/docker-compose.yml" ps

# --------------------------------------------------------------------------
# 8. Pare-feu (ufw), si actif
# --------------------------------------------------------------------------

if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
  echo "==> Ouverture des ports NPM dans ufw (80, 443, 81/tcp)..."
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 81/tcp    # interface admin NPM — à restreindre à votre IP en prod
fi

cat <<EOF

============================================================
 Installation terminée.
============================================================

Docker rootless tourne sous l'utilisateur : ${TARGET_USER}
Socket Docker                              : ${DOCKER_HOST_SOCK}
Stack docker compose                       : ${STACK_DIR}/docker-compose.yml
Réseau Docker partagé                      : ${PROXY_NETWORK}

Nginx Proxy Manager (unique point d'entrée/sortie publié) :
  - Admin  : http://<IP_DE_LA_VM>:81
  - Login  : admin@example.com / changeme  (à changer immédiatement)
  - HTTP   : port 80   / HTTPS : port 443

Dockhand (gestion des conteneurs) :
  - Non exposé directement sur l'hôte.
  - À publier via NPM : Proxy Host -> Forward Hostname "dockhand",
    Forward Port 3000, sur le réseau "${PROXY_NETWORK}".

Pour lancer des commandes docker en tant que ${TARGET_USER} :
  su - ${TARGET_USER}
  docker ps

Tout futur conteneur applicatif doit rejoindre le réseau externe
"${PROXY_NETWORK}" pour être atteignable/proxifié via Nginx Proxy Manager,
qui reste l'unique point de sortie publié sur l'hôte.
============================================================
EOF
