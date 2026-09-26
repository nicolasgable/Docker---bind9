# Serveur mail Postfix + Dovecot + OpenDKIM, authentification LDAP

Serveur de messagerie complet dans un conteneur Docker, dont les comptes sont
ceux de **votre conteneur LDAP existant**, limités aux membres du **groupe
`mail`**.

| Composant | Rôle |
|-----------|------|
| **Postfix** | SMTP : réception (25), envoi authentifié (587 STARTTLS / 465 TLS) |
| **Dovecot** | IMAP (143 STARTTLS / 993 TLS), authentification LDAP, livraison LMTP en Maildir |
| **OpenDKIM** | Signature DKIM des mails sortants, vérification des mails entrants |
| **LDAP** (votre conteneur) | Comptes et mots de passe, groupe `mail` |

## Fonctionnement de l'authentification

```
Client mail ──IMAP──▶ Dovecot ──bind LDAP (mot de passe utilisateur)──▶ LDAP
Client mail ──SMTP 587/465──▶ Postfix ──SASL──▶ Dovecot ──▶ LDAP
Internet ──SMTP 25──▶ Postfix ──"le destinataire existe ?"──▶ LDAP
                         └──LMTP──▶ Dovecot ──▶ /var/mail/vhosts/<domaine>/<user>/Maildir
```

- Un utilisateur n'est reconnu que s'il a un attribut `mail` **et** appartient
  au groupe `mail` (filtre `LDAP_GROUP_FILTER`). Cela s'applique à la
  connexion IMAP, à l'envoi SMTP et à la réception (les adresses hors groupe
  sont rejetées en `550 User unknown`).
- Le mot de passe est vérifié par un **bind LDAP** avec les identifiants de
  l'utilisateur : aucun hash n'est lu ni stocké côté serveur mail.
- Connexion possible avec l'adresse (`jdupont@example.local`) **ou** l'`uid`
  (`jdupont`) ; les deux mènent à la même boîte.
- Un utilisateur authentifié ne peut envoyer qu'avec **sa propre adresse**
  (`reject_sender_login_mismatch`).
- Pas de relais ouvert : le port 25 n'accepte que les mails destinés aux
  domaines gérés et ne propose pas d'authentification.

## Arborescence

```
mail/
├── Dockerfile               # Ubuntu 24.04 + postfix/dovecot/opendkim
├── docker-compose.yml       # Service + raccordement au réseau Docker du LDAP
├── .env.example             # Toutes les variables à adapter
├── entrypoint.sh            # Génère les configs, clés DKIM, certificat, DNS
├── supervisord.conf         # rsyslog, opendkim, dovecot, postfix
├── rsyslog.conf             # Tous les logs vers "docker compose logs"
├── templates/               # Modèles de configuration (variables ${...})
│   ├── postfix/             # main.cf, master.cf, requêtes LDAP
│   ├── dovecot/             # dovecot.conf, dovecot-ldap.conf.ext
│   └── opendkim/            # opendkim.conf
├── ldap/mail-group.ldif     # Exemple de groupe "mail" + utilisateur
├── config/                  # virtual_aliases (alias de réception, optionnel)
├── certs/                   # fullchain.pem + privkey.pem (à fournir)
└── dkim/                    # Clés DKIM générées + DNS-RECORDS.txt
```

## 1. Préparer l'annuaire LDAP

1. Repérez le réseau Docker de votre conteneur LDAP et son nom :

   ```bash
   docker ps --format '{{.Names}}\t{{.Networks}}'
   ```

   Si le conteneur LDAP n'est sur aucun réseau dédié, créez-en un et
   branchez-le :

   ```bash
   docker network create ldap_network
   docker network connect ldap_network <conteneur_ldap>
   ```

2. Créez le groupe `mail` et ajoutez-y les utilisateurs autorisés (exemple
   dans `ldap/mail-group.ldif`). Chaque utilisateur doit avoir un attribut
   `mail` (une seule valeur) dont le domaine fait partie de `MAIL_DOMAINS`.

3. Vérifiez que l'attribut `memberOf` est bien présent sur les membres :

   ```bash
   docker exec <conteneur_ldap> ldapsearch -x -LLL -D "cn=admin,dc=example,dc=local" -W \
       -b "ou=users,dc=example,dc=local" "(uid=jdupont)" memberOf
   ```

   Si `memberOf` n'apparaît pas (overlay absent, ou groupe `posixGroup`),
   adaptez `LDAP_GROUP_FILTER` dans `.env`, par exemple :

   | Cas | `LDAP_GROUP_FILTER` |
   |-----|---------------------|
   | groupOfNames / groupOfUniqueNames + overlay memberOf (**défaut**) | *(vide)* → `(memberOf=<LDAP_MAIL_GROUP_DN>)` |
   | posixGroup dont les membres ont `mail` comme groupe principal | `(gidNumber=10000)` |
   | Attribut dédié sur les comptes | `(mailEnabled=TRUE)` |

   > Idéalement, utilisez un compte de service **en lecture seule** pour
   > `LDAP_BIND_DN` plutôt que `cn=admin`.

## 2. Configuration

```bash
cd mail
cp .env.example .env
nano .env
```

Points essentiels : `MAIL_HOSTNAME`, `MAIL_DOMAINS`, `LDAP_NETWORK`,
`LDAP_URI`, `LDAP_BASE_DN`, `LDAP_BIND_DN`, `LDAP_BIND_PASSWORD`,
`LDAP_USER_BASE`, `LDAP_MAIL_GROUP_DN`.

### Certificat TLS

Déposez `fullchain.pem` et `privkey.pem` dans `mail/certs/`. Exemple avec
Let's Encrypt (certbot sur l'hôte) :

```bash
sudo certbot certonly --standalone -d mail.example.com
sudo cp -L /etc/letsencrypt/live/mail.example.com/{fullchain,privkey}.pem certs/
```

Sans certificat, un certificat **auto-signé** est généré au démarrage
(suffisant pour tester, les clients afficheront un avertissement).

### Alias (optionnel)

```bash
cp config/virtual_aliases.example config/virtual_aliases
nano config/virtual_aliases
docker compose restart
```

## 3. Démarrage

```bash
docker compose up -d --build
docker compose logs -f
```

Au démarrage, les logs indiquent notamment :

```
[entrypoint] LDAP OK : 3 compte(s) mail trouve(s) dans le groupe.
```

puis affichent les **enregistrements DNS à publier**.

## 4. DNS (zone BIND9 de ce dépôt)

Les enregistrements sont aussi écrits dans `dkim/DNS-RECORDS.txt`. À ajouter
dans le fichier de zone du domaine (ex. `../zones/db.example.local`), en
**incrémentant le serial** :

```dns
mail            IN A     <IP_PUBLIQUE_DU_SERVEUR_MAIL>
@               IN MX 10 mail.example.local.
@               IN TXT   "v=spf1 mx -all"
_dmarc          IN TXT   "v=DMARC1; p=quarantine; rua=mailto:postmaster@example.local"
mail._domainkey IN TXT   ( "v=DKIM1; h=sha256; k=rsa; s=email; "
                           "p=MIIBIjANBgkq..." )   ; copier depuis dkim/DNS-RECORDS.txt
```

Puis dans Webmin **Apply Configuration** (ou `rndc reload`). Vérification :

```bash
dig +short MX example.local @<IP_DNS>
dig +short TXT mail._domainkey.example.local @<IP_DNS>
docker compose exec mail opendkim-testkey -d example.local -s mail -vvv
```

Pour un domaine public, pensez aussi au **reverse DNS (PTR)** de l'IP
publique → `MAIL_HOSTNAME` (à demander à votre hébergeur/FAI) : sans lui, vos
mails seront souvent classés en spam.

Les clés DKIM sont conservées dans `mail/dkim/` : **sauvegardez ce dossier**
(une nouvelle clé imposerait de republier l'enregistrement DNS).

## 5. Pare-feu

```bash
sudo ufw allow 25/tcp
sudo ufw allow 465/tcp
sudo ufw allow 587/tcp
sudo ufw allow 993/tcp
sudo ufw allow 143/tcp   # optionnel si vos clients utilisent 993
```

Beaucoup d'hébergeurs/FAI bloquent le port 25 **sortant** : dans ce cas,
renseignez `MAIL_RELAYHOST` (smarthost) dans `.env`.

## 6. Configuration d'un client mail (Thunderbird, Outlook, mobile)

| | Serveur | Port | Sécurité | Identifiant |
|-|---------|------|----------|-------------|
| Réception IMAP | `mail.example.local` | 993 | SSL/TLS | `jdupont` ou `jdupont@example.local` |
| Envoi SMTP | `mail.example.local` | 587 | STARTTLS | idem (mot de passe LDAP) |

## 7. Tests et dépannage

```bash
# Membres du groupe vus par le serveur mail
docker compose exec mail sh -c 'ldapsearch -x -LLL -H "$LDAP_URI" -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" \
    -b "${LDAP_USER_BASE:-ou=users,$LDAP_BASE_DN}" "(memberOf=$LDAP_MAIL_GROUP_DN)" mail'

# Test d'authentification Dovecot -> LDAP
docker compose exec mail doveadm auth test jdupont@example.local 'MotDePasse'

# Une adresse est-elle acceptée par Postfix ?
docker compose exec mail postmap -q jdupont@example.local ldap:/etc/postfix/ldap-virtual-mailbox-maps.cf

# File d'attente
docker compose exec mail postqueue -p
```

Pour des logs d'authentification détaillés : `DOVECOT_AUTH_DEBUG=yes` dans
`.env` puis `docker compose up -d`.

## 8. Persistance et sauvegarde

- `mail_data` (volume) : toutes les boîtes aux lettres (Maildir).
- `mail_queue` (volume) : file d'attente Postfix.
- `./dkim` : clés privées DKIM.
- `./certs`, `./config`, `.env` : configuration.

Supprimer un utilisateur du groupe `mail` bloque immédiatement sa connexion
et la réception de ses mails, **sans effacer** sa boîte
(`/var/mail/vhosts/<domaine>/<user>`).
