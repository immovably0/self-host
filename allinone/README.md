# Nuvio tout-en-un (expérimental)

Une seule image Docker qui contient tout le backend Nuvio (base de données, authentification, API, stockage, fonctions, tableau de bord et passerelle HTTP). Elle s'installe comme n'importe quel conteneur de NAS, par exemple Jellyfin : une image, un port, trois dossiers.

> **Statut : non testé de bout en bout.** Cette image a été écrite sans accès à un démon Docker. Les fichiers de configuration, le script de démarrage et le routage HTTP ont été vérifiés (voir « Ce qui a été vérifié »), mais l'image n'a jamais été construite ni lancée avant la première exécution du workflow GitHub. Ce workflow contient un test complet (démarrage, création de compte, redémarrage, reconnexion) : tant qu'il n'est pas vert, considérez l'image comme non fonctionnelle. Si elle ne démarre pas, l'installation classique (`./nuvio setup`, à la racine du dépôt) reste la voie fiable.

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

L'image n'existe pas encore sur GHCR : elle est construite par GitHub, pas par votre NAS.

1. Sur votre fork, onglet **Actions**, activez les workflows si GitHub le propose (ils sont désactivés par défaut sur un fork).
2. Le workflow se lance déjà à chaque envoi sur la branche `feat/all-in-one` : il construit l'image et exécute le test complet, **sans publier**. Consultez le résultat dans l'onglet Actions, et ouvrez les journaux en cas d'échec : ils contiennent ceux du conteneur.
3. Quand le test est vert, fusionnez la branche dans `main` (Pull request : <https://github.com/immovably0/self-host/pull/new/feat/all-in-one>). Le workflow se relance sur `main` et publie l'image sur GHCR. Pour republier plus tard sans modifier le code : Actions, **Publish all-in-one image**, **Run workflow**, case *publish* cochée (possible une fois le fichier présent sur `main`).
4. Le paquet GHCR d'un fork est privé par défaut : dans GitHub, **Packages, nuvio-allinone, Package settings, Change visibility, Public**, ou bien connectez votre NAS avec `docker login ghcr.io` (identifiant GitHub + jeton avec le droit `read:packages`).

### 2. Créer le conteneur

Créez trois dossiers sur le NAS, par exemple `/volume1/docker/nuvio/app`, `/postgres` et `/storage`.

| Réglage | Valeur |
| --- | --- |
| Image | `ghcr.io/immovably0/nuvio-allinone:latest` |
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
- **`/proc` absent dans les chroots** : il n'est monté que si le conteneur a `CAP_SYS_ADMIN`. La plupart des services s'en passent ; si les fonctions Edge ou Storage échouent à cause de cela, ajoutez `cap_add: SYS_ADMIN` et `security_opt: apparmor=unconfined` (voir le compose d'exemple). C'est moins isolé.
- **Fonctions Edge** : elles téléchargent leurs dépendances (`deno.land`) au premier appel, donc le conteneur doit avoir accès à Internet.
- **Conteneur qui s'arrête au démarrage** : lisez la dernière ligne `ERREUR :` des journaux. Les messages les plus probables concernent un point d'entrée introuvable ou une image amont dont la structure a changé ; mettez à jour les versions dans `Dockerfile` en même temps que `compose.yml`.
- **Mise à jour des versions** : les images amont sont celles de `compose.yml`. L'image du tableau de bord est `:latest` ; épinglez-la pour des constructions reproductibles.

## Ce qui a été vérifié

Sans Docker, sur le code de ce dossier :

- le Caddyfile est valide (binaire Caddy 2.10) et son routage a été testé avec de faux services : clé `apikey` absente ou fausse refusée, routes ouvertes d'Auth, connexion TV sans clé, CORS et préflight, Storage sans clé, découverte `/.well-known/nuvio`, passerelle interne ;
- le script de démarrage passe `shellcheck` ; la génération des secrets (JWT HS256 vérifiés, persistance, droits), la validation de la configuration et la construction de l'environnement de chaque service ont été testées ;
- le Dockerfile passe `hadolint` ; le workflow passe `actionlint` ; le compose d'exemple est valide.

Non vérifié : la construction de l'image, le démarrage réel de chaque service (point d'entrée de chaque image, chroot, `mknod`), l'initialisation de la base, les migrations et l'envoi des avatars. Le workflow GitHub exécute précisément ce test.

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
