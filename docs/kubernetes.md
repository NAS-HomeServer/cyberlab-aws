# Kubernetes : ce qui est en place, simplement

Cette page répond à : **où sont les manifestes** (fichiers YAML) de l'application, **que contiennent-ils**, et **comment arrivent-ils dans le cluster** ? Pour l'infrastructure AWS et le state, voir [terraform.md](terraform.md).

Détails complémentaires : [gitops.md](gitops.md) (Argo CD, mise en production, rollback), [secrets.md](secrets.md) (SOPS + age).

## Quel Kubernetes

**K3s** : une version légère de Kubernetes, **un seul nœud** (l'instance EC2), installée par le script de démarrage (cloud-init), sans `traefik` ni `servicelb` (pas d'entrée publique). **Argo CD** y est installé pour appliquer les manifestes depuis Git. Personne ne lance `kubectl apply` pour déployer.

## Où sont les manifestes

Tout est dans [k8s/](../k8s/), organisé avec **Kustomize** : une **base** commune + des **overlays** (variantes par environnement).

```
k8s/
├── cyberlab/                      # l'application
│   ├── base/                      # manifestes communs à tous les environnements
│   │   ├── sherlock.yaml                 Deployment + Service (port 7100)
│   │   ├── dns-analyzer.yaml             Deployment + Service (port 4002)
│   │   ├── audit-orchestrator.yaml       Deployment + Service (port 4003)
│   │   ├── cloudflared-sherlock.yaml     } un tunnel Cloudflare par backend
│   │   ├── cloudflared-dns.yaml          } (connexion SORTANTE = seule
│   │   ├── cloudflared-audit.yaml        }  entrée du trafic)
│   │   ├── networkpolicy.yaml            règles réseau (voir plus bas)
│   │   └── kustomization.yaml            liste ce qui précède
│   └── overlays/
│       ├── staging/                      namespace cyberlab-staging
│       ├── production/                   namespace cyberlab-production
│       └── kind/                         test local (secrets factices)
├── monitoring/                    # supervision (Prometheus Agent → NAS)
│   ├── base/                      Prometheus Agent, node-exporter, kube-state-metrics, RBAC
│   └── overlays/{aws,kind}/
├── argocd/applications/           # dit à Argo CD quoi surveiller
│   ├── cyberlab-staging.yaml
│   ├── cyberlab-production.yaml
│   └── monitoring.yaml
└── kind/                          # outils du test local (cluster kind)
```

## Les manifestes : ce qu'il faut retenir

**Base** : 3 backends (`sherlock`, `dns-analyzer`, `audit-orchestrator`), chacun avec son tunnel `cloudflared`. Soit **6 Deployments par environnement** (7 pods en production, où `dns-analyzer` a 2 réplicas).

Chaque backend est durci : pas de root (`runAsNonRoot`), système de fichiers en lecture seule, toutes les *capabilities* retirées, profil seccomp `RuntimeDefault`, pas de jeton d'API Kubernetes monté, sondes `startup`/`readiness`/`liveness` sur `/health`, mises à jour sans coupure (`maxUnavailable: 0`).

**Namespaces** : `cyberlab-staging`, `cyberlab-production`, `monitoring`. Staging et production imposent les *Pod Security Standards* niveau **restricted** : le cluster refuse tout pod non conforme.

## Pourquoi un tunnel Cloudflare par backend

**Pourquoi un tunnel.** L'instance n'ouvre aucun port public (sauf SSH depuis l'IP de l'opérateur). `cloudflared` établit une connexion **sortante** vers Cloudflare, et Cloudflare y fait passer le trafic des utilisateurs. Pas de port 80/443 à exposer, pas de load balancer à payer.

**Pourquoi un tunnel par backend, plutôt qu'un seul.** Le schéma vient du déploiement d'origine sur le NAS (3 backends, chacun derrière son tunnel) et a été conservé et durci sur AWS. Ses avantages :

- **Isolation réseau.** Une NetworkPolicy n'autorise chaque tunnel qu'à joindre son backend. Un tunnel compromis n'ouvre pas l'accès aux deux autres services ; un tunnel unique devrait pouvoir atteindre les trois.
- **Moindre privilège sur les secrets.** Chaque tunnel ne reçoit que son propre `TUNNEL_TOKEN`. (Sur le NAS, il recevait tout le `.env` de son backend.)
- **Pannes indépendantes.** Un tunnel qui tombe ne coupe que son service ; sa sonde `/ready` le redémarre seul, et son `/metrics` le supervise séparément.
- **Un point d'entrée par service** côté Cloudflare (un nom de domaine par backend).

**Ce que ça coûte** : 3 pods supplémentaires par environnement (13 pods applicatifs au total : 6 en staging, 7 en production), l'une des raisons du choix d'une `t3.medium`.

**Un jeu de tunnels par environnement**, avec de nouveaux tokens : réutiliser ceux du NAS répartirait le trafic réel entre le NAS et AWS. La supervision vers le NAS, elle, passe par Tailscale, pas par un tunnel.

## Les règles réseau (NetworkPolicies)

[networkpolicy.yaml](../k8s/cyberlab/base/networkpolicy.yaml) : tout l'**entrant** est refusé par défaut, puis on ouvre le strict nécessaire :

| Règle | Autorise |
|---|---|
| `default-deny-ingress` | rien (base de départ) |
| `allow-tunnels-to-backends` | les tunnels → les backends |
| `allow-audit-to-dns-analyzer` | `audit-orchestrator` → `dns-analyzer` |
| `allow-monitoring-to-tunnels` | namespace `monitoring` → métriques des tunnels |

L'**egress** reste libre (les backends interrogent Internet par nature).

## Ce qui change selon l'environnement (overlays)

| | staging | production |
|---|---|---|
| Namespace | `cyberlab-staging` | `cyberlab-production` |
| Image des backends | digest `sha256:…` (arrive en premier) | mêmes digests, recopiés après validation |
| `dns-analyzer` | 1 réplica | **2 réplicas** |
| Limites mémoire | réduites (sherlock 384 Mi, les autres 256 Mi) | celles de la base |
| Synchronisation Argo CD | **automatique** | **sur clic « Sync »** (validation humaine) |

Les images sont référencées par **digest** (empreinte immuable), pas par un tag mobile : on sait exactement quel binaire tourne. La CI vérifie leur signature Cosign.

## Du Git au cluster

1. Une PR modifie un manifeste (typiquement un digest dans un overlay) → la CI la contrôle (rendu Kustomize via [ci/render.sh](../ci/render.sh), validation, scan, signatures, secrets chiffrés).
2. Fusion sur `main`.
3. Argo CD voit le changement :
   - **staging et monitoring** : appliqué tout seul (`prune` + `selfHeal` : une ressource retirée de Git est supprimée, une modification manuelle dans le cluster est annulée) ;
   - **production** : l'application passe `OutOfSync` et **attend un clic sur « Sync »**.
4. Retour en arrière : `git revert` + PR (voir [gitops.md](gitops.md)).

## Les secrets

Les manifestes ne contiennent **aucun secret en clair**. Les secrets sont dans `secrets/<env>/*.sops.yaml`, **chiffrés** avec SOPS + age (valeurs illisibles, noms lisibles). Ils ne passent pas par Argo CD : le script de démarrage les applique une fois (`scripts/secrets.sh apply`) avec la clé age lue dans SSM, puis efface la clé du disque.

## Voir les manifestes tels que le cluster les reçoit

Le YAML « final » (base + overlay fusionnés) se génère localement, sans cluster :

```bash
kubectl kustomize k8s/cyberlab/overlays/staging       # ce que reçoit staging
kubectl kustomize k8s/cyberlab/overlays/production    # ce que reçoit la production
kubectl kustomize k8s/monitoring/overlays/aws         # la supervision
```

Et, sur l'instance (accès SSH, voir [terraform.md](terraform.md)) :

```bash
sudo kubectl -n argocd get applications               # Synced / Healthy ?
sudo kubectl -n cyberlab-production get pods
sudo kubectl -n cyberlab-production get deploy dns-analyzer -o yaml   # manifeste appliqué
```

## Test local sans AWS

L'overlay `kind` + [k8s/kind/](../k8s/kind/) permettent de tester les manifestes dans un cluster kind sur le poste, avec des secrets factices (aucune valeur réelle).

## Aide-mémoire

| Je cherche… | C'est là |
|---|---|
| Les manifestes d'un backend | `k8s/cyberlab/base/<nom>.yaml` |
| Ce qui diffère staging/production | `k8s/cyberlab/overlays/<env>/kustomization.yaml` |
| Les règles réseau | `k8s/cyberlab/base/networkpolicy.yaml` |
| Ce qu'Argo CD surveille | `k8s/argocd/applications/*.yaml` |
| Les secrets chiffrés | `secrets/<env>/*.sops.yaml` |
