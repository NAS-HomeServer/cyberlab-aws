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

> **Test de reconstruction** : `terraform destroy` puis `terraform apply` rétablissent l'ensemble sans aucune intervention manuelle. Voir [docs/test-reconstruction.md](docs/test-reconstruction.md).

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

Flux de déploiement : une pull request fusionnée sur `main` → Argo CD voit le changement → il l'applique au cluster. Personne ne lance `kubectl apply`. Détails : [docs/gitops.md](docs/gitops.md).

### La chaîne complète : de `terraform apply` aux applications

```
terraform apply
   └─ crée l'EC2 (t3.medium) + réseau + IAM + budget, avec un user_data
        └─ cloud-init exécute scripts/bootstrap-node.sh (≈ 3 min)
             1. paquets de base, AWS CLI, SOPS
             2. K3s (sans traefik ni servicelb)
             3. Argo CD (install.yaml épinglé par version + SHA-256)
             4. clone du dépôt
             5. clé age lue dans SSM → déchiffrement des secrets → apply dans le cluster → clé supprimée du disque
             6. Tailscale (rejoint le tailnet pour joindre le NAS)
             7. création des 3 Applications Argo CD
                  └─ Argo CD déploie ensuite depuis Git :
                     cyberlab-staging, cyberlab-production, monitoring
```

| Élément | Installé par | Quand |
|---|---|---|
| EC2, réseau, IAM, budget, bucket d'état | **Terraform** (`terraform/main` et `terraform/bootstrap`) | `terraform apply`, à la main |
| K3s, Argo CD, secrets, Tailscale | **`scripts/bootstrap-node.sh`** (cloud-init) | une seule fois, au premier démarrage |
| Backends, tunnels, supervision (les 12 pods) | **Argo CD**, depuis `k8s/` | à chaque fusion sur `main` |

Terraform ne parle jamais à Kubernetes (ni provider `kubernetes`, ni `helm_release`) : il fournit le script via `user_data`, et c'est l'instance qui s'installe elle-même. La CI ne lance ni `plan` ni `apply` : elle valide (`fmt`, `validate`, Trivy) et teste les manifestes sur un cluster jetable. Le « CD » est assuré par Argo CD en mode GitOps, c'est lui qui tire depuis Git.

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

## Où sont les secrets (clé AWS, kubeconfig, CI)

Le dépôt est **public** : la règle est qu'aucun secret n'y entre, ni en clair, ni dans la CI. Voici où se trouve chacun.

| Secret | Où il vit | Ce qui le protège |
|---|---|---|
| **Clé AWS** (pour `terraform apply`) | uniquement sur ton poste (AWS CLI configuré) | **absente de GitHub** : la CI ne parle jamais à AWS (`init -backend=false`, aucun `plan` ni `apply`). `*.tfvars` et `*.tfstate` sont dans `.gitignore` |
| **kubeconfig** | uniquement sur l'instance (`/etc/rancher/k3s/`) | **absent de GitHub** : la CI ne déploie rien sur le vrai cluster, c'est Argo CD (dans le cluster) qui tire depuis Git. Le port 6443 n'est pas ouvert (voir `security.tf`) |
| **Secrets applicatifs** (tokens des 3 tunnels cloudflared, `.env` des backends) | dans Git, **chiffrés par SOPS + age** (`secrets/*/*.sops.yaml`) | la CI refuse tout fichier non chiffré (`ci/check-secrets-encrypted.sh`) et passe Gitleaks. Seule la clé **publique** age est versionnée (`.sops.yaml`) |
| **Clé privée age** | AWS Systems Manager Parameter Store (SecureString) | lue par l'instance au premier démarrage, puis **supprimée du disque** (`shred`). Jamais dans le dépôt, ni dans `user_data`, ni dans l'état Terraform |
| **Clé d'authentification Tailscale** | Parameter Store (SecureString), créée à la main | même chemin que la clé age ; sans elle, l'instance démarre sans lien vers le NAS |
| **Identifiants Argo CD → Git** | aucun | le dépôt est public, Argo CD le clone sans identifiant |
| **Accès au registre d'images** | aucun | les images ghcr.io sont publiques ; leur signature Cosign est vérifiée **sans clé** (identité du workflow GitHub) |

**Comment l'instance accède à ses deux paramètres sans clé stockée** : elle a un rôle IAM (`terraform/main/iam.tf`) qui n'autorise que `ssm:GetParameter` sur ces deux paramètres, et rien d'autre (ni S3, ni EC2, ni IAM). Les identifiants temporaires du rôle sont fournis par le service de métadonnées, durci en IMDSv2 avec `hop limit = 1` : un pod compromis ne peut pas les atteindre.

**Côté CI** : `ci.yml` n'utilise aucun secret du dépôt et ne demande que `permissions: contents: read`. Aucun workflow n'écrit dans le dépôt. Les runners sont hébergés par GitHub, jamais auto-hébergés : une PR venue d'un fork n'exécute donc rien sur ta machine et n'a rien à voler.

**Le jour où un `terraform plan` sera ajouté à la CI** : il faudra une authentification **OIDC** GitHub → AWS avec un rôle en lecture seule, sans clé stockée, et le garder inaccessible aux PR de forks.

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
- **Pour déployer une nouvelle version** : le dépôt du backend publie l'image, on écrit son digest dans l'overlay staging (une pull request), puis on le promeut en production (`scripts/promote.sh`). Voir [docs/gitops.md](docs/gitops.md).

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
7. **Vérifier** : sur l'instance, `sudo kubectl -n argocd get applications` doit montrer les 3 applications `Synced` et `Healthy` (commandes détaillées dans [docs/test-reconstruction.md](docs/test-reconstruction.md)).

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
| Mettre à jour les images de staging | modifier le digest dans `k8s/cyberlab/overlays/staging/kustomization.yaml`, via une PR |
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
├── instance.sh                                          # arrêter / démarrer l'instance
├── promote.sh                                           # promotion staging → production
└── secrets.sh                                           # gestion des secrets chiffrés
nas-monitoring/                                          # règles d'alerte pour le Prometheus du NAS + tests promtool
ci/                                                      # scripts de la CI (rendu, signatures Cosign, scan, synchro des digests)
.github/workflows/                                       # ci.yml (pipeline)
docs/                                                    # gitops, test de reconstruction, supervision NAS, notes de projet
```

Les trois backends ne gardent aucune donnée durable (jobs en mémoire, fichiers temporaires dans `/tmp`) : aucun volume n'est nécessaire.

## À quoi sert chaque script

### Au quotidien (sur ton poste)

| Script | Rôle | Quand l'utiliser |
|---|---|---|
| `scripts/instance.sh` | arrête, démarre, donne l'état ou l'IP de l'instance, sans la détruire | `start` / `stop` chaque jour pour ne pas payer pour rien |
| `scripts/promote.sh` | copie les digests d'images de staging vers production (aucun commit, aucun réseau) | pour promouvoir : on relit le diff, puis on ouvre une PR |
| `scripts/secrets.sh` | gère les secrets chiffrés : `keygen`, `init`, `set`, `edit`, `check`, `apply` | pour créer ou modifier un secret sans jamais l'écrire en clair |

### Lancés automatiquement (tu n'as rien à faire)

| Script | Rôle | Lancé par |
|---|---|---|
| `scripts/bootstrap-node.sh` | installe K3s, Argo CD, Tailscale, déchiffre et applique les secrets, crée les 3 applications Argo CD | cloud-init, une seule fois au premier démarrage de l'instance |
| `ci/render.sh` | transforme chaque overlay Kustomize en un YAML complet, celui que le cluster recevra | la CI, avant kubeconform et Trivy |
| `ci/verify-signatures.sh` | vérifie la signature Cosign de chaque image backend | la CI (contrôle Security) |
| `ci/check-secrets-encrypted.sh` | refuse tout secret qui ne serait pas chiffré par SOPS | la CI (contrôle Security) |

### Tests locaux sur kind (aucun appel à AWS)

| Script | Ce qu'il prouve |
|---|---|
| `k8s/kind/test.sh` | déploiement complet : backends répondent sur `/health`, les séries de l'agent arrivent sur un faux NAS avec les bons labels |
| `k8s/kind/test-argocd.sh` | Argo CD déploie depuis GitHub, annule une modification manuelle (selfHeal) et recrée une ressource supprimée |
| `k8s/kind/check-agent-config.sh` | la configuration du Prometheus Agent est valide (`promtool`) |

## Tester en local (aucun appel à AWS)

Prérequis : Docker, [kind](https://kind.sigs.k8s.io/), `kubectl`.

```bash
k8s/kind/check-agent-config.sh kind   # promtool sur la config de l'agent
k8s/kind/test.sh                      # déploiement complet + séries reçues par un faux NAS
k8s/kind/test-argocd.sh               # Argo CD déploie l'overlay depuis GitHub, selfHeal, recréation
k8s/kind/test.sh --cleanup && k8s/kind/test-argocd.sh --cleanup   # supprime les clusters de test
```

## Pipeline CI

[`ci.yml`](.github/workflows/ci.yml) s'exécute sur chaque pull request et sur `main` (runners GitHub). Les trois checks sont obligatoires pour fusionner.

| Étape | Contrôles |
|---|---|
| ① Code Quality | yamllint, shellcheck, rendu Kustomize + kubeconform (strict), promtool (configuration de l'agent), `terraform fmt` + `validate` |
| ② Security | Gitleaks, signatures Cosign des backends, Trivy config sur Kubernetes et Terraform (HIGH/CRITICAL bloquants) |
| ③ Tests (kind) | déploiement complet sur un cluster jetable, déploiement par Argo CD (selfHeal) |

Les mêmes scripts se lancent en local : `ci/render.sh <dossier>`, `ci/verify-signatures.sh`.

## Documentation

- [docs/notes-projet.md](docs/notes-projet.md) : décisions, alternatives écartées, difficultés rencontrées (y compris les erreurs et leurs corrections)
- [docs/gitops.md](docs/gitops.md) : Argo CD, promotion, rollback
- [docs/test-reconstruction.md](docs/test-reconstruction.md) : `destroy` puis `apply`, et ce qui est contrôlé
- [docs/changements-nas-monitoring.md](docs/changements-nas-monitoring.md) : Tailscale, récepteur Prometheus, règles, démonstration d'alerte
- [terraform/README.md](terraform/README.md), [secrets/README.md](secrets/README.md)
