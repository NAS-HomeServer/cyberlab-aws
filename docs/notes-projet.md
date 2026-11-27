# Notes de projet : migration du cyberlab vers AWS

> **À retenir** : un seul cluster K3s et deux namespaces, par choix de coût. Chaque choix est justifié ci-dessous.

## Contexte

| Sujet | Détail |
|---|---|
| Point de départ | 3 backends (`sherlock`, `dns-analyzer`, `audit-orchestrator`) sur un NAS Synology, chacun derrière un tunnel `cloudflared` |
| Objectif | le même service sur AWS (Terraform, K3s, Argo CD), en staging et production, supervisé par le Prometheus du NAS |
| Périmètre | ce dépôt seul ; `cyberlab-infra` et `HomeServer-monitoring` ne sont pas modifiés. Le NAS reste la production |

## Les backends

| | sherlock | dns-analyzer | audit-orchestrator |
|---|---|---|---|
| Données durables | aucune | aucune | aucune |
| État en mémoire | pas de job | jobs (1 h), fichier dans `/tmp` | jobs (1 h) |
| Tests unitaires en CI | non | non | non |
| `/metrics` / `/health` | non / oui | non / oui | non / oui |

Conséquences : ni volume EBS ni bucket S3. Sans `/metrics`, la santé vient de kube-state-metrics et cAdvisor.

## Choix d'architecture

| Choix | Pourquoi | Écarté ou limite |
|---|---|---|
| K3s | léger, tient sur une instance | EKS : plan de contrôle facturé environ 73 $/mois |
| Une instance, deux namespaces | coût ; la démonstration n'exige pas plus | un cluster par environnement ; point de défaillance partagé |
| `t3.medium` (x86) | images en amd64 ; `t3.small` trop juste en mémoire | `t4g` (ARM) |
| Ubuntu 24.04, `ignore_changes = [ami]` | une nouvelle image ne remplace pas l'instance | mise à jour volontaire |
| Région `eu-west-3` | Paris | modifiable |
| Disque gp3 chiffré, jetable | aucune donnée à garder | |
| cloud-init et un script | Terraform seul reconstruit tout | Ansible : non exigé (utilisé sur le NAS) ; script exécuté au premier démarrage seulement |
| State Terraform local | un seul opérateur ; survit au `destroy` | S3 avec verrou (en équipe) ; perdu avec le poste ; jamais commité |
| Kustomize, sans Helm ni Operator | manifestes lisibles | |
| `cyberlab` et `monitoring` séparés | un `cyberlab` par environnement, un monitoring par cluster | l'overlay `kind` sert au test local |
| Images épinglées par digest | on sait ce qui tourne | mises à jour à la main, par PR |

## Réseau et sécurité

| Choix | Détail |
|---|---|
| Aucune entrée publique | trafic par les tunnels sortants ; SSH limité à `ssh_allowed_cidrs` (jamais `0.0.0.0/0`), sinon Systems Manager |
| Sorties ouvertes | les backends interrogent des cibles libres, `cloudflared` exige 7844 ; contrôle par NetworkPolicies. **À arbitrer avec le jury** |
| Sous-réseau public, sans NAT Gateway | économie d'environ 35 $/mois |
| IP élastique | stable entre arrêt et démarrage, libérée au `destroy` |
| IAM minimal | `AmazonSSMManagedInstanceCore` et lecture de 3 paramètres SSM |
| IMDSv2, hop limit 1 | un pod ne peut pas voler les identifiants de l'instance (SSRF) |
| Budget | 15 $/mois, alertes à 80 % (réel) et 100 % (prévu) |
| Pods durcis | non root, lecture seule, `capabilities` retirées, seccomp, pas de jeton d'API, ingress refusé, Pod Security `restricted` |
| Un token par tunnel et par environnement | moindre privilège ; ceux du NAS répartiraient le trafic réel |
| `node-exporter` | exige `hostNetwork` et `hostPath` : namespace `monitoring` en `privileged`, exceptions Checkov sur la ressource |

## Secrets

Mode d'emploi : [secrets.md](secrets.md).

| Choix | Détail |
|---|---|
| SOPS + age | seules les valeurs sont chiffrées : les diffs restent lisibles |
| Un fichier par Secret | `secrets/<env>/`, modèles dans `secrets/templates/` |
| Clé privée dans SSM (SecureString) | lue au démarrage puis supprimée ; absente du dépôt, de `user_data` et du state ; pas de droit KMS à ajouter |
| Déchiffrement par `scripts/secrets.sh` | écarté : KSOPS (plugin à maintenir). Modifier un secret demande de relancer le script |
| Garde-fous CI | refus d'un secret non chiffré, Gitleaks |
| Limite | Secrets non chiffrés dans la base de K3s (disque EBS chiffré) |

## CI

| Étape | Contrôles (tous bloquants) |
|---|---|
| ① Code Quality | yamllint, shellcheck, Kustomize + kubeconform, promtool, `terraform fmt` et `validate` |
| ② Security | secrets chiffrés, Gitleaks, signatures Cosign, Checkov |
| ③ Tests (kind) | déploiement complet sur un cluster jetable |

| Choix | Détail |
|---|---|
| Valider le rendu Kustomize | c'est ce que le cluster reçoit |
| Runners GitHub | dépôt public : un runner du NAS exécuterait le code des forks |
| Outils épinglés | conteneurs par digest, actions par SHA |
| Checkov plutôt que Trivy | précaution après l'attaque de mars 2026 sur Trivy (CVE-2026-33634) |
| Exceptions Checkov | pas de filtre par sévérité : tout écart bloque, sauf exception écrite (VPC Flow Logs, par exemple : coût) |
| Pas de job « Deploy » | Argo CD déploie |
| Pas de protection de `main` | opérateur seul : PR et trois checks verts, par discipline |
| Limite | pas de scan d'images ici ; il est fait dans la CI de chaque backend, encore avec Trivy |

## Démarrage de l'instance

`scripts/bootstrap-node.sh` s'exécute une fois : paquets, SOPS, K3s, Argo CD, secrets, Tailscale, applications Argo CD. Journal : `/var/log/cyberlab-bootstrap.log`.

| Choix | Détail |
|---|---|
| Versions et SHA-256 vérifiés | K3s, Argo CD, SOPS, Tailscale (pas AWS CLI ni les paquets `apt`) |
| Mémoire économisée | K3s sans traefik, servicelb ni metrics-server ; Argo CD sans Dex ni notifications |
| Test | impossible sur kind : seul un vrai démarrage le valide |

## GitOps

Mode d'emploi : [gitops.md](gitops.md).

| Choix | Détail |
|---|---|
| 3 applications Argo CD, sans app-of-apps | permet de tester une branche (`repo_ref`) |
| Staging et supervision automatiques | `prune` et `selfHeal` |
| Production sur « Sync » | validation humaine, y compris au premier démarrage |
| Mise en production | PR qui recopie les digests de staging |
| Rollback | `git revert` : seule trace durable |
| Une branche, deux dossiers | staging et production suivent `main` |
| Secrets hors Argo CD | jamais supprimés par `prune` |
| Limite | Argo CD n'est pas testé sur kind |

## Supervision (lien avec le NAS)

Réglages côté NAS : [changements-nas-monitoring.md](changements-nas-monitoring.md).

| Choix | Détail |
|---|---|
| Tailscale | déjà en place, ACL limitée au port 9090 du NAS. Écarté : tunnel Cloudflare + Access |
| Clé non éphémère, 90 jours | survit à l'arrêt du soir ; à renouveler avant une reconstruction |
| `--accept-dns=false` | les pods gardent le DNS du cluster |
| Démarrage tolérant | sans clé, tout fonctionne sauf la supervision |
| Un seul Prometheus Agent | labels `env` (selon le namespace) et `cluster=aws-k3s` |
| WAL en `emptyDir` (512 Mi, 4 h) | perdu à l'arrêt de l'instance : voulu |
| Alertes limitées à AWS | pas d'alerte « métriques absentes » (instance souvent éteinte) |

## Réplicas : un seul partout, deux pour `sherlock` en production

| Sujet | Détail |
|---|---|
| Règle | 1 réplica : un seul nœud de 4 Go ; mises à jour avec `maxUnavailable: 0` |
| `sherlock` : 2 en production | une requête = un scan complet, aucun job à retrouver |
| Les deux autres : 1 | jobs en mémoire : le suivi doit retomber sur le même pod |
| Limites | même nœud ; quotas comptés par pod (jusqu'au double) ; scan perdu si le pod disparaît |
| Erreur corrigée | les 2 réplicas avaient d'abord été donnés à `dns-analyzer` (suivi en 404 possible) |
| À vérifier sur AWS | 2 pods en production, mémoire (`free -m`, jusqu'à 1 Gio par pod) |

## Difficultés rencontrées

| Problème | Solution |
|---|---|
| Première PR ouverte sur `cyberlab-infra` | reprise ici ; confirmer le dépôt cible |
| PR empilées fusionnées hors de `main` | une PR d'intégration ; toutes les PR sur `main` |
| Images amd64, poste arm64 | émulation sous kind, `t3` sur AWS |
| Liste YAML coupée sur les virgules (`CrashLoopBackOff`) | liste en bloc |
| ConfigMaps non référencées | `namespace` fixé dans la base et les overlays |
| Tunnels redémarrés en boucle sur kind (faux token) | liveness retirée sur kind |
| Échantillons « out-of-order » (cAdvisor) | `honor_timestamps: false` |
| Label `env` absent de `up` | posé par `relabel_configs` |
| Regex trop longues pour yamllint | chaînes sur plusieurs lignes |
| Checksum Terraform refusé en CI | `terraform providers lock` pour linux et macOS |
| `keygen` remplaçait mal la clé publique | expression régulière corrigée |
| Labels perdus dans l'alerte mémoire | `group_left` |
| `tailscale up` bloqué (`TS_AUTHKEY` ignorée) | `--auth-key=file:...` et délai de 120 s |
| Arrêt silencieux du script (SIGPIPE) | sortie écrite dans un fichier |

## Validation et résultats

| Quoi | Résultat |
|---|---|
| En local | kubeconform, Checkov, promtool, `k8s/kind/test.sh` (backends, tunnels, métriques) |
| `sherlock` en lecture seule | un scan réel n'écrit que dans `/tmp` |
| Terraform | `fmt`, `init` sans backend, `validate` |
| Premier essai réel (17/11/2026) | un seul `apply` ; script de démarrage en **2 min 45 s** ; **11 contrôles sur 11 OK** |
| Reconstruction | procédure : [test-reconstruction.md](test-reconstruction.md) |
| Reste à démontrer | mise en production, `git revert`, alerte Discord |
