# Cyberlab AWS

Migration du cyberlab (3 backends `sherlock`, `dns-analyzer`, `audit-orchestrator` et leurs 3 tunnels `cloudflared`, par environnement) d'un NAS Synology vers AWS : **Terraform** crée une instance EC2, **cloud-init** y installe K3s et Argo CD, puis **Argo CD** déploie tout depuis ce dépôt (GitOps). Deux environnements (`staging`, `production`) avec promotion par pull request et rollback par `git revert`. La supervision reste sur le NAS : un **Prometheus Agent** envoie ses métriques au Prometheus du NAS par Tailscale.

> **Test de reconstruction** : `terraform destroy` puis `terraform apply` rétablissent l'ensemble sans aucune intervention manuelle, vérifié par un script. Voir [docs/test-reconstruction.md](docs/test-reconstruction.md).

Le NAS reste la production tant que la bascule n'est pas décidée : son dépôt, [cyberlab-infra](https://github.com/NAS-HomeServer/cyberlab-infra), n'est pas modifié. La supervision (Prometheus, Grafana, Alertmanager) reste dans [HomeServer-monitoring](https://github.com/NAS-HomeServer/HomeServer-monitoring).

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
   L'instance s'installe seule (5 à 8 minutes) : K3s, Argo CD, secrets, Tailscale, puis le déploiement par Git.
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
