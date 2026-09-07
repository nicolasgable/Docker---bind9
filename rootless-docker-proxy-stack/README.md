# Docker rootless + Dockhand + Nginx Proxy Manager

Script d'installation pour une VM Ubuntu (20.04/22.04/24.04) : installe
**Docker en mode rootless** (sans privilège root pour le démon `dockerd`)
pour un utilisateur normal, puis déploie deux conteneurs :

- **[Dockhand](https://github.com/Finsys/dockhand)** — interface web de
  gestion des conteneurs Docker (`fnsys/dockhand`).
- **[Nginx Proxy Manager](https://nginxproxymanager.com/)** — reverse proxy
  avec interface web (`jc21/nginx-proxy-manager`).

Les deux conteneurs sont attachés à un réseau Docker externe nommé
**`proxy`**. Seul Nginx Proxy Manager publie des ports sur l'hôte
(`80`, `443`, `81`) : il agit comme **unique passerelle d'entrée et de
sortie**. Dockhand ne publie aucun port sur l'hôte et n'est joignable que
via NPM, sur le réseau `proxy` — tout le trafic applicatif est donc filtré
par ce réseau/point de sortie unique.

## Prérequis

- VM Ubuntu 20.04/22.04/24.04 avec accès `sudo`.
- Un utilisateur non-root existant (Docker rootless ne doit jamais être
  installé pour `root`).

## Utilisation

```bash
chmod +x install-rootless-docker-proxy.sh
sudo ./install-rootless-docker-proxy.sh <utilisateur>
# ou, sans argument, cible l'utilisateur qui a lancé sudo (SUDO_USER)
sudo ./install-rootless-docker-proxy.sh
```

Le script :

1. Installe les prérequis rootless (`uidmap`, `dbus-user-session`,
   `fuse-overlayfs`, `slirp4netns`) et les paquets Docker officiels
   (`docker-ce-cli`, `containerd.io`, `docker-ce-rootless-extras`,
   `docker-buildx-plugin`, `docker-compose-plugin`).
2. Désactive le démon Docker root-full s'il tourne déjà (`docker.service`).
3. Autorise la liaison des ports privilégiés (`>=80`) pour les sockets
   non-root, nécessaire pour que NPM publie les ports 80/443/81 en rootless
   (`net.ipv4.ip_unprivileged_port_start`).
4. Active le *lingering* systemd (`loginctl enable-linger`) pour que le
   démon rootless survive à la déconnexion SSH.
5. Installe et démarre Docker rootless pour l'utilisateur cible
   (`dockerd-rootless-setuptool.sh`), avec un service systemd `--user`.
6. Crée le réseau Docker externe `proxy` et génère `/app/docker-compose.yml`
   (répertoire `/app` appartenant intégralement à l'utilisateur Docker
   rootless), puis lance la stack.
7. Ouvre les ports 80/443/81 dans `ufw` si celui-ci est actif.

## Après l'installation

- Interface NPM : `http://<IP_DE_LA_VM>:81`
  (identifiants par défaut `admin@example.com` / `changeme` — à changer
  immédiatement, et à restreindre à votre IP en production).
- Dockhand n'est pas exposé directement : créez un *Proxy Host* dans NPM
  pointant vers `dockhand:3000` sur le réseau `proxy`.
- Pour toute commande Docker manuelle, connectez-vous avec l'utilisateur
  cible (`su - <utilisateur>`) ; l'environnement (`DOCKER_HOST`, `PATH`)
  est configuré dans son `~/.bashrc`.
- Tout nouveau conteneur applicatif à exposer via NPM doit rejoindre le
  réseau externe `proxy`.

## Réinitialisation / désinstallation

```bash
su - <utilisateur> -c 'docker compose -f /app/docker-compose.yml down'
su - <utilisateur> -c 'dockerd-rootless-setuptool.sh uninstall'
sudo loginctl disable-linger <utilisateur>
```
