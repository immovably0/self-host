# Nuvio tout-en-un (expérimental)

Une seule image Docker qui contient tout le backend Nuvio (base de données, authentification, API, stockage, fonctions, tableau de bord et passerelle HTTP). Elle s'installe comme n'importe quel conteneur de NAS, par exemple Jellyfin : une image, un port, trois dossiers.

> **Statut : expérimental, mais testé de bout en bout.** À chaque publication, le workflow GitHub construit l'image, la démarre, vérifie chaque service, crée un compte, redémarre le conteneur et se reconnecte avec le même compte (persistance). L'image n'est publiée que si ce test est vert. Il tourne sur amd64 ; l'image arm64 est construite mais pas testée. Si elle ne démarre pas chez vous, l'installation classique (`./nuvio setup`, à la racine du dépôt) reste la voie de référence.

## Ce qui est inclus, ce qui ne l'est pas

Inclus : PostgreSQL (image Supabase), Auth (GoTrue), API REST (PostgREST), Storage, fonctions Edge de Nuvio (connexion TV, suppression de compte), tableau de bord du compte, passerelle Caddy.

Retiré par rapport à l'installation classique :

| Retiré | Conséquence |
| --- | --- |
| Kong | Remplacé par Caddy, qui reprend les mêmes routes, la même vérification de la clé `apikey` et le même CORS. |
| imgproxy | Pas de redimensionnement d'images à la volée (`/storage/v1/render/image`). Les avatars et fichiers sont servis tels quels. |
| Realtime, Studio, postgres-meta | Déjà optionnels dans l'installation classique (profils `realtime` et `studio`). |
| Supavisor (pooler) | Les services se connectent directement à PostgreSQL. |
| Import de compte Nuvio Cloud | `scripts/import-account.sh` pilote `docker compose` et n'est pas repris ici. |
| Clés API « opaques » (`sb_publishable_…`) | Seules les clés JWT classiques sont gérées. |

## Installation sur un NAS (Synology, TrueNAS, autre)

### 1. Obtenir l'image

L'image est construite et publiée par GitHub, pas par votre NAS, et rien n'est jamais publié depuis `main` : le workflow ne tourne que sur la branche `feat/all-in-one`.

1. Sur votre fork, onglet **Actions**, activez les workflows si GitHub le propose (ils sont désactivés par défaut sur un fork).
2. Chaque envoi sur la branche `feat/all-in-one` lance le workflow : construction, test complet, puis publication **uniquement si le test est vert**. En cas d'échec, ouvrez les journaux : ils contiennent ceux du conteneur.
3. L'image est publiée sur GHCR, sans configuration : `ghcr.io/immovably0/nuvio-allinone:latest`.
4. Le paquet GHCR d'un fork est privé par défaut : dans GitHub, **Packages, nuvio-allinone, Package settings, Change visibility, Public**, ou bien connectez votre NAS avec `docker login ghcr.io` (identifiant GitHub + jeton avec le droit `read:packages`).

Une fois l'image publiée, `docker pull ghcr.io/immovably0/nuvio-allinone:latest` fonctionne depuis n'importe quelle machine.

**Option Docker Hub** (plus pratique sur Synology : l'image se cherche directement dans Container Manager). Dans les paramètres du fork, **Secrets and variables, Actions**, créez `DOCKERHUB_USERNAME` (votre identifiant) et `DOCKERHUB_TOKEN` (un jeton d'accès Docker Hub avec droit d'écriture). Au prochain envoi, l'image est aussi publiée sur `docker.io/<identifiant>/nuvio-allinone`. Sans ces secrets, seul GHCR est utilisé.

### 2. Créer le conteneur

Créez trois dossiers sur le NAS, par exemple `/volume1/docker/nuvio/app`, `/postgres` et `/storage`.

| Réglage | Valeur |
| --- | --- |
| Image | `ghcr.io/immovably0/nuvio-allinone:latest` (ou celle de Docker Hub) |
| Port | `8000` du conteneur vers un port du NAS (ex. `8000`) |
| Dossier → `/data` | `…/nuvio/app` (secrets, certificats) |
| Dossier → `/var/lib/postgresql/data` | `…/nuvio/postgres` (base de données) |
| Dossier → `/opt/storage/var/lib/storage` | `…/nuvio/storage` (fichiers envoyés) |
| Variable `NUVIO_PUBLIC_URL` | l'adresse publique du backend, par exemple `https://nuvio.exemple.fr` |

Le fichier `docker-compose.yml` de ce dossier fait la même chose en ligne de commande ou dans Dockge/Portainer.

### 3. HTTPS

Deux possibilités :

- **Proxy inversé du NAS (recommandé sur Synology/TrueNAS)** : laissez `NUVIO_AUTO_HTTPS=false`. Faites pointer le proxy de `https://nuvio.exemple.fr` vers `http://IP-DU-NAS:8000` et mettez cette adresse dans `NUVIO_PUBLIC_URL`.
- **Caddy intégré** : `NUVIO_AUTO_HTTPS=true`, `NUVIO_PUBLIC_URL=https://nuvio.exemple.fr`, et publiez aussi les ports 80 et 443. Ils sont souvent déjà pris par le NAS lui-même.

### 4. Premier démarrage

Comptez plusieurs minutes (initialisation de la base, migrations, avatars). Les journaux du conteneur affichent `OK` pour chaque service, puis l'adresse du backend et la clé publique. Pour les revoir :

```sh
docker exec nuvio nuvio credentials   # adresse et clé publique
docker exec nuvio nuvio doctor        # contrôle de chaque service
```

Dans les applications Nuvio, saisissez l'adresse du backend. Le tableau de bord du compte est à la même adresse.

## Variables

| Variable | Défaut | Rôle |
| --- | --- | --- |
| `NUVIO_PUBLIC_URL` | `http://localhost:8000` | Adresse publique (schéma + nom d'hôte, sans chemin). |
| `NUVIO_AUTO_HTTPS` | `false` | `true` : Caddy obtient le certificat (ports 80/443). |
| `NUVIO_HTTP_PORT` | `8000` | Port HTTP interne de la passerelle. |
| `NUVIO_SITE_URL` | `https://nuvio.tv` | Site public lié depuis le tableau de bord. |
| `DEFAULT_CATALOG_URL` | `https://catalog.nuvio.tv/manifest.json` | Catalogue par défaut de l'instance. |
| `DISABLE_SIGNUP` | `false` | Interdit les nouvelles inscriptions. |
| `ENABLE_EMAIL_AUTOCONFIRM` | `true` | Confirme les comptes sans e-mail. |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`, `SMTP_ADMIN_EMAIL`, `SMTP_SENDER_NAME` | valeurs factices | Serveur d'envoi des e-mails. |
| `POSTGRES_PASSWORD`, `JWT_SECRET`, `ANON_KEY`, `SERVICE_ROLE_KEY` | générés | À ne fournir qu'au tout premier démarrage (voir ci-dessous). |

Les autres réglages d'Auth de `.env.example` (`PASSWORD_MIN_LENGTH`, `RATE_LIMIT_*`, `PASSKEY_ENABLED`, etc.) sont repris sous le même nom.

## Secrets

Au premier démarrage, le mot de passe de la base et les clés JWT sont générés puis enregistrés dans `/data/secrets.env` (droits 600). Aux démarrages suivants, **le fichier prime sur l'environnement** : ces valeurs sont figées dans la base, les changer la rendrait inutilisable. Sauvegardez ce fichier avec le dossier PostgreSQL. Les clés JWT expirent au bout de cinq ans.

## Mise à jour et sauvegarde

Mise à jour : récupérez la nouvelle image et recréez le conteneur ; les migrations manquantes sont appliquées au démarrage. Sauvegarde : arrêtez le conteneur, copiez les trois dossiers.

## Comment ça marche

`nuvio-entrypoint` (PID 1) génère les secrets, lance PostgreSQL avec le point d'entrée d'origine de l'image Supabase, puis démarre chaque autre service **dans son propre dossier** `/opt/<service>` (chroot), avec l'ENTRYPOINT, le CMD et l'environnement de son image d'origine, relevés à la construction dans `svc/<service>.json`. Les bibliothèques ne sont donc jamais mélangées entre services. Caddy écoute sur le port public (8000) et sur `127.0.0.1:8001` (réservé aux fonctions Edge et aux contrôles de santé). Si un service s'arrête, le conteneur s'arrête et Docker le relance.

## Limites connues et dépannage

- **Taille** : l'image embarque le système de fichiers de chaque service et dépasse probablement 2 Go.
- **Services en root** : chaque service tourne en root dans son chroot, par simplicité. Le chroot isole les fichiers, pas les privilèges.
- **`/proc` absent dans les chroots** : il n'est monté que si le conteneur a `CAP_SYS_ADMIN`. Pour cette raison, les fonctions Edge ne tournent pas dans un chroot : elles sont lancées directement, avec le chargeur dynamique et les bibliothèques de leur image (elles lisent `/home/deno/functions`). Les autres services s'en passent. Si Storage échoue pour une raison liée à `/proc`, ajoutez `cap_add: SYS_ADMIN` et `security_opt: apparmor=unconfined` (voir le compose d'exemple).
- **Fonctions Edge** : elles téléchargent leurs dépendances (`deno.land`) au premier appel, donc le conteneur doit avoir accès à Internet.
- **Conteneur qui s'arrête au démarrage** : lisez la dernière ligne `ERREUR :` des journaux. Les messages les plus probables concernent un point d'entrée introuvable ou une image amont dont la structure a changé ; mettez à jour les versions dans `Dockerfile` en même temps que `compose.yml`.
- **Mise à jour des versions** : les images amont sont celles de `compose.yml`. L'image du tableau de bord est `:latest` ; épinglez-la pour des constructions reproductibles.

## Ce qui a été vérifié

- Le Caddyfile est valide (Caddy 2.10) et son routage a été testé avec de faux services : clé `apikey` absente ou fausse refusée, routes ouvertes d'Auth, connexion TV sans clé, CORS et préflight, Storage sans clé, découverte `/.well-known/nuvio`, passerelle interne.
- Les scripts passent `shellcheck`, le Dockerfile `hadolint`, le workflow `actionlint`.
- Dans le workflow (amd64) : construction de l'image, démarrage, contrôle de chaque service (`nuvio doctor`), accès au tableau de bord et à la découverte, refus sans clé, inscription, redémarrage, reconnexion.

Non vérifié : arm64, les fonctions Edge appelées avec un vrai jeton de connexion TV, l'envoi d'e-mails, l'import de compte, une mise à jour depuis une version précédente.

## Fichiers

| Fichier | Rôle |
| --- | --- |
| `Dockerfile` | Assemble l'image à partir des images officielles. |
| `nuvio-entrypoint.sh` | Secrets, démarrage, migrations, supervision, commandes `doctor`/`credentials`. |
| `Caddyfile` | Passerelle HTTP (remplace Kong). |
| `scripts/extract-image-config.sh` | Relève ENTRYPOINT/CMD/environnement des images amont. |
| `scripts/smoke-test.sh` | Test de bout en bout, utilisable en local. |
| `build.sh` | Construction locale (`./allinone/build.sh`). |
| `docker-compose.yml` | Exemple d'installation en un seul service. |
