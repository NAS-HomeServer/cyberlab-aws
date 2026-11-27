# Haute disponibilité, scalabilité, sauvegarde

> **À retenir** : un seul nœud et aucune donnée applicative durable. La reprise consiste à **reconstruire** (Terraform + Git). La haute disponibilité est une cible, pas un acquis.

## 1. Objectifs proposés

AWS est un environnement de démonstration, arrêté le soir.

| Objectif | Valeur |
|---|---|
| Perte acceptée, configuration | rien de ce qui est fusionné sur `main` |
| Perte acceptée, données | scans et jobs en cours |
| Délai de reprise | 15 min après intervention (**à mesurer** ; seul le script de démarrage l'est : 2 min 45 s) |

## 2. Pannes et reprise

| Panne | Reprise |
|---|---|
| Un pod meurt | automatique (Kubernetes) |
| Mauvaise version | `git revert`, puis « Sync » en production |
| Instance perdue | `terraform apply -replace=aws_instance.node`, puis « Sync » |
| Infrastructure détruite | `terraform apply`, puis « Sync » ([procédure](test-reconstruction.md)) |
| Zone AWS indisponible | changer la zone dans `network.tf`, puis `apply` |
| Région indisponible | changer `region`, recréer les paramètres SSM, `apply` |
| GitHub, GHCR ou Cloudflare indisponible | attendre |
| NAS indisponible | services AWS non touchés, mais plus de supervision |

**Point faible : rien n'alerte si l'instance disparaît.** Sans métriques, aucune règle ne se déclenche (alerte d'absence écartée à cause de l'arrêt du soir).

Avant le « Sync » qui suit une reconstruction, relire le diff : `main` peut être plus récent que ce qui tournait.

## 3. Scalabilité

La scalabilité automatique n'est pas en place : c'est un **choix de périmètre**.

| Raison | Explication |
|---|---|
| Besoin | environnement de démonstration, arrêté le soir, sans objectif de charge |
| Application | `dns-analyzer` et `audit-orchestrator` gardent leurs jobs en mémoire : à externaliser avant d'ajouter des réplicas |
| Coût | un seul nœud, pour rester proche d'un budget de 15 $/mois ; un HPA demanderait aussi de la mémoire libre sur ce nœud |

| Axe | Aujourd'hui |
|---|---|
| Plus de pods | nombre de réplicas réglé par environnement via Git ; `sherlock` en a 2 en production |
| Instance plus grosse | variable `instance_type` (`t3` uniquement), avec interruption : solution d'attente |
| Autoscaling | aucun (metrics-server désactivé) |

Les deux réplicas de `sherlock` partagent le même nœud : ils couvrent la perte d'un pod, **pas celle de l'instance**.

**Pour aller plus loin**, dans cet ordre : sortir les jobs de la mémoire (Redis par exemple), activer metrics-server et un HPA, puis ajouter des nœuds avec autoscaling. EKS serait une option si AWS devenait la production ; aujourd'hui, son coût et sa complexité seraient disproportionnés.

## 4. Sauvegarde

Aucune donnée applicative à sauvegarder, et le cluster se reconstruit depuis Git. Voici le reste :

| Élément | Où | Si on le perd | À faire |
|---|---|---|---|
| Code et secrets chiffrés | GitHub, clones | plus de reconstruction | dépôt miroir |
| Clé age | poste, SSM | toutes copies perdues : secrets à recréer | copie hors poste (**à confirmer**) |
| `terraform.tfstate` et `tfvars` | poste | ressources à importer ou supprimer à la main ; réglages à ressaisir | copie hors poste, puis S3 |
| Clé SSH | poste | à régénérer (secours : Session Manager) | rien |
| Clés Tailscale | SSM | supervision coupée jusqu'au remplacement | noter l'échéance (90 jours) |
| Images des backends | GHCR | à reconstruire, nouveau digest | vérifier la rétention |
| Tunnels et Worker | Cloudflare | à recréer à la main | documenter leur configuration |

**Restaurer la clé age** depuis SSM (uniquement si le fichier n'existe plus) :

```bash
mkdir -p ~/.config/sops/age && (umask 077; aws --region eu-west-3 ssm get-parameter --name /cyberlab-aws/age-key --with-decryption --query Parameter.Value --output text > ~/.config/sops/age/keys.txt)
```

## 5. Évolutions

Rien de ceci n'est en place ; à vérifier avant mise en œuvre.

| Palier | Actions | Gain | Contrainte |
|---|---|---|---|
| **1. Presque gratuit** | state sur S3, copies des clés, sonde externe, 2 réplicas par tunnel | moins de pertes, pannes détectées | toujours un seul nœud |
| **2. Auto-remplacement** | groupe d'autoscaling d'une instance, multi-zones | nœud recréé seul | la production attend « Sync » |
| **3. Haute disponibilité** | plusieurs nœuds et zones (K3s HA ou EKS) | la perte d'un nœud ne coupe plus les services répliqués | bien au-delà de 15 $/mois (voir ci-dessous) |
| **4. Scalabilité** | jobs dans Redis, HPA, autoscaling des nœuds | capacité selon la charge | modifier deux backends |

**Coût des paliers**, en ordre de grandeur pour une plateforme allumée 24 h/24 (hors réseau et disques) :

| Option | Par mois, 24 h/24 |
|---|---|
| Aujourd'hui, et paliers 1 et 2 (une seule instance) | environ 36 $ |
| Palier 3 avec K3s (3 nœuds `t3.medium`) | environ 110 $ |
| Palier 3 avec EKS (2 nœuds `t3.medium`) | environ 150 $ |
| Palier 4 | + 36 $ par nœud ajouté |

**Pourquoi 3 nœuds avec K3s ?** Sa base intégrée (etcd) a besoin d'une majorité de serveurs en vie : à 2, perdre un seul bloque le pilotage du cluster ; à 3, on en tolère un. Avec EKS, AWS gère le plan de contrôle à part, d'où 2 nœuds.

EKS facture son plan de contrôle environ 73 $ par mois (0,10 $/h, [tarif AWS](https://aws.amazon.com/eks/pricing/), support standard). Le budget de 15 $ suppose une instance éteinte la plupart du temps.

**Recommandation** : le palier 1 maintenant, la suite seulement si AWS remplace le NAS en production.
