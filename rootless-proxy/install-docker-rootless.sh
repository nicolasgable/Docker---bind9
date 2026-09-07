#!/usr/bin/env bash
set -euo pipefail

# install-docker-rootless.sh
#
# Installe Docker en mode "rootless" pour un utilisateur dédié sur une VM
# Ubuntu, et prépare /app (propriété de cet utilisateur) pour y déployer des
# stacks Docker Compose.
#
# Usage :
#   sudo ./install-docker-rootless.sh [nom_utilisateur]
#
# Par défaut, l'utilisateur créé/utilisé est "dockerapp".
# À lancer une seule fois par VM. Le script est idempotent : le relancer ne
# casse rien si l'utilisateur/Docker rootless existent déjà.

DOCKER_USER="${1:-dockerapp}"
APP_DIR="/app"

log()  { echo -e "\n\033[1;32m==> $*\033[0m"; }
err()  { echo -e "\033[1;31mErreur : $*\033[0m" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "Ce script doit être exécuté en root (sudo)."
command -v apt-get >/dev/null 2>&1 || err "Ce script cible Ubuntu/Debian (apt-get introuvable)."

log "Utilisateur cible pour Docker rootless : ${DOCKER_USER}"

# 1. Prérequis système pour le mode rootless -------------------------------
log "Installation des paquets requis (uidmap, dbus-user-session, slirp4netns, fuse-overlayfs...)"
apt-get update -y
apt-get install -y --no-install-recommends \
    ca-certificates curl uidmap dbus-user-session \
    fuse-overlayfs slirp4netns iptables

# 2. Création de l'utilisateur dédié ----------------------------------------
if id "${DOCKER_USER}" &>/dev/null; then
  log "L'utilisateur ${DOCKER_USER} existe déjà, réutilisation."
else
  log "Création de l'utilisateur ${DOCKER_USER}"
  adduser --disabled-password --gecos "" "${DOCKER_USER}"
fi

USER_UID="$(id -u "${DOCKER_USER}")"
USER_HOME="$(getent passwd "${DOCKER_USER}" | cut -d: -f6)"

# Plages subuid/subgid nécessaires aux user namespaces du mode rootless
grep -q "^${DOCKER_USER}:" /etc/subuid 2>/dev/null || echo "${DOCKER_USER}:100000:65536" >> /etc/subuid
grep -q "^${DOCKER_USER}:" /etc/subgid 2>/dev/null || echo "${DOCKER_USER}:100000:65536" >> /etc/subgid

# 3. Linger : permet au service Docker rootless de tourner sans session
#    ouverte et de redémarrer au boot de la VM.
log "Activation du linger pour ${DOCKER_USER}"
loginctl enable-linger "${DOCKER_USER}"

# 4. Autoriser le bind sur les ports privilégiés (80/443) sans root --------
#    Indispensable en rootless pour que Nginx Proxy Manager écoute sur 80/443.
log "Autorisation des ports 80+ pour les processus non-root (sysctl)"
cat >/etc/sysctl.d/99-rootless-docker.conf <<EOF
net.ipv4.ip_unprivileged_port_start=80
EOF
sysctl --system >/dev/null

# 5. Installation de Docker rootless pour cet utilisateur -------------------
export XDG_RUNTIME_DIR="/run/user/${USER_UID}"
mkdir -p "${XDG_RUNTIME_DIR}"
chown "${DOCKER_USER}:${DOCKER_USER}" "${XDG_RUNTIME_DIR}"

if [[ -x "${USER_HOME}/bin/dockerd-rootless.sh" ]]; then
  log "Docker rootless déjà installé pour ${DOCKER_USER}, on ne réinstalle pas."
else
  log "Installation de Docker rootless (script officiel get.docker.com/rootless)"
  su - "${DOCKER_USER}" -c "curl -fsSL https://get.docker.com/rootless | sh"
fi

# 6. Variables d'environnement persistantes pour l'utilisateur --------------
BASHRC="${USER_HOME}/.bashrc"
if ! grep -q "DOCKER_HOST=unix:///run/user" "${BASHRC}" 2>/dev/null; then
  log "Ajout des variables d'environnement Docker rootless dans ${BASHRC}"
  cat >> "${BASHRC}" <<EOF

# --- Docker rootless ---
export PATH="${USER_HOME}/bin:\${PATH}"
export DOCKER_HOST="unix:///run/user/${USER_UID}/docker.sock"
EOF
fi

# 7. Activation + démarrage du service docker rootless (systemd --user) ----
log "Activation et démarrage du service Docker rootless"
su - "${DOCKER_USER}" -c "
  export XDG_RUNTIME_DIR=/run/user/${USER_UID}
  systemctl --user enable docker.service
  systemctl --user start docker.service
"

log "Vérification du démon Docker rootless"
su - "${DOCKER_USER}" -c "
  export XDG_RUNTIME_DIR=/run/user/${USER_UID}
  export DOCKER_HOST=unix:///run/user/${USER_UID}/docker.sock
  ${USER_HOME}/bin/docker version
" || err "Docker rootless ne répond pas. Vérifiez les logs : journalctl --user -u docker -M ${DOCKER_USER}@"

# 8. Création de /app pour l'utilisateur Docker ------------------------------
log "Création de ${APP_DIR} (propriété de ${DOCKER_USER})"
mkdir -p "${APP_DIR}"
chown "${DOCKER_USER}:${DOCKER_USER}" "${APP_DIR}"

log "Docker rootless prêt pour ${DOCKER_USER} (uid ${USER_UID})."
echo "Étape suivante : sudo ./deploy-proxy-stack.sh ${DOCKER_USER}"
