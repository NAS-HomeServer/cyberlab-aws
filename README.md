# Cyberlab AWS

Migration du **cyberlab** d'un NAS Synology vers **AWS**.

**Ce qui est migré** : 3 backends et leurs 3 tunnels, dans chacun des 2 environnements (`staging` et `production`).

| Backends | Tunnels |
|---|---|
| `sherlock` | un tunnel `cloudflared` par backend |
| `dns-analyzer` | |
| `audit-orchestrator` | |

**Comment ça marche**

- **Terraform** crée l'instance EC2.
- **cloud-init** y installe K3s et Argo CD, une seule fois, au premier démarrage.
- **Argo CD** déploie tout depuis ce dépôt (GitOps).
- La **promotion** de staging vers production se fait par pull request, le **rollback** par `git revert`.
- Un **Prometheus Agent** envoie les métriques au Prometheus du NAS par Tailscale : la supervision reste sur le NAS.

> **Test de reconstruction** : `terraform destroy` puis `terraform apply` rétablissent l'ensemble sans aucune intervention manuelle, vérifié par un script. Voir [docs/test-reconstruction.md](docs/test-reconstruction.md).

**Les deux autres dépôts**

- [cyberlab-infra](https://github.com/NAS-HomeServer/cyberlab-infra) : le NAS reste la production tant que la bascule n'est pas décidée. Ce dépôt n'est pas modifié.
- [HomeServer-monitoring](https://github.com/NAS-HomeServer/HomeServer-monitoring) : Prometheus, Grafana et Alertmanager du NAS.

## Ce qui a été réalisé, en bref

```
1. Infrastructure AWS avec Terraform
     ├─ un réseau privé (VPC), une instance EC2, un rôle IAM limité, une IP élastique
     ├─ un budget avec alertes e-mail
     └─ un bucket S3 à part pour l'état Terraform, qui n'est jamais détruit

2. Un cluster Kubernetes (K3s) qui s'installe tout seul
     ├─ un script de démarrage (cloud-init) installe K3s, Argo CD et Tailscale
     └─ aucun geste manuel : un seul « terraform apply » suffit

3. Déploiement automatique depuis Git (GitOps, Argo CD)
     ├─ 2 environnements : staging et production
     ├─ 3 backends + 3 tunnels cloudflared dans chacun
     ├─ promotion staging → production par pull request
     └─ retour en arrière par « git revert »

4. Supervision sur le NAS
     ├─ un Prometheus Agent envoie les métriques au Prometheus du NAS (Tailscale)
     └─ des alertes testées préviennent sur Discord

5. Sécurité
     ├─ secrets chiffrés dans Git (SOPS + age), jamais en clair
     ├─ images référencées par digest et signatures Cosign vérifiées
     ├─ aucun port entrant public (tunnels sortants, SSH limité à une IP)
     ├─ accès au NAS limité par ACL au seul port de Prometheus
     └─ disque chiffré, accès aux métadonnées AWS durci (IMDSv2)

6. Qualité et preuves
     ├─ CI à 3 contrôles obligatoires (qualité, sécurité, tests sur kind)
     ├─ test de reconstruction : destroy puis apply, tout revient sans intervention
     └─ script de vérification : 11 contrôles, dont l'arrivée des métriques sur le NAS
```

Résultat mesuré le 17/11/2026 : une instance neuve est entièrement installée en **moins de 3 minutes** (hors création AWS) et les 11 contrôles de `scripts/verify-rebuild.sh` passent. Détails et difficultés rencontrées : [docs/notes-projet.md](docs/notes-projet.md).

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

Flux de déploiement : une pull request fusionnée sur `main` → Argo CD voit le changement → il l'applique au cluster. Personne ne lance `kubectl apply`. Détails : [docs/gitops.md](docs/gitops.md).

### Choix structurants (justifications dans [docs/notes-projet.md](docs/notes-projet.md))

| Choix | Pourquoi |
|---|---|
| K3s sur une seule instance | cyberlab de petite taille, coût faible ; un EKS coûterait plus que tout le reste |
| Argo CD + Kustomize | GitOps déclaratif : Git est la source de vérité, la promotion et le rollback sont des opérations Git |
| Tunnels cloudflared | aucun port entrant à ouvrir, le trafic arrive par des connexions sortantes |
| SOPS + age, clé dans SSM | aucun secret en clair dans le dépôt, la clé privée ne vit que dans le Parameter Store |
| Images référencées par digest | une image ne peut pas changer sous nos pieds ; la CI vérifie leur signature Cosign |
| Prometheus Agent → NAS par Tailscale | supervision centralisée sur l'existant, aucun port ouvert, accès limité par ACL |
| Bucket d'état Terraform à part | il survit aux `destroy` ; l'infrastructure se détruit et se recrée librement |

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
- **Pour déployer une nouvelle version** : le dépôt du backend publie l'image, son digest arrive dans staging (workflow `Sync digests`), puis on le promeut en production (`scripts/promote.sh`). Voir [docs/gitops.md](docs/gitops.md).

## Installation complète

Prérequis sur le poste : Terraform ≥ 1.10, AWS CLI configuré, [age](https://github.com/FiloSottile/age) et [SOPS](https://github.com/getsops/sops), `kubectl` (pour le test local), Docker + [kind](https://kind.sigs.k8s.io/) (pour le test local). Côté services : un compte AWS, un domaine Cloudflare avec 6 tunnels créés (un par backend et par environnement), un compte Tailscale, et le Prometheus du NAS.

1. **Cloner le dépôt** et créer une clé SSH dédiée : `ssh-keygen -t ed25519 -f ~/.ssh/cyberlab-aws`.
2. **Secrets** (une fois) : générer la paire age, renseigner les tokens des tunnels et les variables des backends, chiffrés par SOPS. → [secrets/README.md](secrets/README.md)
3. **Bucket d'état Terraform** (une fois, jamais détruit) : `terraform/bootstrap`. → [terraform/README.md](terraform/README.md) §1
4. **Paramètres SSM** (une fois, à la main) : la clé privée age (`/cyberlab-aws/age-key`) et la clé d'authentification Tailscale (`/cyberlab-aws/tailscale-authkey`). → [terraform/README.md](terraform/README.md) §2 bis et quater
5. **Réglages côté NAS** (une fois) : tag et ACL Tailscale, récepteur `remote_write` sur Prometheus, règles d'alerte. → [docs/changements-nas-monitoring.md](docs/changements-nas-monitoring.md)
6. **Créer l'infrastructure** : copier `backend.hcl.example` et `terraform.tfvars.example` (ignorés par git) dans `terraform/main`, puis :
   ```bash
   cd terraform/main
   terraform init -backend-config=backend.hcl
   terraform plan                # relire avant d'appliquer
   terraform apply               # ⚠ crée des ressources facturées
   ```
   L'instance s'installe seule (environ 3 minutes) : K3s, Argo CD, secrets, Tailscale, puis le déploiement par Git.
7. **Vérifier** : `scripts/verify-rebuild.sh` contrôle le bootstrap, les 3 applications Argo CD, les 12 pods et l'arrivée des métriques sur le NAS (code de sortie 0 = tout est OK).

### Au quotidien

```bash
scripts/instance.sh stop      # arrête l'instance : plus de facturation de calcul
scripts/instance.sh start     # la redémarre ; K3s relance tout, l'IP ne change pas
terraform -chdir=terraform/main destroy    # tout détruire (test de reconstruction uniquement)
```

Coût : une `t3.medium` coûte environ 5 centimes de dollar par heure d'allumage (tarif à vérifier dans la console AWS) ; arrêtée, il ne reste que le disque et l'IP élastique. Un budget mensuel avec alertes e-mail est créé par Terraform.

## Exploiter le cyberlab

| Besoin | Commande / page |
|---|---|
| Promouvoir staging → production | `scripts/promote.sh`, puis PR → [docs/gitops.md](docs/gitops.md) |
| Revenir en arrière | `git revert` du commit de fusion, via une PR → [docs/gitops.md](docs/gitops.md) |
| Voir l'état du déploiement | `sudo kubectl -n argocd get applications` (sur l'instance), ou l'interface Argo CD par tunnel SSH |
| Déclencher une alerte pour la démonstration | [docs/changements-nas-monitoring.md](docs/changements-nas-monitoring.md) §5 |
| Mettre à jour les images de staging | workflow `Sync digests` (toutes les 6 h) : PR automatique depuis le compose du NAS |
| Reconstruire de zéro et vérifier | [docs/test-reconstruction.md](docs/test-reconstruction.md) |

## Structure du dépôt

```
k8s/
├── cyberlab/{base,overlays/{kind,staging,production}}   # 3 backends + 3 tunnels cloudflared
├── monitoring/{base,overlays/{kind,aws}}                # Prometheus Agent, node-exporter, kube-state-metrics
├── argocd/applications/                                 # les 3 Application Argo CD
└── kind/                                                # faux NAS et scripts de test local
terraform/{bootstrap,main}                               # bucket d'état (à part) puis VPC, EC2, IAM, IP élastique, budget
secrets/                                                 # secrets chiffrés (SOPS + age) par environnement
scripts/
├── bootstrap-node.sh                                    # cloud-init : K3s, Argo CD, secrets, Tailscale, Applications
├── verify-rebuild.sh                                    # contrôle complet après un apply
├── instance.sh                                          # arrêter / démarrer l'instance
├── promote.sh, lib-digests.sh                           # promotion staging → production
└── secrets.sh                                           # gestion des secrets chiffrés
nas-monitoring/                                          # règles d'alerte pour le Prometheus du NAS + tests promtool
ci/                                                      # scripts de la CI (rendu, signatures Cosign, scan, synchro des digests)
.github/workflows/                                       # ci.yml (pipeline), sync-digests.yml
docs/                                                    # gitops, test de reconstruction, supervision NAS, notes de projet
```

Les trois backends ne gardent aucune donnée durable (jobs en mémoire, fichiers temporaires dans `/tmp`) : aucun volume n'est nécessaire.

## À quoi sert chaque script

### Au quotidien (sur ton poste)

| Script | Rôle | Quand l'utiliser |
|---|---|---|
| `scripts/instance.sh` | arrête, démarre, donne l'état ou l'IP de l'instance, sans la détruire | `start` / `stop` chaque jour pour ne pas payer pour rien |
| `scripts/verify-rebuild.sh` | contrôle complet d'une instance (11 vérifications, dont l'arrivée des métriques sur le NAS) | après un `terraform apply`, ou avant une démonstration |
| `scripts/promote.sh` | copie les digests d'images de staging vers production (aucun commit, aucun réseau) | pour promouvoir : on relit le diff, puis on ouvre une PR |
| `scripts/secrets.sh` | gère les secrets chiffrés : `keygen`, `init`, `set`, `edit`, `check`, `apply` | pour créer ou modifier un secret sans jamais l'écrire en clair |

### Lancés automatiquement (tu n'as rien à faire)

| Script | Rôle | Lancé par |
|---|---|---|
| `scripts/bootstrap-node.sh` | installe K3s, Argo CD, Tailscale, déchiffre et applique les secrets, crée les 3 applications Argo CD | cloud-init, une seule fois au premier démarrage de l'instance |
| `ci/sync-digests.sh` | aligne les digests de staging sur ceux de `cyberlab-infra` (lecture seule) | workflow `Sync digests`, toutes les 6 h |
| `ci/render.sh` | transforme chaque overlay Kustomize en un YAML complet, celui que le cluster recevra | la CI, avant kubeconform et Trivy |
| `ci/verify-signatures.sh` | vérifie la signature Cosign de chaque image backend | la CI (contrôle Security) |
| `ci/scan-images.sh` | scanne les vulnérabilités des images avec Trivy (informatif, ne bloque jamais) | la CI (contrôle Security) |
| `ci/check-secrets-encrypted.sh` | refuse tout secret qui ne serait pas chiffré par SOPS | la CI (contrôle Security) |
| `nas-monitoring/check-rules.sh` | valide la syntaxe des règles d'alerte du NAS et leurs tests unitaires | la CI (contrôle Code Quality) |

### Bibliothèque (ne se lance pas seule)

| Script | Rôle |
|---|---|
| `scripts/lib-digests.sh` | fonctions partagées pour lire et écrire les digests dans les `kustomization.yaml` ; utilisée par `promote.sh` et `sync-digests.sh` |

### Tests locaux sur kind (aucun appel à AWS)

| Script | Ce qu'il prouve |
|---|---|
| `k8s/kind/test.sh` | déploiement complet : backends répondent sur `/health`, les séries de l'agent arrivent sur un faux NAS avec les bons labels |
| `k8s/kind/test-resilience.sh` | si la liaison avec le NAS est coupée puis rétablie, l'agent rattrape son retard sans trou dans les séries |
| `k8s/kind/test-argocd.sh` | Argo CD déploie depuis GitHub, annule une modification manuelle (selfHeal) et recrée une ressource supprimée |
| `k8s/kind/test-secrets.sh` | la chaîne SOPS + age fonctionne de bout en bout, avec une clé jetable |
| `k8s/kind/check-agent-config.sh` | la configuration du Prometheus Agent est valide (`promtool`) |

## Tester en local (aucun appel à AWS)

Prérequis : Docker, [kind](https://kind.sigs.k8s.io/), `kubectl`.

```bash
k8s/kind/check-agent-config.sh kind   # promtool sur la config de l'agent
k8s/kind/test.sh                      # déploiement complet + séries reçues par un faux NAS
k8s/kind/test-resilience.sh           # coupe puis rétablit la liaison remote_write
k8s/kind/test-argocd.sh               # Argo CD déploie l'overlay depuis GitHub, selfHeal, recréation
k8s/kind/test.sh --cleanup && k8s/kind/test-argocd.sh --cleanup   # supprime les clusters de test
```

## Pipeline CI

[`ci.yml`](.github/workflows/ci.yml) s'exécute sur chaque pull request et sur `main` (runners GitHub). Les trois checks sont obligatoires pour fusionner.

| Étape | Contrôles |
|---|---|
| ① Code Quality | yamllint, shellcheck, rendu Kustomize + kubeconform (strict), promtool (agent et règles du NAS, avec tests unitaires), `terraform fmt` + `validate` |
| ② Security | Gitleaks, signatures Cosign des backends, Trivy config sur Kubernetes et Terraform (HIGH/CRITICAL bloquants), scan Trivy des images (informatif) |
| ③ Tests (kind) | déploiement complet sur un cluster jetable, résilience du `remote_write`, déploiement par Argo CD (selfHeal) |

Les mêmes scripts se lancent en local : `ci/render.sh <dossier>`, `ci/verify-signatures.sh`, `ci/scan-images.sh <dossier>`, `nas-monitoring/check-rules.sh`.

## Documentation

- [docs/notes-projet.md](docs/notes-projet.md) : décisions, alternatives écartées, difficultés rencontrées (y compris les erreurs et leurs corrections)
- [docs/gitops.md](docs/gitops.md) : Argo CD, promotion, rollback
- [docs/test-reconstruction.md](docs/test-reconstruction.md) : `destroy` puis `apply`, et ce qui est contrôlé
- [docs/changements-nas-monitoring.md](docs/changements-nas-monitoring.md) : Tailscale, récepteur Prometheus, règles, démonstration d'alerte
- [terraform/README.md](terraform/README.md), [secrets/README.md](secrets/README.md)
