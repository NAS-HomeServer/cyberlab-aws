# Cyberlab AWS

Migration du **cyberlab** (3 backends `sherlock`, `dns-analyzer`, `audit-orchestrator`, chacun derrière un tunnel `cloudflared`) d'un NAS Synology vers **AWS**, en 2 environnements : `staging` et `production`.

## En bref

| Brique | Outil | Rôle |
|---|---|---|
| Infrastructure | **Terraform** | VPC, EC2, IAM limité, IP élastique, budget |
| Démarrage | **cloud-init** + `scripts/bootstrap-node.sh` | installe K3s, Argo CD, secrets, Tailscale au premier démarrage |
| Déploiement | **Argo CD + Kustomize** (GitOps) | Git est la source de vérité ; staging automatique, production après un clic « Sync » |
| Secrets | **SOPS + age** | secrets chiffrés dans Git, clé privée dans AWS SSM |
| Qualité / sécurité | **GitHub Actions** | lint, Gitleaks, Cosign, Checkov, test sur kind |
| Supervision | **Prometheus Agent** | envoie les métriques au Prometheus du NAS par Tailscale |

Mise en production : pull request (digest d'image) puis « Sync » ; retour arrière : `git revert`. Une instance neuve est prête en moins de 3 minutes (hors création AWS), et `terraform destroy` puis `apply` reconstruit tout sans intervention, la production attendant ensuite son clic « Sync » ([test de reconstruction](docs/test-reconstruction.md)).

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

| Élément | Installé par | Quand |
|---|---|---|
| EC2, réseau, IAM, budget | **Terraform** (`terraform/main`) | `terraform apply`, à la main |
| K3s, Argo CD, secrets, Tailscale | **`scripts/bootstrap-node.sh`** (cloud-init) | une seule fois, au premier démarrage |
| Backends, tunnels, supervision | **Argo CD**, depuis `k8s/` | à chaque fusion sur `main` (production : après « Sync ») |

Terraform ne parle jamais à Kubernetes. La CI ne lance ni `plan` ni `apply` : elle valide et teste ; le « CD » est assuré par Argo CD, qui tire depuis Git. Les justifications des choix (K3s plutôt qu'EKS, un seul cluster, state local, etc.) sont dans [docs/notes-projet.md](docs/notes-projet.md).

## Secrets et images

- Le dépôt est **public** : les secrets y sont **chiffrés** (SOPS + age), la clé privée vit dans AWS SSM et est effacée du disque après usage. La CI refuse tout fichier non chiffré. → [docs/secrets.md](docs/secrets.md)
- Les 3 images viennent de `ghcr.io/ag69075/…`, référencées **par digest** dans `k8s/cyberlab/overlays/{staging,production}/kustomization.yaml`. La CI vérifie leur signature **Cosign**. Nouvelle version : digest dans staging (PR), puis dans production (PR). → [docs/gitops.md](docs/gitops.md)

## Installation

> Valeurs propres à l'auteur (dépôt, images `ag69075`, adresse Tailscale du NAS, tunnels Cloudflare) : à adapter pour rejouer le projet.

Prérequis : Terraform ≥ 1.10, AWS CLI, [age](https://github.com/FiloSottile/age), [SOPS](https://github.com/getsops/sops) ; pour le test local, Docker + [kind](https://kind.sigs.k8s.io/) + `kubectl`.

1. **Secrets** (une fois) : `scripts/secrets.sh keygen`, `init`, `set` → [docs/secrets.md](docs/secrets.md)
2. **Paramètres SSM** (une fois) : clé age, clé Tailscale et, facultatif, client OAuth Tailscale → [docs/terraform.md](docs/terraform.md)
3. **Infrastructure** :
   ```bash
   cd terraform/main
   cp terraform.tfvars.example terraform.tfvars
   terraform init && terraform plan
   terraform apply        # ⚠ crée des ressources facturées
   ```
4. **Vérifier** : `sudo kubectl -n argocd get applications` sur l'instance → `cyberlab-staging` et `monitoring` `Synced`/`Healthy` ; `cyberlab-production` reste `OutOfSync` jusqu'au clic « Sync ».
5. **Fin de démo** : `terraform -chdir=terraform/main destroy` (plus rien n'est facturé ; `t3.medium` ≈ 5 ct/h, budget avec alertes e-mail).

## Exploiter

| Besoin | Où |
|---|---|
| Mettre en production, rollback, démo Argo CD | [docs/gitops.md](docs/gitops.md) |
| Reconstruire de zéro | [docs/test-reconstruction.md](docs/test-reconstruction.md) |
| Tester en local sans AWS | `k8s/kind/test.sh` (puis `--cleanup`) |

## Structure

```
terraform/main/     VPC, EC2, IAM, IP élastique, budget
k8s/                cyberlab/{base,overlays/{kind,staging,production}} · monitoring/ · argocd/applications/ · kind/ (tests locaux)
secrets/            secrets chiffrés (SOPS + age) par environnement
scripts/            bootstrap-node.sh (cloud-init) · secrets.sh
ci/                 scripts de la CI (rendu, Cosign, secrets chiffrés)
.github/workflows/  ci.yml
docs/               documentation
nas-monitoring/     (annexe) règles d'alerte à copier sur le Prometheus du NAS
```

## Pipeline CI

[`ci.yml`](.github/workflows/ci.yml) tourne sur chaque pull request et sur `main`. Trois checks, que l'opérateur (seul sur ce dépôt) attend verts avant de fusionner :

| Étape | Contrôles |
|---|---|
| ① Code Quality | yamllint, shellcheck, Kustomize + kubeconform, promtool, `terraform fmt` + `validate` |
| ② Security | Gitleaks, Cosign, Checkov (Kubernetes et Terraform, tout écart non justifié est bloquant) |
| ③ Tests (kind) | déploiement complet sur un cluster jetable |

## Documentation

- [docs/terraform.md](docs/terraform.md) : ressources, state, pas à pas
- [docs/kubernetes.md](docs/kubernetes.md) : manifestes, overlays, NetworkPolicies
- [docs/gitops.md](docs/gitops.md) : Argo CD, mise en production, rollback
- [docs/secrets.md](docs/secrets.md) : SOPS + age
- [docs/test-reconstruction.md](docs/test-reconstruction.md) : `destroy` puis `apply`
- [docs/notes-projet.md](docs/notes-projet.md) : décisions et difficultés
- Annexe, côté NAS : [docs/changements-nas-monitoring.md](docs/changements-nas-monitoring.md) (Tailscale, récepteur Prometheus, règles d'alerte)
