# Secrets (SOPS + age)

Les secrets des backends (`.env`), les tokens des tunnels cloudflared et, plus tard, les identifiants de la liaison avec le NAS vivent **chiffrés** dans ce dépôt. Rien n'est jamais en clair : la CI refuse tout fichier de `secrets/staging/` ou `secrets/production/` qui ne soit pas chiffré, et Gitleaks tourne en plus.

## Principe

- [age](https://github.com/FiloSottile/age) génère une paire de clés. La **clé publique** (`age1…`) est dans `.sops.yaml` et peut être versionnée. La **clé privée** reste chez vous (`~/.config/sops/age/keys.txt`), **jamais** dans le dépôt.
- [SOPS](https://github.com/getsops/sops) chiffre les *valeurs* des Secrets Kubernetes (les noms et les clés restent lisibles : les diffs de PR restent compréhensibles).
- Au démarrage de l'instance, le script d'amorçage récupère la clé privée (AWS Systems Manager, étape suivante), déchiffre les fichiers et les applique avec `kubectl`. ArgoCD gère le reste (manifestes, digests, promotion).

## Mise en route (une seule fois, sur votre poste)

```bash
brew install age sops
scripts/secrets.sh keygen            # crée la clé privée et écrit la clé publique dans .sops.yaml
#  >>> sauvegardez ~/.config/sops/age/keys.txt dans votre gestionnaire de mots de passe
scripts/secrets.sh init staging      # crée secrets/staging/*.sops.yaml depuis secrets/templates/
scripts/secrets.sh init production
scripts/secrets.sh set staging cloudflared-sherlock TUNNEL_TOKEN --clipboard   # copier le token, puis lancer
scripts/secrets.sh set staging dns-analyzer-env INTERNAL_API_TOKEN              # sans --clipboard : saisie masquee
```

`set` renseigne **une valeur à la fois**, sans éditeur : avec `--clipboard`, il lit le presse-papiers puis le vide ; sans, il demande la valeur en saisie masquée (collez avec Cmd+V, rien ne s'affiche). `edit <env> <nom>` ouvre tout un fichier dans `$EDITOR` si vous préférez.

Repérer les clés attendues : `secrets/templates/` liste les variables de chaque Secret (déduites du code des backends). Comparez-les au `.env` de chaque backend sur le NAS et ajoutez celles qui manquent.

Staging et production ont **chacun leurs propres tunnels** (tokens `cloudflared-*` distincts de ceux du NAS) : créez-les dans le tableau de bord Cloudflare avant de remplir les fichiers.

## Appliquer à la main (kind ou cluster existant)

```bash
scripts/secrets.sh apply staging     # déchiffre et applique dans le namespace cyberlab-staging
```

## À la reconstruction

La clé privée n'est pas dans le dépôt : elle est fournie au cluster par l'instance elle-même, depuis AWS Systems Manager Parameter Store (créée une fois par vous, hors Terraform). Voir `docs/notes-projet.md`.

## Perte de la clé

Sans la clé privée, les fichiers chiffrés sont irrécupérables. Conservez-la dans un gestionnaire de mots de passe **et** hors de ce poste. En cas de perte : générer une nouvelle clé, réinitialiser les fichiers (`init`) et ressaisir les secrets (les tokens cloudflared peuvent être régénérés dans Cloudflare).
