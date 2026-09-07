# Docker rootless + Nginx Proxy Manager + Dockhand

Scripts pour installer Docker en mode **rootless** pour un utilisateur dédié
sur une VM Ubuntu, puis déployer dans `/app/proxy` :

- **Nginx Proxy Manager** — reverse proxy avec interface web, seul point
  d'entrée exposé sur l'hôte (ports 80/443, admin sur 81).
- **Dockhand** — interface web de gestion Docker, accessible uniquement via
  Nginx Proxy Manager (aucun port publié directement), pour que tout le
  trafic passe par le proxy.

## Pourquoi le mode rootless ?

Le démon Docker tourne avec les droits de l'utilisateur dédié (pas root),
ce qui limite fortement l'impact d'une éventuelle compromission d'un
conteneur (dont Dockhand, qui a accès au socket Docker).

## Prérequis

- VM Ubuntu 22.04/24.04, accès `sudo`.
- Ports 80, 443 et 81 libres et ouverts côté pare-feu cloud (security group /
  NSG) si la VM est hébergée.

## Utilisation

```bash
git clone <url-de-ce-depot>
cd Docker---bind9/rootless-proxy

# 1. Installe Docker rootless pour l'utilisateur "dockerapp"
#    (remplacez le nom si besoin ; idempotent, peut être relancé)
sudo ./install-docker-rootless.sh dockerapp

# 2. Déploie Nginx Proxy Manager + Dockhand dans /app/proxy
sudo ./deploy-proxy-stack.sh dockerapp
```

## Ce que fait `install-docker-rootless.sh`

1. Installe les paquets requis (`uidmap`, `dbus-user-session`,
   `slirp4netns`, `fuse-overlayfs`).
2. Crée l'utilisateur dédié s'il n'existe pas, avec ses plages
   `subuid`/`subgid`.
3. Active le *linger* (`loginctl enable-linger`) pour que le démon Docker
   rootless démarre au boot de la VM et survive à la déconnexion SSH.
4. Autorise le bind sur les ports ≥ 80 sans privilège root
   (`net.ipv4.ip_unprivileged_port_start=80`), nécessaire pour que Nginx
   Proxy Manager écoute sur 80/443 en rootless.
5. Installe Docker rootless via le script officiel
   (`get.docker.com/rootless`).
6. Ajoute `DOCKER_HOST` et le `PATH` dans le `.bashrc` de l'utilisateur.
7. Active et démarre le service `docker` en `systemd --user`.
8. Crée `/app`, appartenant à l'utilisateur dédié.

## Ce que fait `deploy-proxy-stack.sh`

1. Crée l'arborescence `/app/proxy/{npm,dockhand}` et y copie
   `docker-compose.yml` + un `.env` pointant vers le socket Docker rootless
   de l'utilisateur (`/run/user/<uid>/docker.sock`).
2. Ouvre les ports 80/443/81 dans `ufw` s'il est actif.
3. Lance `docker compose up -d` **en tant qu'utilisateur dédié** (jamais en
   root).

## Après le déploiement

1. Ouvrez `http://<IP_DE_LA_VM>:81` : identifiants par défaut de Nginx Proxy
   Manager `admin@example.com` / `changeme` — **changez-les immédiatement**.
2. Dans **Hosts > Proxy Hosts**, créez un hôte proxy vers Dockhand :
   - Domain Names : le nom de domaine souhaité (ex. `dockhand.mondomaine.fr`)
   - Forward Hostname / IP : `dockhand`
   - Forward Port : `3000`
   - Activez SSL (Let's Encrypt) une fois le DNS pointé vers la VM.
3. Faites de même pour tout futur service ajouté au réseau docker `proxy` :
   c'est ce réseau qui garantit que tout le trafic transite par Nginx Proxy
   Manager plutôt que par des ports publiés directement sur l'hôte.

## Vérifications utiles

```bash
# En tant qu'utilisateur dédié :
su - dockerapp
export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock
docker ps

# Statut du démon Docker rootless :
systemctl --user status docker

# Logs :
journalctl --user -u docker -M dockerapp@ -f
```

## Sécurité

- Changez le mot de passe admin de Nginx Proxy Manager dès la première
  connexion.
- Restreignez l'accès au port `81` (admin NPM) à votre IP via `ufw` ou un
  VPN plutôt que de l'exposer publiquement.
- Dockhand a accès au socket Docker : ne l'exposez jamais directement sur
  Internet, uniquement via NPM, idéalement derrière une authentification
  supplémentaire (SSO, page de connexion NPM avec accès restreint, etc.).
- Ajoutez tout nouveau conteneur au réseau docker `proxy` plutôt que de
  publier ses ports directement, afin de conserver "tout le trafic passe
  par le proxy".
