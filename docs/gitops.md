# Déploiement GitOps : Argo CD, promotion, rollback

**Principe : Git est la seule source de vérité.** Personne ne lance `kubectl apply` pour déployer : on fusionne une pull request, Argo CD voit le changement et l'applique au cluster.

```
 backend reconstruit (son dépôt) → nouveau digest d'image
        │  PR : on met le digest dans l'overlay STAGING
        ▼
 CI (3 checks, dont signature Cosign de l'image) → fusion
        │
        ▼
 Argo CD : application cyberlab-staging  → namespace cyberlab-staging
        │  validation en staging
        ▼
 scripts/promote.sh  → PR : mêmes digests dans PRODUCTION → CI → fusion
        │
        ▼
 Argo CD : application cyberlab-production → namespace cyberlab-production
```

## Ce que contient chaque brique

| Élément | Rôle |
|---|---|
| `k8s/argocd/applications/*.yaml` | Une `Application` par cible : `cyberlab-staging`, `cyberlab-production`, `monitoring`. Elles surveillent un dossier de ce dépôt et appliquent son contenu (`prune` et `selfHeal` activés). |
| `scripts/bootstrap-node.sh` | Étape 7 : crée ces `Application` au premier démarrage de l'instance, avec l'URL et la branche choisies dans Terraform (`repo_url`, `repo_ref`). |
| `scripts/promote.sh` | Copie les digests de staging vers production. Aucun commit, aucun réseau : on relit le diff puis on ouvre la PR. |

Les **secrets** ne passent pas par Argo CD : ils sont appliqués une fois par le bootstrap (`secrets.sh apply`). Argo CD ne les gère pas, donc `prune` ne peut pas les supprimer.

## Promouvoir staging → production

```bash
git switch main && git pull
git switch -c promotion/<date>
scripts/promote.sh                    # copie les digests de staging
git diff k8s/cyberlab/overlays/production
git commit -am "chore(production): promeut les images validées en staging"
git push -u origin HEAD && gh pr create --base main
```

Quand la PR est fusionnée (après les 3 checks), Argo CD déploie en production en quelques minutes. Les mises à jour des pods se font sans coupure (`maxUnavailable: 0`).

## Revenir en arrière (rollback)

Un déploiement défectueux se défait **par Git**, pas par le cluster :

```bash
git switch main && git pull
git revert -m 1 <commit de fusion de la PR fautive>
git push -u origin HEAD               # via une PR, comme tout le reste
```

Une fois la PR du revert fusionnée, Argo CD réapplique l'ancien digest. Pour aller vite pendant une démonstration, la même opération se fait en un clic dans l'interface (« Sync » sur un commit précédent), mais seul le `git revert` laisse une trace durable et reste la source de vérité.

## Voir Argo CD

L'interface n'est pas exposée sur Internet. Depuis le poste :

```bash
ssh -i ~/.ssh/cyberlab-aws -L 8080:localhost:8080 ubuntu@$(terraform -chdir=terraform/main output -raw public_ip) \
  "sudo kubectl -n argocd port-forward svc/argocd-server 8080:443"
# puis https://localhost:8080 (certificat auto-signé : l'accepter)
# identifiant : admin ; mot de passe :
ssh -i ~/.ssh/cyberlab-aws ubuntu@<ip> "sudo kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
```

État en ligne de commande : `sudo kubectl -n argocd get applications`.
