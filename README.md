# BIND9 + Webmin dans Docker

> Le **serveur mail** associé (Postfix, Dovecot, OpenDKIM, Rspamd, Sieve, quotas,
> authentification LDAP limitée au groupe `mail`) est dans le dépôt
> [nicolasgable/mail](https://github.com/nicolasgable/mail).

Serveur DNS **BIND9** administrable via une interface web (**Webmin**, module
"Servers > BIND DNS Server"), packagé dans une seule image Docker, prêt à
déployer sur une VM Ubuntu.

- BIND9 écoute sur le port **53** (TCP + UDP)
- Webmin écoute en HTTPS sur le port **10000**
- Configuration et zones DNS montées en volumes pour être persistantes et
  éditables depuis l'hôte ou depuis Webmin

## Arborescence du dépôt

```
.
├── Dockerfile              # Image BIND9 + Webmin (Ubuntu 22.04)
├── docker-compose.yml      # Orchestration du conteneur
├── entrypoint.sh            # Init : mot de passe Webmin, checkconf, supervisord
├── supervisord.conf         # Lance named + webmin dans le même conteneur
├── .env.example              # Modèle de variables d'environnement
├── config/
│   ├── named.conf.options   # Options globales BIND9 (forwarders, recursion...)
│   └── named.conf.local     # Déclaration des zones
└── zones/
    ├── db.example.local     # Zone directe d'exemple
    └── db.192.168.1         # Zone inverse d'exemple
```

## 1. Prérequis sur la VM Ubuntu

Connectez-vous en SSH sur votre VM Ubuntu (20.04/22.04/24.04), puis installez
Docker et le plugin Compose :

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y ca-certificates curl gnupg

# Dépôt officiel Docker
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# (optionnel) utiliser docker sans sudo
sudo usermod -aG docker $USER
newgrp docker
```

Vérifiez : `docker --version` et `docker compose version`.

## 2. Récupération du projet

```bash
git clone <url-de-ce-depot> bind9-webmin
cd bind9-webmin
```

## 3. Configuration

Copiez le fichier d'environnement et définissez un mot de passe Webmin fort :

```bash
cp .env.example .env
nano .env    # WEBMIN_PASSWORD=VotreMotDePasseFort!
```

Adaptez ensuite si besoin :

- `config/named.conf.options` : forwarders DNS, plages autorisées à faire de
  la récursion (`allow-recursion`) — **important pour ne pas exposer un
  résolveur DNS ouvert sur Internet**.
- `config/named.conf.local` : liste des zones DNS.
- `zones/` : fichiers de zone (adaptez ou remplacez les zones d'exemple
  `example.local` / `192.168.1.0/24`).

## 4. Build et démarrage

```bash
docker compose build
docker compose up -d
docker compose logs -f
```

Vérifiez que le conteneur est sain :

```bash
docker compose ps
```

## 5. Ouverture du pare-feu (ufw)

Si `ufw` est actif sur la VM :

```bash
sudo ufw allow 53/tcp
sudo ufw allow 53/udp
sudo ufw allow 10000/tcp   # interface Webmin — restreignez idéalement à votre IP :
# sudo ufw allow from <votre_IP> to any port 10000 proto tcp
sudo ufw status
```

Pensez aussi à ouvrir ces ports dans le pare-feu du fournisseur cloud
(security group / NSG) si la VM est hébergée (AWS, Azure, OVH, etc.).

## 6. Accès à l'interface d'administration Webmin

Ouvrez dans un navigateur :

```
https://<IP_DE_LA_VM>:10000
```

- Le certificat est auto-signé par défaut : acceptez l'avertissement du
  navigateur (ou installez votre propre certificat via le module
  "Webminconfig > SSL Encryption" une fois connecté).
- Identifiants : utilisateur `root`, mot de passe = celui défini dans `.env`
  (`WEBMIN_PASSWORD`).

Une fois connecté :

1. Menu **Servers > BIND DNS Server**.
2. Webmin détecte automatiquement `/etc/bind/named.conf` — validez la
   configuration proposée si demandé.
3. Vous pouvez créer/éditer des zones, des enregistrements (A, AAAA, CNAME,
   MX, TXT...), gérer les forwarders, etc. directement depuis l'interface.
4. Après modification, cliquez sur **Apply Configuration** (équivalent
   `rndc reload`) pour recharger BIND9 sans interrompre le service.

> **Remarque** : dans ce conteneur, `named` et `webmin` sont supervisés par
> `supervisord` (et non par les scripts `service`/`systemd` habituels). Les
> boutons Webmin **Start Server / Stop Server** pilotent `/etc/init.d/bind9`,
> qui n'a pas d'effet ici. Utilisez plutôt **Apply Configuration** (rndc
> reload), ou `docker compose restart` depuis la VM si un redémarrage complet
> du processus `named` est nécessaire.

## 7. Tester la résolution DNS

Depuis la VM elle-même ou un poste du réseau :

```bash
dig @<IP_DE_LA_VM> www.example.local
dig @<IP_DE_LA_VM> -x 192.168.1.20        # requête inverse (PTR)
```

Pour utiliser ce serveur comme résolveur par défaut sur un poste client,
pointez son DNS vers `<IP_DE_LA_VM>`.

## 8. Persistance des données

- `bind9_cache` (volume Docker) : cache BIND9 (`/var/cache/bind`).
- `webmin_config` (volume Docker) : configuration Webmin, y compris le mot
  de passe root modifié depuis l'interface.
- `./config` et `./zones` : montés depuis l'hôte, donc versionnables dans
  git et modifiables directement sur la VM.

Ces volumes/fichiers survivent à un `docker compose down` / `up`. Pour tout
réinitialiser :

```bash
docker compose down -v
```

## 9. Mise à jour

```bash
git pull
docker compose build --no-cache
docker compose up -d
```

## 10. Sécurité — points d'attention

- **Changez le mot de passe Webmin par défaut** avant toute exposition sur
  Internet (`.env` → `WEBMIN_PASSWORD`).
- **Restreignez l'accès au port 10000** (ufw / security group) à votre IP ou
  à un VPN plutôt que de l'exposer publiquement.
- **Ne laissez pas `allow-recursion` sur `any`** : un résolveur DNS ouvert
  peut être utilisé pour des attaques par amplification DDoS. Limitez-le à
  votre réseau local (`localnets`) ou à des IP précises.
- **`allow-transfer { none; }`** est configuré par défaut pour empêcher tout
  transfert de zone (AXFR) non autorisé ; n'ouvrez cette option qu'à des IP
  de secondaires DNS de confiance si nécessaire.
- Envisagez de remplacer le certificat auto-signé de Webmin par un certificat
  valide (Let's Encrypt via le module Webmin dédié) en production.
