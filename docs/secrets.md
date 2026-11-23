# Secrets : SOPS + age, expliqué simplement

> **À retenir** : les secrets sont chiffrés dans Git (SOPS + age), la clé privée vit dans AWS SSM et l'instance la supprime de son disque après usage.

Côté Terraform, la politique IAM `age_key` ([iam.tf](../terraform/main/iam.tf)) autorise l'instance à lire **uniquement** les deux paramètres SSM (clé age, clé Tailscale). Terraform ne manipule jamais la clé elle-même.

## Le problème

L'application a besoin de secrets : les tokens des 6 tunnels Cloudflare, la clé Gemini, les jetons internes des backends. Or ce dépôt est **public**, et Git garde tout l'historique pour toujours.

| Idée | Pourquoi elle ne marche pas |
|---|---|
| Écrire les secrets en clair dans Git | Visibles par tout le monde, définitivement |
| Les garder seulement sur mon poste | `terraform apply` ne pourrait plus tout reconstruire seul : il faudrait les ressaisir à la main |
| **Les mettre dans Git, mais chiffrés** | Le dépôt reste la source de vérité, et personne ne peut les lire sans la clé |

C'est ce que font **SOPS** et **age**.

## Les deux outils

- **age** est un outil de chiffrement. Il crée une **paire de clés** :
  - la **clé publique** (`age1…`) sert à *chiffrer*. Elle n'est pas secrète, elle est dans `.sops.yaml` et versionnée ;
  - la **clé privée** sert à *déchiffrer*. Elle reste chez moi et n'entre jamais dans le dépôt.

  Image : la clé publique est un cadenas ouvert que tout le monde peut fermer ; seule la clé privée l'ouvre.
- **SOPS** est l'outil qui applique age à un fichier YAML : il chiffre les **valeurs** et laisse les **noms** lisibles.

## À quoi ressemble un secret dans le dépôt

Extrait réel de `secrets/production/cloudflared-dns.sops.yaml` (le bloc chiffré est raccourci) :

```yaml
apiVersion: v1
kind: Secret                       # lisible
metadata:
    name: cloudflared-dns          # lisible
    namespace: cyberlab-production # lisible
stringData:
    TUNNEL_TOKEN: ENC[AES256_GCM,data:DtgjqK9rzuoV/oGPaPixt/G4QeQ…,type:str]   # illisible
sops:
    age:
        - recipient: age1xkgfzm20xxt20mmzyfzdsucfugs0e7epfgf3d8jxqxg05x35fvxskrfqn0
```

Seules les valeurs sont chiffrées (`encrypted_regex` dans `.sops.yaml`). Dans une pull request, on voit donc *quel* secret change, sans jamais voir sa valeur.

## Le trajet d'un secret

```
 MON POSTE                          GIT (public)                 L'INSTANCE AWS
 scripts/secrets.sh set  ──chiffre──▶ secrets/*.sops.yaml  ──────▶ bootstrap-node.sh
 (clé PUBLIQUE age)                   (illisible)                   │
                                           │                        ├─ lit la clé PRIVÉE dans AWS SSM
                                      la CI refuse                  ├─ déchiffre (sops)
                                      tout fichier non chiffré      ├─ kubectl apply → Secrets Kubernetes
                                      (+ Gitleaks)                  └─ supprime la clé du disque
```

1. **Je chiffre** sur mon poste : `scripts/secrets.sh set` demande la valeur (saisie masquée) et l'écrit chiffrée dans le fichier.
2. **Je commite** le fichier chiffré. La CI vérifie qu'aucun fichier de `secrets/` n'est en clair (`ci/check-secrets-encrypted.sh`) et lance Gitleaks.
3. **À la reconstruction**, l'instance récupère la clé privée dans AWS Systems Manager (créée une fois à la main, hors Terraform), déchiffre les fichiers, crée les Secrets Kubernetes, puis **efface la clé** de son disque.

Résultat : `terraform apply` reconstruit tout sans que personne ne tape un secret.

## Où vit chaque secret

Le dépôt est public : la règle est qu'aucun secret n'y entre en clair, ni dans la CI.

| Secret | Où il vit | Ce qui le protège |
|---|---|---|
| **Clé AWS** (pour `terraform apply`) | uniquement sur le poste (AWS CLI) | absente de GitHub : la CI ne parle jamais à AWS. `*.tfvars` et `*.tfstate` sont dans `.gitignore` |
| **kubeconfig** | uniquement sur l'instance | absent de GitHub ; le port 6443 n'est pas ouvert ; Argo CD tire depuis Git, personne ne pousse vers le cluster |
| **Secrets applicatifs** (tokens des tunnels, `.env` des backends) | dans Git, **chiffrés par SOPS + age** | la CI refuse tout fichier non chiffré ; seule la clé *publique* est versionnée |
| **Clé privée age** | AWS Systems Manager Parameter Store (SecureString) | lue au premier démarrage puis supprimée du disque ; jamais dans le dépôt, ni dans `user_data`, ni dans l'état Terraform |
| **Clé d'authentification Tailscale** | Parameter Store, créée à la main | même chemin que la clé age |
| **Accès Argo CD → Git, registre d'images** | aucun | dépôt et images publics ; la signature Cosign est vérifiée sans clé |

L'instance lit ses deux paramètres grâce à un rôle IAM qui n'autorise que `ssm:GetParameter` sur ces deux noms (`terraform/main/iam.tf`). Un pod compromis ne peut pas utiliser ce rôle : l'accès aux métadonnées AWS est durci (IMDSv2, `hop limit = 1`).

La CI n'utilise aucun secret, ne demande que `permissions: contents: read` et tourne sur des runners GitHub jetables, jamais auto-hébergés. Le jour où un `terraform plan` y sera ajouté, il faudra une authentification OIDC GitHub → AWS avec un rôle en lecture seule, sans clé stockée.

## Pourquoi le kubeconfig n'est pas dans la CI

Beaucoup de cours le stockent dans les secrets de la CI pour qu'elle déploie. C'est une mauvaise pratique : identifiant d'admin sans expiration, port 6443 à ouvrir sur Internet, fuite facile (logs, forks, action tierce compromise). Ici le modèle est *pull* : le kubeconfig reste sur l'instance, le port 6443 est fermé, Argo CD tire depuis Git, donc il n'y a rien à stocker côté CI.

## Utiliser SOPS + age (sur le poste)

### Mise en route, une seule fois

```bash
brew install age sops
scripts/secrets.sh keygen            # crée la clé privée et écrit la clé publique dans .sops.yaml
#  >>> sauvegarder ~/.config/sops/age/keys.txt dans un gestionnaire de mots de passe
scripts/secrets.sh init staging      # crée secrets/staging/*.sops.yaml depuis secrets/templates/
scripts/secrets.sh init production
```

### Renseigner ou modifier une valeur

```bash
scripts/secrets.sh set staging cloudflared-sherlock TUNNEL_TOKEN --clipboard   # copier le token, puis lancer
scripts/secrets.sh set staging dns-analyzer-env INTERNAL_API_TOKEN              # sinon : saisie masquée
scripts/secrets.sh edit staging dns-analyzer-env                                # ou tout le fichier dans $EDITOR
```

`set` renseigne une valeur à la fois, sans éditeur : avec `--clipboard`, il lit le presse-papiers puis le vide ; sans, il demande la valeur en saisie masquée (collez avec Cmd+V, rien ne s'affiche).

`secrets/templates/` liste les variables attendues pour chaque Secret (déduites du code des backends) : les comparer au `.env` de chaque backend sur le NAS. Staging et production ont **chacun leurs tunnels** (tokens distincts de ceux du NAS), à créer dans le tableau de bord Cloudflare avant de remplir les fichiers.

### Vérifier

```bash
scripts/secrets.sh check staging     # nombre de CHANGEME restants par fichier : 0 partout = prêt
scripts/secrets.sh apply staging     # déchiffre et applique dans le namespace cyberlab-staging (kind ou cluster existant)
```
