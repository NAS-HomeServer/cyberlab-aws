# Cyberlab AWS

Migration du cyberlab (3 backends `sherlock`, `dns-analyzer`, `audit-orchestrator` et leurs 3 tunnels `cloudflared`) du NAS Synology vers AWS : instance EC2 avec K3s, déployée en GitOps avec ArgoCD, supervisée par le Prometheus du NAS grâce à un Prometheus Agent (`remote_write`).

Le NAS reste la production tant que la bascule n'est pas décidée : son dépôt, [cyberlab-infra](https://github.com/NAS-HomeServer/cyberlab-infra), n'est pas modifié. La supervision (Prometheus, Grafana, Alertmanager) reste dans [HomeServer-monitoring](https://github.com/NAS-HomeServer/HomeServer-monitoring).

> État : étape 3 sur 7 (manifestes Kubernetes validés par la CI, infrastructure AWS décrite en Terraform). Le bootstrap de l'instance (cloud-init : K3s, ArgoCD), SOPS, ArgoCD et la liaison avec le NAS arrivent par petites PR, une par étape. Les décisions et difficultés sont consignées dans [docs/notes-projet.md](docs/notes-projet.md).

## Contenu

```
k8s/
├── cyberlab/{base,overlays/{kind,staging,production}}   # 3 backends + 3 tunnels cloudflared
├── monitoring/{base,overlays/{kind,aws}}                # Prometheus Agent, node-exporter, kube-state-metrics
└── kind/                                                # faux NAS et scripts de test local
terraform/{bootstrap,main}                               # bucket d'état (à part) puis VPC, EC2, IAM, IP élastique, budget (voir terraform/README.md)
scripts/instance.sh                                      # arrêter / démarrer l'instance sans la détruire
ci/                                                      # scripts de la CI (rendu, signatures Cosign, scan des images)
.github/workflows/ci.yml                                 # pipeline : Code Quality, Security, Tests (kind)
docs/notes-projet.md                                     # décisions, alternatives écartées, difficultés
```

Les trois backends ne gardent aucune donnée durable (jobs en mémoire, fichiers temporaires dans `/tmp`) : aucun volume n'est nécessaire.

## Tester en local (aucun appel à AWS)

Prérequis : Docker, [kind](https://kind.sigs.k8s.io/), `kubectl`.

```bash
k8s/kind/check-agent-config.sh kind   # promtool sur la config de l'agent
k8s/kind/test.sh                      # déploiement complet + séries reçues par un faux NAS
k8s/kind/test-resilience.sh           # coupe puis rétablit la liaison remote_write
k8s/kind/test.sh --cleanup            # supprime le cluster de test
```

## Pipeline CI

[`ci.yml`](.github/workflows/ci.yml) s'exécute sur chaque pull request et sur `main` (runners GitHub, chemins `k8s/`, `ci/`).

| Étape | Contrôles |
|---|---|
| ① Code Quality | yamllint, shellcheck, rendu Kustomize + kubeconform (strict), promtool sur la config de l'agent, `terraform fmt` + `validate` |
| ② Security | Gitleaks, signatures Cosign des backends, Trivy config sur Kubernetes et Terraform (HIGH/CRITICAL bloquants), scan Trivy des images (informatif) |
| ③ Tests (kind) | déploiement complet sur un cluster jetable + test de résilience du `remote_write` |

Les mêmes scripts se lancent en local : `ci/render.sh <dossier>`, `ci/verify-signatures.sh`, `ci/scan-images.sh <dossier>`.
