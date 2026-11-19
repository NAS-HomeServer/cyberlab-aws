# Notes de projet — migration du cyberlab vers AWS

Décisions, alternatives écartées et difficultés rencontrées, par étape.

## Contexte et périmètre

- **Dépôt dédié** : tout le travail AWS vit dans `NAS-HomeServer/cyberlab-aws`.
  `cyberlab-infra` (production sur le NAS : compose, Ansible, pipeline) et `HomeServer-monitoring`
  ne sont pas modifiés. *Erreur de parcours* : la première PR a d'abord été ouverte par erreur sur
  `cyberlab-infra`, puis reprise ici. Leçon : confirmer le dépôt cible avant la première écriture.
- **Point de départ** : 3 backends (`sherlock`, `dns-analyzer`, `audit-orchestrator`), chacun derrière
  un tunnel `cloudflared`, sur un NAS Synology. Images publiques sur GHCR, épinglées par digest,
  signées Cosign.
- **Objectif** : le même service sur AWS (Terraform → EC2 K3s par cloud-init → Argo CD → manifestes
  Kubernetes), deux environnements, supervision par le Prometheus du NAS via un Prometheus Agent.
  Le NAS reste la production tant que la bascule n'est pas décidée.

## Étape 1 — Manifestes Kubernetes (Kustomize), testés sur kind

### Constats sur les backends

| | sherlock | dns-analyzer | audit-orchestrator |
|---|---|---|---|
| Données durables | aucune | aucune (fichier temporaire dans `/tmp`) | aucune (jobs en mémoire, purgés après 1 h) |
| Tests unitaires en CI | non | non | non |
| `/metrics` Prometheus | non | non | non |
| `/health` | oui | oui | oui |

Conséquences :
- **Pas de volume EBS ni de bucket S3 pour les données** : les backends sont sans état durable. C'est
  une décision argumentée, pas un oubli. Le seul stockage durable du projet est l'état Terraform
  (fichier local sur le poste).
- **Un seul réplica par backend**, sauf `dns-analyzer` en production (voir « Réplicas ») :
  `audit-orchestrator` garde ses jobs dans la mémoire du process, le suivi d'un job doit retomber
  sur le même pod.
- **Pas de `/metrics` côté backends** (les modifier toucherait 3 dépôts). Leur santé vient de
  kube-state-metrics (réplicas disponibles, redémarrages) et cAdvisor (CPU, mémoire). Les tunnels
  exposent `/metrics` grâce à `--metrics`.

### Décisions

- **Un seul EC2, un seul cluster K3s, deux namespaces** (`cyberlab-staging`, `cyberlab-production`)
  plutôt que deux instances : coût minimal, et ce qu'on démontre (Terraform, K8s, GitOps, mise en production par étapes)
  ne dépend pas du nombre de machines. Limite assumée : staging et production partagent le même point
  de défaillance. *Alternative écartée* : un cluster par environnement (plus propre, deux fois plus cher).
- **Un seul Prometheus Agent** (namespace `monitoring`) : deux agents sur le même nœud dupliqueraient
  les métriques de l'hôte. Le label `env` est déduit du namespace par relabeling
  (`cyberlab-staging` → `env=staging`) et vaut `shared` pour l'hôte et le cluster ;
  `cluster=aws-k3s` est un `external_label`.
- **Structure** : `k8s/cyberlab/{base,overlays}` et `k8s/monitoring/{base,overlays}`, deux ensembles
  indépendants (le monitoring est unique par cluster, `cyberlab` existe une fois par environnement).
  L'overlay `kind` sert au test local (secrets factices, faux NAS), `staging` et `production` à AWS.
- **Config de l'agent en deux fichiers** : `scrape.yml` (quoi collecter, commun) et `prometheus.yml`
  (où envoyer, quels labels : un par overlay), reliés par `scrape_config_files`.
- **Images épinglées par digest** : backends via `images:`/`digest:` dans les overlays (pour recopier les mêmes digests
  de staging vers production), les autres directement dans les manifestes, suivies par Renovate.
- **Durcissement repris du compose** : `readOnlyRootFilesystem`, `capabilities.drop: [ALL]`,
  `allowPrivilegeEscalation: false`, `emptyDir` en mémoire pour `/tmp`, limites mémoire, probes
  (startup, readiness, liveness). Ajouts : `runAsNonRoot`, seccomp `RuntimeDefault`, jeton de
  ServiceAccount non monté, NetworkPolicies (ingress refusé par défaut), namespaces en Pod Security
  `restricted`.
- **Secrets séparés** : dans le compose, chaque tunnel reçoit tout le `.env` de son backend. Ici il ne
  reçoit que son `TUNNEL_TOKEN` (moindre privilège).
- **Tunnels : un jeu par environnement, nouveaux tokens.** Réutiliser ceux du NAS répartirait le trafic
  réel entre le NAS et AWS.
- **node-exporter** : seul composant qui exige `hostNetwork` + `hostPath`. Le namespace `monitoring`
  est donc en Pod Security `privileged`, et deux règles Trivy sont ignorées avec justification
  (`.trivyignore`). *Alternative écartée* : ne pas superviser l'hôte.
- **Pas de Helm ni d'Operator** : manifestes simples, lisibles en soutenance.
- **WAL de l'agent** : `emptyDir` plafonné (512 Mi), rétention 4 h. Il survit à un redémarrage du
  conteneur, pas à l'arrêt de l'instance (un `stop` du soir coupe aussi les métriques : voulu).

### Difficultés rencontrées

- **Images backends en amd64 seulement, poste en arm64** : elles tournent sous kind grâce à
  l'émulation de Docker Desktop. Sur AWS : instances x86 (`t3`), pas `t4g`.
- **Liste YAML en ligne qui découpe sur la virgule** : `args: [--resources=a,b, --port=8080]` était lue
  comme trois arguments (CrashLoopBackOff de kube-state-metrics). Résolution : liste en bloc.
- **`namespace` non réécrit par Kustomize** : les ConfigMaps générées n'étaient pas référencées par le
  Deployment tant que le `namespace` n'était pas fixé dans la base et les overlays.
- **Tunnels avec un faux token** (kind) : la liveness (`/ready`) les redémarrait en boucle ; elle est
  retirée par un patch sur kind uniquement.
- **Échantillons « out-of-order » de cAdvisor** : `honor_timestamps: false` sur ce job.
- **`up` n'est pas touché par `metric_relabel_configs`** : pour qu'il porte `env`, le label est posé
  dans `relabel_configs` (cibles).

### Validation (en local, sans AWS)

`kubeconform -strict` sur 5 overlays ; `trivy config` sans finding HIGH/CRITICAL (hors les 2 règles
node-exporter justifiées) ; `promtool check config` sur l'agent ; `k8s/kind/test.sh` : backends
joignables sur `/health`, tunnels exposant `/metrics`, séries de l'agent reçues par un faux NAS avec
les bons labels. Un scan Sherlock réel sous `readOnlyRootFilesystem` a confirmé qu'il n'écrit rien
en dehors de `/tmp`.

## Étape 2 — CI de validation

### Ce que fait la CI (`.github/workflows/ci.yml`)

| Étape | Contrôles | Bloquant |
|---|---|---|
| ① Code Quality | yamllint, shellcheck, rendu Kustomize + kubeconform, promtool, `terraform fmt` + `validate` | oui |
| ② Security | secrets chiffrés (SOPS), Gitleaks, signatures Cosign des images, Trivy config (Kubernetes et Terraform, HIGH/CRITICAL) | oui |
| ③ Tests (kind) | déploiement complet sur un cluster jetable | oui |

On valide ce que le cluster va réellement recevoir (la sortie de `kubectl kustomize`), pas les fichiers
sources : les `images:`/`digest:` des overlays n'existent que dans le rendu.

### Décisions

- **Runners hébergés par GitHub, pas le runner du NAS** : le dépôt est public, un runner auto-hébergé
  y exécuterait le code des PR de forks. kind y est disponible et la CI ne dépend plus du NAS.
- **Outils en conteneurs épinglés par digest** ; actions GitHub épinglées par SHA de commit.
- **Cosign dans la CI** : une image non signée par la CI de son dépôt n'atteint jamais Argo CD.
- **Pas de job « Deploy »** : le déploiement est fait par Argo CD (GitOps), pas par la CI.
- **Protection de `main`** : PR obligatoire, pas de force-push, les trois checks obligatoires. Sans
  filtre de chemins, une PR qui ne touche que la documentation obtient aussi ses checks (quelques
  minutes de CI en plus).
- **Limite connue : la CI de ce dépôt ne scanne pas les images** (seulement les configurations). Un
  scan bloquant des images existantes aurait remonté des vulnérabilités HIGH/CRITICAL dès le premier
  jour ; la CI de chaque backend scanne déjà son image. Risque connu et suivi : mises à jour par Renovate,
  reconstruction des backends.

### Difficultés rencontrées

- **yamllint et regex longues** : les listes `keep` dépassaient 200 caractères ; chaînes entre
  guillemets avec continuation de ligne.
- **Plusieurs PR empilées** (#2 sur #1, #3 sur #2) fusionnées dans leurs branches de base au lieu de
  `main` : une PR d'intégration a été nécessaire. Leçon : une PR par branche, toutes sur `main`.

## Étape 3 — Terraform (infrastructure AWS)

### Décisions

- **État Terraform local** (`terraform.tfstate`, ignoré par git) plutôt qu'un bucket S3 : un seul
  opérateur, et l'énoncé n'exige pas d'état distant. Le fichier survit à `terraform destroy`, donc le
  cycle « destroy puis apply » fonctionne. *Limites assumées* : pas de partage ni de verrou entre
  opérateurs, état perdu avec le poste. *Évolution en équipe* : backend S3 avec `use_lockfile`
  (Terraform ≥ 1.10), le bucket étant créé hors du module détruit. Le fichier peut contenir des données
  sensibles : jamais commité.
- **Région `eu-west-3` (Paris)**, modifiable par variable.
- **Instance `t3.medium`** (x86 : images en amd64). La `t3.small` ne tient pas en mémoire (K3s, Argo CD
  et 12 pods : OOMKilled), voir étape 5.
- **Ubuntu 24.04 LTS** via le paramètre SSM public de Canonical ; `ignore_changes = [ami]` pour qu'une
  nouvelle AMI ne remplace pas l'instance au prochain `plan`.
- **Réseau** : 1 VPC, 1 sous-réseau public, pas de NAT Gateway (≈ 35 $/mois).
- **Aucune entrée publique** : SSH limité à `ssh_allowed_cidrs` (jamais `0.0.0.0/0`, validation
  Terraform) ; liste vide = accès par Systems Manager uniquement. Le rôle IAM n'a que
  `AmazonSSMManagedInstanceCore` et la lecture de deux paramètres SSM.
- **Sorties ouvertes** : sherlock sonde des centaines de sites, dns-analyzer interroge des serveurs DNS
  et des ports choisis par l'utilisateur, cloudflared exige 7844 (tcp/udp). Compromis : entrée fermée,
  sorties libres, contrôle fin par NetworkPolicies. L'exception Trivy est écrite à côté de la règle
  (`#trivy:ignore`). À arbitrer avec le jury si la question est posée.
- **IMDSv2 obligatoire, hop limit 1** : un pod ne peut pas lire les métadonnées de l'instance. Les
  backends effectuent des requêtes vers des cibles choisies par l'utilisateur (risque SSRF) : c'est la
  parade côté infrastructure.
- **IP élastique dans le module principal** : stable aux arrêts/démarrages, libérée par un `destroy`.
  Avec Tailscale, le lien avec le NAS ne dépend pas de l'IP publique.
- **Budget** : alerte à 80 % du réel et 100 % du prévu, 15 $/mois par défaut ; e-mail en variable.
- **Aucun volume de données** : disque racine gp3 chiffré ; l'instance est jetable.

### Validation (aucun appel à AWS)

`terraform fmt -check`, `init -backend=false` avec lockfile en lecture seule et `validate` (en local et
dans la CI) ; Trivy config sans finding HIGH/CRITICAL. Finding connu et non traité : VPC Flow Logs
(MEDIUM, coût et volume disproportionnés ici).

### Difficulté rencontrée

**Lockfile et architectures** : un `init` sur Mac Apple Silicon ne verrouille que `darwin_arm64` ; la CI
(linux amd64) échouait sur le checksum. Résolution : `terraform providers lock` pour `linux_amd64`,
`linux_arm64` et `darwin_arm64`.

## Décision — pas d'Ansible côté AWS

Le script de démarrage de l'instance est exécuté par `cloud-init` (script passé en `user_data`) plutôt que par Ansible.
Terraform seul reconstruit alors tout : `terraform apply`, puis Argo CD synchronise les applications.

- **Pourquoi c'est possible** : les compétences visées demandent d'automatiser le déploiement
  d'une infrastructure (Terraform) et d'orchestrer des conteneurs (Kubernetes) ; aucune n'exige Ansible.
  Il reste utilisé en production sur le NAS (`cyberlab-infra`).
- **Limites acceptées** : cloud-init ne s'exécute qu'au premier démarrage (modifier le script revient à
  recréer l'instance, ce que `terraform plan` montre) ; le diagnostic passe par
  `/var/log/cyberlab-bootstrap.log` et `/var/log/cloud-init-output.log`.

## Étape 4 — Secrets chiffrés (SOPS + age)

Explication complète et mode d'emploi : [secrets/README.md](../secrets/README.md).

### Décisions

- **SOPS + age, clé privée gardée par l'utilisateur.** La clé publique est dans `.sops.yaml`
  (versionnable). Seules les *valeurs* des Secrets Kubernetes sont chiffrées (`encrypted_regex`) : les
  diffs de PR restent lisibles.
- **Déchiffrement par un script, pas par Argo CD.** `scripts/secrets.sh apply <env>` fait
  `sops --decrypt | kubectl apply`, exécuté au démarrage de l'instance. *Alternative écartée* : KSOPS
  dans Argo CD (vrai GitOps pour les secrets, mais image `repo-server` modifiée et plugin à maintenir).
  *Contrepartie* : modifier un secret demande de relancer le script plutôt qu'un simple `git push`.
- **Un fichier par Secret** (`secrets/<env>/<nom>.sops.yaml`), modèles dans `secrets/templates/`.
- **Garde-fou CI** (`ci/check-secrets-encrypted.sh`) : refuse tout fichier de `secrets/<env>/` sans bloc
  `sops:` ou avec une valeur non chiffrée, en plus de Gitleaks.
- **La clé arrive au cluster** par AWS Systems Manager Parameter Store (SecureString, hors Terraform),
  lue au démarrage via le rôle IAM de l'instance : jamais dans le dépôt, `user_data` ni l'état Terraform.

### Difficultés rencontrées

- `keygen` remplaçait mal la clé publique dans `.sops.yaml` (le marqueur contenait des majuscules et des
  tirets bas, l'expression régulière attendait de l'age réel). Corrigé.
- Le script accepte `KUBE_CONTEXT` pour viser kind sans toucher au contexte courant.

## Étape 5 — Script de démarrage de l'instance (cloud-init)

### Ce que fait `scripts/bootstrap-node.sh` (une fois, au premier démarrage)

Paquets et AWS CLI, SOPS, K3s, Argo CD, clonage du dépôt, lecture de la clé age dans SSM,
`secrets.sh check` puis `apply` pour staging et production, suppression de la clé du disque, Tailscale,
puis création des 3 `Application` Argo CD. Le script passe dans shellcheck en CI.

### Choix

- **Un script plutôt qu'Ansible** : une exécution au premier démarrage suffit puisque l'instance est
  jetable. Le script est un fichier du dépôt (relisible), Terraform ne fait que le transmettre.
- **Tout est épinglé et vérifié** : K3s, Argo CD, SOPS, Tailscale en version fixée **et** SHA-256
  contrôlé. Une release modifiée après coup fait échouer le script de démarrage au lieu de s'exécuter.
- **La clé age n'a pas besoin d'un droit KMS** : le SecureString est chiffré par la clé gérée `aws/ssm`,
  dont la politique autorise déjà le déchiffrement via SSM.
- **Les pods ne peuvent pas lire cette clé** : IMDSv2 avec hop limit 1.
- **Mémoire** : K3s sans traefik, servicelb ni metrics-server ; Argo CD sans Dex ni notifications.
  Argo CD seul laissait ~750 Mo sur une `t3.small` : d'où la `t3.medium`.
- **Secrets Kubernetes non chiffrés dans la base de K3s** (disque EBS chiffré) : acceptable ici ; le
  chiffrement au repos d'etcd serait une amélioration.

Le script de démarrage n'est **pas** testable sur kind (il installe K3s sur une vraie VM) : le premier démarrage
réel est le test.

## Étape 6 — GitOps : Argo CD, mise en production, rollback

Mode d'emploi : [gitops.md](gitops.md).

- **Trois `Application` Argo CD** (staging, production, supervision). Staging et supervision se
  synchronisent automatiquement (`prune`, `selfHeal`) ; **la production se déploie sur validation humaine**
  (clic sur « Sync » après la fusion de la PR), le script de démarrage ne déclenchant que son premier déploiement.
  Les applications sont créées par le script de démarrage avec l'URL et la branche de Terraform (`repo_url`, `repo_ref`).
- **Mise en production** : les digests de staging sont recopiés à la main vers production par une PR, relue et
  soumise aux 3 checks (dont la signature Cosign). La production ne reçoit jamais directement une image.
  La mise à jour du digest de staging se fait aussi par une PR manuelle.
- **Rollback** : `git revert` de la fusion fautive ; Argo CD réapplique l'ancien digest (production : après « Sync »). Seul le revert
  laisse une trace durable.
- **Pas d'app-of-apps** : trois `Application` suffisent et permettent de tester une branche
  (`repo_ref`) sans modifier les fichiers.
- **Une branche, deux dossiers** : staging et production suivent `main` mais des dossiers différents.
- **Secrets hors Argo CD** : appliqués par le script de démarrage, donc jamais élagués par `prune`.
- **Argo CD, la bascule staging → production et le `git revert` ne sont pas testés sur kind** : la
  démonstration `apply` puis `destroy` sur AWS prouve qu'Argo CD déploie tout, et ces opérations se
  montrent en démonstration sur AWS. Les tests kind couvrent les manifestes, pas Argo CD.

## Étape 7 — Lien avec le NAS (Tailscale, remote_write, alertes)

- **Transport : Tailscale**, déjà en place sur le NAS. L'instance l'installe au démarrage, avec une clé
  d'authentification lue dans SSM (`/cyberlab-aws/tailscale-authkey`, même mécanisme que la clé age) ;
  l'agent écrit sur `http://100.104.202.81:9090/api/v1/write`.
- **Règles d'alerte** pour le Prometheus du NAS : `nas-monitoring/cyberlab-aws.rules.yml`. Guide des
  changements côté NAS : [changements-nas-monitoring.md](changements-nas-monitoring.md).

### Choix

- **Tailscale plutôt que tunnel cloudflared + Access** : déjà là, aucun port ouvert, accès limité par ACL
  au seul port 9090 du NAS. Le tunnel aurait exigé d'envoyer deux en-têtes secrets avec chaque écriture
  (que Prometheus ne lit pas dans un fichier) et exposé un point d'écriture sur Internet.
- **Clé Tailscale non éphémère** : une machine éphémère serait retirée du tailnet pendant l'arrêt du
  soir et ne pourrait pas se reconnecter. Contrepartie : les anciennes instances restent listées après
  un destroy.
- **Pas de DNS Tailscale** (`--accept-dns=false`) : les pods gardent le DNS du cluster.
- **Script de démarrage tolérant** : sans paramètre SSM, l'instance démarre quand même (avertissement dans le
  journal), seule la supervision ne remonte pas.
- **Alertes bornées à `cluster="aws-k3s"`** et jobs `aws-*` : aucune interaction avec les règles du NAS.
  Pas d'alerte « métriques absentes » : l'instance n'est allumée que pour les démonstrations.
- **Clé Tailscale limitée à 90 jours** : à renouveler avant une reconstruction après ce délai.

### Difficultés rencontrées

- **Règle mémoire** : la jointure `on(...)` supprimait les labels `env` et `cluster` (le résumé de
  l'alerte aurait affiché un environnement vide). Corrigé avec `group_left`.
- **`tailscale up` ignore la variable `TS_AUTHKEY`** (supposé sans vérifier) : sans clé, il attend
  indéfiniment une connexion interactive et le script de démarrage restait bloqué. Corrigé : clé passée par
  `--auth-key=file:...`, délai de 120 s et avertissement, pour qu'un échec Tailscale ne bloque jamais
  K3s, Argo CD ni les applications.
- **SIGPIPE** : `tailscale status | head -5` avec `set -o pipefail` donnait un code 141 et `set -e`
  arrêtait le script sans message. Corrigé en écrivant la sortie dans un fichier. Un premier diagnostic
  correct avait été écarté à tort par une reproduction locale trop simple. Leçon : un script de
  démarrage ne se valide que par un vrai démarrage.
- **Non testé de bout en bout** : le déclenchement de l'alerte sur Discord et la suspension/rétablissement
  de la synchronisation Argo CD pour la démonstration d'alerte se vérifient avec le NAS et AWS.

## Étape 8 — Test de reconstruction et README

- [test-reconstruction.md](test-reconstruction.md) : procédure `terraform destroy` puis `apply` (ce qui
  est détruit, ce qui est conservé, durée à mesurer, dépannage).
- **`t3.medium` par défaut** : la procédure d'installation ne doit pas mener à une instance trop petite.

### Résultat du premier essai réel (17/11/2026)

Instance neuve créée par un seul `terraform apply`, sans intervention ensuite :

- instance lancée à 14:14:11 UTC, script de démarrage terminé à 14:16:56 UTC : **2 min 45 s**
  (paquets 35 s, Argo CD 1 min 04 s, secrets 11 s, Tailscale 3 s) ;
- **11 contrôles sur 11 OK** : 3 applications Argo CD `Synced/Healthy`, 6 deployments par namespace,
  secrets présents, clé age supprimée du disque, Tailscale connecté, 6 jobs `aws-*` reçus par le
  Prometheus du NAS (requête faite depuis l'instance, seule autorisée à joindre le NAS) ;
- premier démarrage complet sans rattrapage manuel, après les deux correctifs ci-dessus.

### Reste à démontrer

Mise en production depuis staging et `git revert`, rejoués sur AWS.

## Réplicas : un seul partout, deux pour `dns-analyzer` en production

- **Règle de départ : 1 réplica.** Un seul nœud K3s : trois réplicas tourneraient sur la même machine
  (aucun gain si elle tombe) et ne tiendraient pas dans les 4 Go. Les mises à jour se font sans coupure
  (`maxSurge: 1`, `maxUnavailable: 0`).
- **Exception : `dns-analyzer` a 2 réplicas en production**, par `replicas:` dans
  `k8s/cyberlab/overlays/production/kustomization.yaml`. Il ne garde aucun état entre deux requêtes ;
  `audit-orchestrator` (jobs en mémoire) et `sherlock` restent à 1. Staging reste à 1.
- **Ce que cela montre** : le nombre de réplicas se règle par environnement dans l'overlay, par une PR,
  appliqué par Argo CD. Limite connue : les deux réplicas partagent le même nœud.
- À vérifier sur AWS : 2 pods `dns-analyzer` en production, mémoire de l'instance (`free -m`).
