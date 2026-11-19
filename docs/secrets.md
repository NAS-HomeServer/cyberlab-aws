# Les secrets : comment ils sont gérés

Version courte. Le détail (mise en route, démonstration, questions du jury) est dans [secrets/README.md](../secrets/README.md).

## Le problème

L'application a besoin de secrets (tokens des 6 tunnels Cloudflare, variables des backends). Or ce dépôt est **public** et Git garde tout l'historique : un secret écrit en clair y serait visible pour toujours.

## La solution : chiffrer les secrets, les mettre dans Git

- **age** crée une paire de clés : une clé **publique** (pour chiffrer, versionnée dans `.sops.yaml`) et une clé **privée** (pour déchiffrer, jamais dans le dépôt).
- **SOPS** applique age à un fichier YAML : il chiffre les **valeurs** et laisse les **noms** lisibles. Dans une PR, on voit *quel* secret change, jamais sa valeur.

Image : la clé publique est un cadenas ouvert que tout le monde peut fermer ; seule la clé privée l'ouvre.

Les fichiers chiffrés sont dans `secrets/staging/` et `secrets/production/` (5 par environnement, `*.sops.yaml`).

## Le trajet d'un secret

```
 MON POSTE                     GIT (public)              L'INSTANCE AWS
 scripts/secrets.sh set ─────▶ secrets/*.sops.yaml ────▶ script de démarrage
 (chiffre avec la clé          (valeurs illisibles)       ├─ lit la clé privée dans AWS SSM
  publique)                         │                     ├─ déchiffre avec SOPS
                               la CI refuse               ├─ crée les Secrets Kubernetes
                               tout fichier en clair      └─ supprime la clé du disque
```

1. **Je chiffre** sur mon poste : `scripts/secrets.sh set <env> <fichier> <CLE>` (saisie masquée).
2. **Je commite** le fichier chiffré. La CI vérifie que rien n'est en clair (`ci/check-secrets-encrypted.sh`) et lance Gitleaks.
3. **À la reconstruction**, le script de démarrage de l'instance récupère la clé privée dans AWS Systems Manager, déchiffre, crée les Secrets Kubernetes, puis **efface la clé** de son disque.

Résultat : `terraform apply` reconstruit tout sans que personne ne retape un secret.

## Où vit chaque secret

En bref : les secrets applicatifs sont dans Git **chiffrés** ; la clé privée age et la clé Tailscale sont dans AWS SSM (créées à la main, hors Terraform) ; la clé AWS reste sur le poste ; le kubeconfig reste sur l'instance. Le rôle IAM de l'instance ne lit **que ces deux paramètres SSM**.

Le tableau complet (une ligne par secret, avec sa protection) est dans [secrets/README.md](../secrets/README.md#où-vit-chaque-secret), qui en est la **seule version de référence**.

## Pourquoi le kubeconfig n'est pas dans les paramètres Git

Beaucoup de cours le stockent dans les secrets de la CI (GitHub/GitLab) pour que la CI déploie. C'est une mauvaise pratique, et ce projet l'évite :

- **Droits trop larges** : c'est un identifiant d'admin du cluster, sans expiration. Qui le lit contrôle tout.
- **Surface d'attaque** : la CI devrait joindre l'API Kubernetes (6443), donc il faudrait l'ouvrir sur Internet.
- **Fuite facile** : logs, PR de forks, workflow modifié, action tierce compromise. La CI devient une porte d'entrée vers le cluster.

Ici, le modèle est *pull* : le kubeconfig reste sur l'instance (`/etc/rancher/k3s/k3s.yaml`), le port 6443 est fermé, et Argo CD tire depuis Git. Personne ne pousse vers le cluster, donc il n'y a rien à stocker côté Git.

Si la CI devait un jour parler au cluster : un ServiceAccount aux droits minimaux, un token à durée courte (ou OIDC), et un accès privé (Tailscale), jamais le kubeconfig admin.

## Ce qu'il faut savoir

- **Argo CD ne gère pas les secrets** : le script de démarrage les applique une fois. Modifier un secret demande donc `scripts/secrets.sh apply`, pas seulement un `git push`.
- **Perdre la clé privée = perdre les secrets chiffrés.** D'où une sauvegarde dans un gestionnaire de mots de passe **et** dans SSM. Il faudrait alors régénérer une clé et ressaisir les valeurs.
- **Limites assumées** : la clé privée est un point unique à protéger, pas de rotation automatique, et dans le cluster les Secrets Kubernetes ne sont pas chiffrés dans la base de K3s (le disque, lui, est chiffré).

## Les commandes utiles

```bash
scripts/secrets.sh keygen                       # une fois : crée la paire de clés
scripts/secrets.sh init staging                 # crée les fichiers chiffrés depuis les modèles
scripts/secrets.sh set staging dns-analyzer-env INTERNAL_API_TOKEN   # renseigne une valeur
scripts/secrets.sh check staging                # compte les CHANGEME restants (0 = prêt)
scripts/secrets.sh apply staging                # déchiffre et applique dans le cluster
```
