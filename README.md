# Cyberlab AWS

Migration du **cyberlab** d'un NAS Synology vers **AWS**.

**Ce qui est migré** : 3 backends et leurs 3 tunnels, dans chacun des 2 environnements (`staging` et `production`).

| Backends | Tunnels |
|---|---|
| `sherlock` | un tunnel `cloudflared` par backend |
| `dns-analyzer` | |
| `audit-orchestrator` | |

**Comment ça marche**

- **Terraform** crée l'instance EC2 et lui remet un script de démarrage (`scripts/bootstrap-node.sh`).
- **cloud-init** (déjà présent dans l'image Ubuntu) exécute ce script une seule fois, au premier démarrage : c'est lui qui installe K3s et Argo CD.
- Le même script crée 3 `Application` Argo CD (`k8s/argocd/applications/` : `cyberlab-staging`, `cyberlab-production`, `monitoring`). Chacune pointe vers un dossier de `k8s/` : **Argo CD déploie ce dossier** depuis ce dépôt (GitOps). Un dossier de `k8s/` n'est déployé que s'il existe une `Application` qui le référence.
- La **mise en production** se fait par pull request, après validation en staging, puis un clic sur « Sync » dans Argo CD ; le **rollback** par `git revert`.
- Un **Prometheus Agent**, déployé par Argo CD (application `monitoring`, dossier `k8s/monitoring/overlays/aws`), envoie les métriques au Prometheus du NAS par Tailscale : la supervision reste sur le NAS.

> **Test de reconstruction** : `terraform destroy` puis `terraform apply` rétablissent l'ensemble sans aucune intervention manuelle. Voir [docs/test-reconstruction.md](docs/test-reconstruction.md).

**Les deux autres dépôts**

- [cyberlab-infra](https://github.com/NAS-HomeServer/cyberlab-infra) : le NAS reste la production tant que la bascule n'est pas décidée. Ce dépôt n'est pas modifié.
- [HomeServer-monitoring](https://github.com/NAS-HomeServer/HomeServer-monitoring) : Prometheus, Grafana et Alertmanager du NAS.

## Ce qui a été réalisé, en bref

```
1. Infrastructure AWS avec Terraform
     ├─ un réseau privé (VPC), une instance EC2, un rôle IAM limité, une IP élastique
     └─ un budget avec alertes e-mail

2. Un cluster Kubernetes (K3s) qui s'installe tout seul
     ├─ un script de démarrage (cloud-init) installe K3s, Argo CD et Tailscale
     └─ aucun geste manuel : un seul « terraform apply » suffit

3. Déploiement depuis Git (GitOps, Argo CD) : automatique en staging, validé à la main en production
     ├─ 2 environnements : staging et production
     ├─ 3 backends + 3 tunnels cloudflared dans chacun
     ├─ mise en production par pull request, après validation en staging,
     │  puis validation humaine (clic sur « Sync » dans Argo CD)
     └─ retour en arrière par « git revert »

4. Supervision sur le NAS
     ├─ un Prometheus Agent, déployé par Argo CD (application « monitoring »), envoie les métriques au Prometheus du NAS (Tailscale)
     └─ des alertes préviennent sur Discord

5. Sécurité
     ├─ secrets chiffrés dans Git (SOPS + age), jamais en clair
     ├─ images référencées par digest et signatures Cosign vérifiées
     ├─ aucun port entrant public (tunnels sortants, SSH limité à une IP)
     ├─ accès au NAS limité par ACL au seul port de Prometheus
     └─ disque chiffré, accès aux métadonnées AWS durci (IMDSv2)

6. Qualité et preuves
     ├─ CI à 3 contrôles obligatoires (qualité, sécurité, tests sur kind)
     ├─ test de reconstruction : destroy puis apply, tout revient sans intervention
     └─ démonstration : « terraform apply » puis « terraform destroy », tout se reconstruit
```

Résultat mesuré le 17/11/2026 : une instance neuve est entièrement installée en **moins de 3 minutes** (hors création AWS) et les 3 applications Argo CD passent `Synced/Healthy`. Détails et difficultés rencontrées : [docs/notes-projet.md](docs/notes-projet.md).

## Architecture

```
  Internet ─▶ Cloudflare ◀── connexions SORTANTES (aucun port entrant public) ──┐
                                                                                 │
 ┌───────────────── AWS (VPC, sous-réseau public, pas de NAT) ─────────────────┐ │
 │  Instance EC2 t3.medium (Ubuntu 24.04) ── créée par Terraform               │ │
 │  cloud-init : scripts/bootstrap-node.sh (une seule fois)                    │ │
 │   ┌─────────────────────────── K3s ──────────────────────────────────────┐  │ │
 │   │  Argo CD ──surveille──▶ ce dépôt Git (branche main)                   │  │ │
 │   │     ├─ cyberlab-staging     : 3 backends + 3 tunnels ─────────────────┼──┼─┘
 │   │     ├─ cyberlab-production  : 3 backends + 3 tunnels                  │  │
 │   │     └─ monitoring           : Prometheus Agent, node-exporter,        │  │
 │   │                               kube-state-metrics                      │  │
 │   └───────────────────────────────────────────────────────────────────────┘  │
 │  Secrets : chiffrés dans Git (SOPS + age), clé age lue dans SSM au 1er démarrage│
 └──────────────────────────────┬───────────────────────────────────────────────┘
                                │ Tailscale (WireGuard) : remote_write, 100.104.202.81:9090 seulement (ACL)
                                ▼
                     NAS : Prometheus ─▶ règles d'alerte ─▶ Alertmanager ─▶ Discord
```

Flux de déploiement : une pull request fusionnée sur `main` → Argo CD voit le changement → il l'applique au cluster tout seul en staging ; en production, l'application passe `OutOfSync` et attend un clic sur « Sync » (validation humaine). Personne ne lance `kubectl apply`. Détails : [docs/gitops.md](docs/gitops.md).

### Qui installe quoi

`terraform apply` crée l'EC2, le réseau, l'IAM et le budget, avec un `user_data`. Au premier démarrage, cloud-init exécute `scripts/bootstrap-node.sh` (environ 3 minutes) : paquets, K3s, Argo CD, déchiffrement des secrets (la clé age est lue dans SSM puis supprimée du disque), Tailscale, puis création des 3 `Application` Argo CD, qui déploient le reste depuis Git.

| Élément | Installé par | Quand |
|---|---|---|
| EC2, réseau, IAM, budget | **Terraform** (`terraform/main`) | `terraform apply`, à la main |
| K3s, Argo CD, secrets, Tailscale | **`scripts/bootstrap-node.sh`** (cloud-init) | une seule fois, au premier démarrage |
| Backends, tunnels, supervision (les 13 pods applicatifs) | **Argo CD**, depuis `k8s/` | à chaque fusion sur `main` (staging, supervision) ; production après un clic sur « Sync » |

**Exemple : le Prometheus Agent.** Le dossier `k8s/monitoring/` ne s'installe pas seul. Le script de démarrage applique `k8s/argocd/applications/monitoring.yaml` (étape 8/8, un `kubectl apply` par `Application`) ; cette `Application` désigne `k8s/monitoring/overlays/aws` et un namespace `monitoring` ; Argo CD y crée alors le Prometheus Agent, `node-exporter` et `kube-state-metrics`, avec synchronisation automatique. C'est le seul `kubectl apply` du projet : il n'applique que ces 3 fichiers `Application`.

Terraform ne parle jamais à Kubernetes (ni provider `kubernetes`, ni `helm_release`) : il fournit le script via `user_data`, et c'est l'instance qui s'installe elle-même. La CI ne lance ni `plan` ni `apply` : elle valide (`fmt`, `validate`, Trivy) et teste les manifestes sur un cluster jetable. Le « CD » est assuré par Argo CD en mode GitOps, c'est lui qui tire depuis Git.

### Choix structurants (justifications dans [docs/notes-projet.md](docs/notes-projet.md))

| Choix | Pourquoi |
|---|---|
| K3s sur une seule instance | cyberlab de petite taille, coût faible ; un EKS coûterait plus que tout le reste |
| Argo CD + Kustomize | GitOps déclaratif : Git est la source de vérité, la mise en production et le rollback sont des opérations Git, validées par un « Sync » pour la production |
| Tunnels cloudflared | aucun port entrant à ouvrir, le trafic arrive par des connexions sortantes |
| SOPS + age, clé dans SSM | aucun secret en clair dans le dépôt, la clé privée ne vit que dans le Parameter Store |
| Images référencées par digest | une image ne peut pas changer sous nos pieds ; la CI vérifie leur signature Cosign |
| Prometheus Agent → NAS par Tailscale | supervision centralisée sur l'existant, aucun port ouvert, accès limité par ACL |
| État Terraform local | projet à un seul opérateur : le fichier `terraform.tfstate` survit aux `destroy` sur le poste, aucun bucket à créer ni à expliquer |

## Secrets

Le dépôt est **public** : aucun secret n'y entre en clair, ni dans la CI. Les secrets applicatifs (tokens des tunnels, `.env` des backends) sont dans Git **chiffrés par SOPS + age** ; la clé privée vit dans AWS Systems Manager, jamais dans le dépôt, et l'instance la supprime de son disque après usage. La CI refuse tout fichier non chiffré.

→ **[secrets/README.md](secrets/README.md)** : à quoi servent SOPS et age, comment les utiliser, où vit chaque secret, démonstration et questions probables du jury.

## D'où viennent les images

Les 3 backends sont construits et publiés dans le registre GitHub (**ghcr.io**), sous le compte `ag69075`. Le cluster les télécharge sans identifiant : ces paquets sont publics.

| Service | Image | Dépôt qui la construit |
|---|---|---|
| sherlock | `ghcr.io/ag69075/cyberlab_sherlock_backend` | `ag69075/cyberlab_sherlock_backend` |
| dns-analyzer | `ghcr.io/ag69075/cyberlab_dns-analyzer` | `ag69075/cyberlab_dns-analyzer` |
| audit-orchestrator | `ghcr.io/ag69075/cyberlab_audit_orchestrator` | `ag69075/cyberlab_audit_orchestrator` |
| tunnels | `cloudflare/cloudflared` (image officielle, Docker Hub) | Cloudflare |

- **Une image est toujours désignée par son digest** (`@sha256:…`) et non par une étiquette comme `latest` : l'image déployée est exactement celle qui a été validée. Les digests sont écrits dans `k8s/cyberlab/overlays/{staging,production}/kustomization.yaml`.
- **Chaque dépôt de backend signe son image** (Cosign, sans clé, via son workflow GitHub). La CI de ce dépôt vérifie la signature (`ci/verify-signatures.sh`) : une image non signée par le bon dépôt bloque la fusion.
- **Pour déployer une nouvelle version** : le dépôt du backend publie l'image, on écrit son digest dans l'overlay staging (une pull request), puis on recopie ce digest dans l'overlay production (une seconde pull request). Voir [docs/gitops.md](docs/gitops.md).

## Installation complète

Prérequis sur le poste : Terraform ≥ 1.10, AWS CLI configuré, [age](https://github.com/FiloSottile/age) et [SOPS](https://github.com/getsops/sops), `kubectl` (pour le test local), Docker + [kind](https://kind.sigs.k8s.io/) (pour le test local). Côté services : un compte AWS, un domaine Cloudflare avec 6 tunnels créés (un par backend et par environnement), un compte Tailscale, et le Prometheus du NAS.

1. **Cloner le dépôt** et créer une clé SSH dédiée : `ssh-keygen -t ed25519 -f ~/.ssh/cyberlab-aws`.
2. **Secrets** (une fois) : générer la paire age, renseigner les tokens des tunnels et les variables des backends, chiffrés par SOPS. → [secrets/README.md](secrets/README.md) (mise en route)
3. **Paramètres SSM** (une fois, à la main) : la clé privée age (`/cyberlab-aws/age-key`) et la clé d'authentification Tailscale (`/cyberlab-aws/tailscale-authkey`). → [terraform/README.md](terraform/README.md) §2 et §3
4. **Réglages côté NAS** (une fois) : tag et ACL Tailscale, récepteur `remote_write` sur Prometheus, règles d'alerte. → [docs/changements-nas-monitoring.md](docs/changements-nas-monitoring.md)
5. **Créer l'infrastructure** : copier `terraform.tfvars.example` (ignoré par git) dans `terraform/main`, puis :
   ```bash
   cd terraform/main
   terraform init
   terraform plan                # relire avant d'appliquer
   terraform apply               # ⚠ crée des ressources facturées
   ```
   L'instance s'installe seule (environ 3 minutes) : K3s, Argo CD, secrets, Tailscale, puis le déploiement par Git.
6. **Vérifier** : sur l'instance, `sudo kubectl -n argocd get applications` doit montrer les 3 applications `Synced` et `Healthy` (commandes détaillées dans [docs/test-reconstruction.md](docs/test-reconstruction.md)).

### Fin de démonstration

```bash
terraform -chdir=terraform/main destroy    # tout détruire (fin de démonstration : plus rien n'est facturé)
```

Coût : une `t3.medium` coûte environ 5 centimes de dollar par heure d'allumage (tarif à vérifier dans la console AWS) ; après un `destroy`, plus rien n'est facturé. Un budget mensuel avec alertes e-mail est créé par Terraform.

## Exploiter le cyberlab

| Besoin | Commande / page |
|---|---|
| Mettre en production (depuis staging) | recopier le digest dans l'overlay production, via une PR, puis « Sync » dans Argo CD → [docs/gitops.md](docs/gitops.md) |
| Revenir en arrière | `git revert` du commit de fusion, via une PR → [docs/gitops.md](docs/gitops.md) |
| Voir l'état du déploiement | `sudo kubectl -n argocd get applications` (sur l'instance), ou l'interface Argo CD par tunnel SSH |
| Déclencher une alerte pour la démonstration | [docs/changements-nas-monitoring.md](docs/changements-nas-monitoring.md) §5 |
| Mettre à jour les images de staging | modifier le digest dans `k8s/cyberlab/overlays/staging/kustomization.yaml`, via une PR |
| Reconstruire de zéro et vérifier | [docs/test-reconstruction.md](docs/test-reconstruction.md) |
| Montrer Argo CD en soutenance (résilience d'un pod, selfHeal en staging, déploiement et rollback par Git) | [docs/gitops.md](docs/gitops.md), section « Démonstration pour la soutenance » |

## Structure du dépôt

```
k8s/
├── cyberlab/{base,overlays/{kind,staging,production}}   # 3 backends + 3 tunnels cloudflared
├── monitoring/{base,overlays/{kind,aws}}                # Prometheus Agent, node-exporter, kube-state-metrics
├── argocd/applications/                                 # les 3 Application Argo CD
└── kind/                                                # faux NAS et scripts de test local
terraform/main                                           # VPC, EC2, IAM, IP élastique, budget
secrets/                                                 # secrets chiffrés (SOPS + age) par environnement
scripts/
├── bootstrap-node.sh                                    # cloud-init : K3s, Argo CD, secrets, Tailscale, Applications
└── secrets.sh                                           # gestion des secrets chiffrés
nas-monitoring/                                          # règles d'alerte pour le Prometheus du NAS
ci/                                                      # scripts de la CI (rendu, signatures Cosign, secrets chiffrés)
.github/workflows/                                       # ci.yml (pipeline)
docs/                                                    # terraform, kubernetes, gitops, test de reconstruction, supervision NAS, notes de projet
```

Les trois backends ne gardent aucune donnée durable (jobs en mémoire, fichiers temporaires dans `/tmp`) : aucun volume n'est nécessaire.

## Scripts et tests locaux

| Script | Rôle | Lancé par |
|---|---|---|
| `scripts/secrets.sh` | gère les secrets chiffrés : `keygen`, `init`, `set`, `edit`, `check`, `apply` | toi, sur ton poste |
| `scripts/bootstrap-node.sh` | installe K3s, Argo CD, Tailscale, déchiffre les secrets, crée les 3 applications | cloud-init, une seule fois |
| `ci/render.sh` | rend chaque overlay Kustomize en un YAML complet (ce que le cluster recevra) | la CI |
| `ci/verify-signatures.sh` | vérifie la signature Cosign de chaque image backend | la CI |
| `ci/check-secrets-encrypted.sh` | refuse tout secret non chiffré par SOPS | la CI |
| `k8s/kind/test.sh` | déploiement complet sur kind : `/health` des backends, séries de l'agent reçues par un faux NAS | la CI, ou toi |
| `k8s/kind/check-agent-config.sh` | configuration du Prometheus Agent valide (`promtool`) | la CI, ou toi |

Tests en local (Docker, [kind](https://kind.sigs.k8s.io/) et `kubectl` requis, aucun appel à AWS) :

```bash
k8s/kind/test.sh
k8s/kind/test.sh --cleanup   # supprime le cluster de test
```

## Pipeline CI

[`ci.yml`](.github/workflows/ci.yml) s'exécute sur chaque pull request et sur `main` (runners GitHub). Les trois checks sont obligatoires pour fusionner.

| Étape | Contrôles |
|---|---|
| ① Code Quality | yamllint, shellcheck, rendu Kustomize + kubeconform (strict), promtool (configuration de l'agent), `terraform fmt` + `validate` |
| ② Security | Gitleaks, signatures Cosign des backends, Trivy config sur Kubernetes et Terraform (HIGH/CRITICAL bloquants) |
| ③ Tests (kind) | déploiement complet sur un cluster jetable (backends, tunnels, agent, faux NAS) |

## Documentation

- [docs/terraform.md](docs/terraform.md) : ce que Terraform crée, où est le state, comment le lire
- [docs/kubernetes.md](docs/kubernetes.md) : où sont les manifestes, overlays, tunnels, NetworkPolicies, du Git au cluster
- [docs/secrets.md](docs/secrets.md) : comment les secrets sont gérés, version courte (détail : [secrets/README.md](secrets/README.md))
- [docs/notes-projet.md](docs/notes-projet.md) : décisions, alternatives écartées, difficultés rencontrées
- [docs/gitops.md](docs/gitops.md) : Argo CD, mise en production, rollback
- [docs/test-reconstruction.md](docs/test-reconstruction.md) : `destroy` puis `apply`, et ce qui est contrôlé
- [docs/changements-nas-monitoring.md](docs/changements-nas-monitoring.md) : Tailscale, récepteur Prometheus, règles, démonstration d'alerte
- [terraform/README.md](terraform/README.md) : Terraform pas à pas
- [secrets/README.md](secrets/README.md) : SOPS + age expliqué, démonstration
