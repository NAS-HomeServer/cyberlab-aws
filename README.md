# Cyberlab AWS

Migration du cyberlab (3 backends `sherlock`, `dns-analyzer`, `audit-orchestrator` et leurs 3 tunnels `cloudflared`) du NAS Synology vers AWS : instance EC2 avec K3s, déployée en GitOps avec ArgoCD, supervisée par le Prometheus du NAS grâce à un Prometheus Agent (`remote_write`).

Le NAS reste la production tant que la bascule n'est pas décidée : son dépôt, [cyberlab-infra](https://github.com/NAS-HomeServer/cyberlab-infra), n'est pas modifié. La supervision (Prometheus, Grafana, Alertmanager) reste dans [HomeServer-monitoring](https://github.com/NAS-HomeServer/HomeServer-monitoring).

> État : étape 1 sur 7 (manifestes Kubernetes, testés sur kind). Terraform, Ansible, SOPS, ArgoCD et la liaison avec le NAS arrivent par petites PR, une par étape. Les décisions et difficultés sont consignées dans [docs/notes-projet.md](docs/notes-projet.md).

## Contenu

```
k8s/
├── cyberlab/{base,overlays/{kind,staging,production}}   # 3 backends + 3 tunnels cloudflared
├── monitoring/{base,overlays/{kind,aws}}                # Prometheus Agent, node-exporter, kube-state-metrics
└── kind/                                                # faux NAS et scripts de test local
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
