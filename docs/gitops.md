# Déploiement GitOps : Argo CD, mise en production, rollback

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
 PR : on recopie les mêmes digests dans PRODUCTION → CI → fusion
        │
        ▼  l'application passe OutOfSync : rien n'est déployé
 VALIDATION HUMAINE : clic sur « Sync » dans Argo CD
        │
        ▼
 Argo CD : application cyberlab-production → namespace cyberlab-production
```

## Ce que contient chaque brique

| Élément | Rôle |
|---|---|
| `k8s/argocd/applications/*.yaml` | Une `Application` par cible : `cyberlab-staging`, `cyberlab-production`, `monitoring`. Elles surveillent un dossier de ce dépôt. `cyberlab-staging` et `monitoring` appliquent son contenu automatiquement (`prune` et `selfHeal` activés) ; **`cyberlab-production` n'a pas de synchronisation automatique** : chaque changement attend un clic sur « Sync ». |
| `scripts/bootstrap-node.sh` | Étape 8 : crée ces `Application` au premier démarrage de l'instance, ne déclenche aucun déploiement de la production (validation par « Sync »), avec l'URL et la branche choisies dans Terraform (`repo_url`, `repo_ref`). |

Les **secrets** ne passent pas par Argo CD : ils sont appliqués une fois par le script de démarrage (`secrets.sh apply`). Argo CD ne les gère pas, donc `prune` ne peut pas les supprimer.

## Mettre en production (depuis staging)

```bash
git switch main && git pull
git switch -c mise-en-prod/<date>
# recopier à la main les lignes « digest: sha256:… » de overlays/staging/kustomization.yaml
# vers overlays/production/kustomization.yaml (mêmes images, mêmes digests)
git diff k8s/cyberlab/overlays/production
git commit -am "chore(production): met en production les images validées en staging"
git push -u origin HEAD && gh pr create --base main
```

Quand la PR est fusionnée (après les 3 checks), **rien ne change encore en production** : `cyberlab-production` passe `OutOfSync` (jaune). C'est la validation humaine :

- dans l'interface Argo CD : bouton **Refresh** puis **Sync** sur `cyberlab-production` (cocher *Prune* si des ressources ont été retirées) ;
- ou sur l'instance : `sudo kubectl -n argocd patch application cyberlab-production --type merge -p '{"operation":{"sync":{"prune":true}}}'`.

Les mises à jour des pods se font sans coupure (`maxUnavailable: 0`).

## Revenir en arrière (rollback)

Un déploiement défectueux se défait **par Git**, pas par le cluster :

```bash
git switch main && git pull
git revert -m 1 <commit de fusion de la PR fautive>
git push -u origin HEAD               # via une PR, comme tout le reste
```

Une fois la PR du revert fusionnée, Argo CD réapplique l'ancien digest (staging aussitôt ; production après un clic sur « Sync », comme pour toute mise en production). Pour aller vite pendant une démonstration, la même opération se fait en un clic dans l'interface (« Sync » sur un commit précédent), mais seul le `git revert` laisse une trace durable et reste la source de vérité.

## Se connecter à l'interface Argo CD

L'interface n'est **pas exposée sur Internet** (aucun port entrant n'est ouvert) : on y accède par un tunnel SSH depuis le poste. Les commandes se lancent depuis la racine du dépôt, sur le poste qui a fait le `terraform apply`.

### 1. Ouvrir le tunnel (premier terminal)

```bash
ssh -i ~/.ssh/cyberlab-aws -L 8080:localhost:8080 ubuntu@$(terraform -chdir=terraform/main output -raw public_ip) \
  "sudo kubectl -n argocd port-forward svc/argocd-server 8080:443"
```

Laisser ce terminal ouvert : le tunnel n'existe que tant que la commande tourne (`Ctrl-C` pour le fermer). Si le port 8080 est déjà pris sur le poste, remplacer le premier `8080` par un autre (`-L 8443:localhost:8080`) et utiliser ce port à l'étape suivante.

### 2. Ouvrir l'interface

Dans le navigateur : **https://localhost:8080**. Le certificat est auto-signé : le navigateur affiche un avertissement, l'accepter (« Avancé », puis « Continuer »).

### 3. Se connecter (second terminal)

- **Identifiant** : `admin`
- **Mot de passe** : généré à chaque nouvelle instance, il change donc après un `destroy` puis `apply`. Le lire avec :

```bash
ssh -i ~/.ssh/cyberlab-aws ubuntu@$(terraform -chdir=terraform/main output -raw public_ip) \
  "sudo kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
```

Le mot de passe s'affiche sans retour à la ligne, collé juste avant l'invite du terminal.

### 4. Ce qu'on voit

Les trois applications (`cyberlab-staging`, `cyberlab-production`, `monitoring`) en `Synced` et `Healthy`. Un clic sur une application ouvre l'arbre de ses ressources (Deployments, pods, Services). Le bouton **Refresh** force Argo CD à relire Git, utile pendant une démonstration.

Sans interface, l'état se lit en ligne de commande, sur l'instance : `sudo kubectl -n argocd get applications`.

## Démonstration pour la soutenance : trois exemples

Les trois exemples se font sur une instance démarrée et prennent environ 7 minutes. Le premier montre la résilience de Kubernetes ; les deux autres montrent les deux propriétés du GitOps : **Git décide**, et **le cluster suit**. Avant de commencer, ouvrir l'interface Argo CD (voir « Se connecter à l'interface Argo CD ») pour que le jury voie les ressources changer en direct, et se connecter à l'instance :

```bash
ssh -i ~/.ssh/cyberlab-aws ubuntu@$(terraform -chdir=terraform/main output -raw public_ip)
sudo kubectl -n argocd get applications     # les 3 applications doivent être Synced / Healthy
```

### Exemple 1 : la résilience, un pod supprimé est recréé

Ce qu'on montre : si un pod meurt, le service revient tout seul. Aucune ligne de commande n'est nécessaire, tout se fait dans l'interface Argo CD.

1. Ouvrir l'application `cyberlab-production` : la chaîne Deployment → ReplicaSet → Pod est visible.
2. Sur un pod `dns-analyzer` (2 réplicas en production), cliquer sur le menu `⋮` puis **Delete**, et confirmer.
3. Le pod disparaît et un nouveau, au suffixe différent, apparaît en quelques secondes ; l'application reste `Synced` / `Healthy`.

Variante en ligne de commande, sur l'instance :

```bash
sudo kubectl -n cyberlab-production get pods -w
sudo kubectl -n cyberlab-production delete pod -l app.kubernetes.io/name=dns-analyzer --wait=false
```

À dire : **ce n'est pas Argo CD qui recrée le pod, c'est Kubernetes** : le ReplicaSet maintient le nombre de réplicas demandé (`replicas`). Argo CD, lui, garde le *Deployment* conforme à Git, ce que montre l'exemple suivant. Résilience des pods par Kubernetes, résilience de la configuration par Argo CD. Avec 2 réplicas, `dns-analyzer` reste disponible pendant la suppression ; les services à 1 réplica (sherlock par exemple) ont une brève coupure.

Pour montrer aussi qu'Argo CD protège les objets eux-mêmes : `sudo kubectl -n cyberlab-staging delete deploy sherlock`. L'application passe `OutOfSync` puis Argo CD recrée le Deployment, son ReplicaSet et son pod.

### Exemple 2 : le selfHeal, Argo CD annule une modification manuelle

Ce qu'on montre : une modification faite à la main dans le cluster est aussitôt annulée, parce que l'état voulu est celui de Git.

```bash
# 1. État de départ : dns-analyzer a 1 réplica en staging
sudo kubectl -n cyberlab-staging get deploy dns-analyzer

# 2. On le met à 0 à la main : le service est « cassé »
sudo kubectl -n cyberlab-staging scale deploy dns-analyzer --replicas=0

# 3. Quelques secondes plus tard Argo CD l'a remis à 1 (Ctrl-C pour quitter)
sudo kubectl -n cyberlab-staging get deploy dns-analyzer -w
```

À dire : Git ne contient qu'un réplica pour ce service ; Argo CD compare en permanence le cluster à Git (`selfHeal`) et rétablit l'état déclaré. Personne n'a lancé de commande de réparation.

### Exemple 3 : un déploiement par Git, puis un rollback

Ce qu'on montre : un changement se déploie en fusionnant une pull request, et se défait en la revertant. Personne ne touche au cluster. On passe `dns-analyzer` de 1 à 2 réplicas en staging.

1. Dans `k8s/cyberlab/overlays/staging/kustomization.yaml`, ajouter à la fin du fichier (même syntaxe que l'overlay de production) :

   ```yaml
   replicas:
     - name: dns-analyzer
       count: 2
   ```

2. Ouvrir la pull request ; la CI passe ses trois contrôles ; la fusionner.

   ```bash
   git switch -c demo/replicas-staging
   git commit -am "demo: 2 replicas de dns-analyzer en staging"
   git push -u origin HEAD && gh pr create --base main
   ```

3. Sur l'instance, un second pod apparaît sans aucune commande de déploiement (Argo CD relit Git toutes les 3 minutes environ ; « Refresh » dans l'interface accélère) :

   ```bash
   sudo kubectl -n cyberlab-staging get pods -w
   sudo kubectl -n argocd get applications      # cyberlab-staging : Synced / Healthy
   ```

4. Rollback : annuler la fusion par Git, de la même façon (voir « Revenir en arrière » plus haut). Une fois la PR du revert fusionnée, le second pod disparaît.

À dire : le déploiement et le retour en arrière sont des opérations Git, relues et tracées ; le cluster n'est jamais modifié à la main. La production suit le même chemin, en recopiant les digests validés en staging vers production.
