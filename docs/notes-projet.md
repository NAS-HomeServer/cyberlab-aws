# Notes de projet — migration du cyberlab vers AWS

Journal des décisions, des alternatives écartées et des difficultés rencontrées.
Il sert de matière première pour le dossier de projet et la situation de
recherche du titre RNCP. Une section par étape ; on ajoute, on ne réécrit pas.

## Contexte et périmètre

- **Dépôt dédié** : tout le travail AWS vit dans ce dépôt (`NAS-HomeServer/cyberlab-aws`).
  `NAS-HomeServer/cyberlab-infra` reste la production sur le NAS (compose, Ansible du NAS,
  pipeline) et n'est pas modifié ; `HomeServer-monitoring` non plus.
  *Erreur de parcours* : la première PR (manifestes k8s) a d'abord été ouverte par
  erreur sur `cyberlab-infra` ; elle a été reprise ici et l'autre PR fermée.
  Leçon : confirmer le dépôt cible avant la première écriture, pas après.

- Point de départ : 3 backends (`sherlock`, `dns-analyzer`, `audit-orchestrator`),
  chacun derrière un tunnel `cloudflared`, sur un NAS Synology (Docker Compose,
  Ansible, runner GitHub auto-hébergé). Images publiques sur GHCR, épinglées par
  digest, signées Cosign.
- Objectif de l'étape A : le même service sur AWS (Terraform → EC2 K3s (cloud-init, sans Ansible)
  → ArgoCD → manifestes Kubernetes), deux environnements, supervision par le
  Prometheus du NAS via un Prometheus Agent. Le NAS reste la production tant que
  la bascule n'est pas décidée.

## Étape 1 — Manifestes Kubernetes (Kustomize), testés sur kind

### Constats sur les backends (état des lieux avant de migrer)

| | sherlock | dns-analyzer | audit-orchestrator |
|---|---|---|---|
| Données durables | aucune | aucune (fichier temporaire dans `/tmp`, supprimé après lecture) | aucune (jobs en mémoire, purgés après 1 h) |
| Tests unitaires en CI | non | non | non |
| Contrôles avant publication | ruff, build, smoke test sous durcissement prod, Trivy | eslint, smoke test, Trivy | eslint, smoke test, Trivy |
| `/metrics` Prometheus | non | non | non |
| `/health` | oui | oui | oui |

Conséquences :
- **Pas de volume EBS ni de bucket S3 pour les données** : les backends sont sans
  état durable. À noter dans le README (compétence « gérer le stockage de données » :
  la réponse est une décision argumentée, pas un volume inutile). Le seul stockage
  durable du projet est l'état Terraform (bucket S3 créé à part).
- **Un seul réplica par backend** : les jobs vivent dans la mémoire du process, le
  suivi d'un job doit retomber sur le même pod.
- **Tests avant mise en production** : aucun test unitaire dans les backends. Ce qui
  existe : lint + smoke test en CI. On le complète côté infra par la validation des
  manifestes (kubeconform, trivy, promtool), un test de bout en bout sur kind, et
  staging comme étape obligatoire avant la production.
- **Pas de `/metrics` côté backends** : on n'a pas modifié les backends pour l'étape A.
  Leur santé vient de kube-state-metrics (réplicas disponibles, redémarrages) et
  cAdvisor (CPU, mémoire). Les tunnels, eux, exposent `/metrics` grâce à `--metrics`.
  *Alternative écartée* : ajouter `prom-client` aux backends (touche 3 dépôts, hors périmètre).

### Décisions

- **Un seul EC2, un seul cluster K3s, deux namespaces** (`cyberlab-staging`,
  `cyberlab-production`) plutôt que deux instances : coût minimal, et ce qu'on
  démontre (Terraform, K8s, GitOps, promotion) ne dépend pas du nombre de machines.
  Limite assumée : staging et production partagent le même point de défaillance.
  *Alternative écartée* : un cluster par environnement (plus propre, deux fois plus cher).
- **Conséquence sur l'agent Prometheus** : un seul agent (namespace `monitoring`).
  Deux agents sur le même nœud dupliqueraient les métriques de l'hôte. Le label
  `env` n'est donc pas un `external_label` : il est déduit du namespace par
  relabeling (`cyberlab-staging` → `env=staging`), et vaut `shared` pour l'hôte et le
  cluster. `cluster=aws-k3s` reste un `external_label` (porté par l'overlay).
- **Structure** : `k8s/cyberlab/{base,overlays}` et `k8s/monitoring/{base,overlays}`.
  Deux ensembles indépendants car le monitoring est unique par cluster alors que
  `cyberlab` existe une fois par environnement. Les overlays `kind` servent au test
  local (secrets factices, faux NAS) ; `staging` et `production` à AWS.
- **Config de l'agent en deux fichiers** : `scrape.yml` (quoi collecter, dans la base,
  commun) et `prometheus.yml` (où envoyer, quels labels : un par overlay), reliés par
  `scrape_config_files`. Ainsi l'overlay ne répète pas les scrapes.
- **Digests** : toutes les images sont épinglées par digest (backends via
  `images:`/`digest:` dans les overlays pour pouvoir promouvoir staging → production ;
  cloudflared, Prometheus, node-exporter, kube-state-metrics directement dans les
  manifestes, suivis par Renovate via le gestionnaire `kubernetes`).
- **Reprise du durcissement du compose** : `read_only` → `readOnlyRootFilesystem`,
  `cap_drop ALL` → `capabilities.drop: [ALL]`, `no-new-privileges` →
  `allowPrivilegeEscalation: false`, `tmpfs /tmp` → `emptyDir` en mémoire (64 Mi),
  `mem_limit` → `resources.limits.memory`, healthchecks → probes (startup, readiness,
  liveness). Ajouts : `runAsNonRoot`, profil seccomp `RuntimeDefault`, jeton de
  ServiceAccount non monté, NetworkPolicies (ingress refusé par défaut), namespaces en
  Pod Security `restricted`.
- **Secrets séparés** : dans le compose, chaque tunnel reçoit tout le `.env` de son
  backend (clé Gemini, jetons internes). Ici le tunnel ne reçoit que son
  `TUNNEL_TOKEN` (Secret dédié) : moindre privilège.
- **Tunnels : un jeu par environnement, nouveaux tokens.** Réutiliser les tokens du NAS
  ferait répartir le trafic réel entre le NAS et AWS. Le NAS reste donc la production
  jusqu'à bascule explicite.
- **node-exporter** : seul composant qui exige `hostNetwork` + `hostPath` (lecture de
  `/proc`, `/sys`, `/`). Le namespace `monitoring` est donc en Pod Security `privileged`,
  et deux règles Trivy sont ignorées avec justification (`.trivyignore`).
  *Alternative écartée* : ne pas superviser l'hôte (perd CPU/mémoire/disque de l'EC2).
- **Pas de Helm ni d'Operator** : manifestes simples, lisibles en soutenance.
- **WAL de l'agent** : `emptyDir` plafonné (512 Mi), rétention max 4 h. Il survit à un
  redémarrage du conteneur, pas à l'arrêt de l'instance (rien à rattraper dans ce cas).
  Un `stop` du soir coupe aussi les métriques : c'est voulu.

### Difficultés rencontrées

- **Images backends en amd64 seulement, poste en arm64** : elles tournent quand même
  sous kind via l'émulation de Docker Desktop (pas de rebuild nécessaire). Sur AWS on
  prend des instances x86 (`t3`), pas `t4g`.
- **Liste YAML en ligne qui découpe sur la virgule** : `args: [--resources=a,b, --port=8080]`
  était lu comme trois arguments, d'où un `unknown command "pods"` et un CrashLoopBackOff
  de kube-state-metrics. Résolution : liste en bloc.
- **`name` non réécrit par Kustomize** : les ConfigMaps générées (avec suffixe de hash)
  n'étaient pas référencées par le Deployment tant que le `namespace` n'était pas fixé
  dans le `kustomization.yaml` (générateur et Deployment dans des namespaces différents
  pour Kustomize). Résolution : `namespace: monitoring` dans la base et les overlays.
- **Tunnels avec un faux token** : ils se connectent au réseau Cloudflare, échouent à
  l'enregistrement, et la liveness probe (sur `/ready`) les redémarrait en boucle. Sur
  kind uniquement, la liveness est retirée par un patch. Effet utile : les tunnels
  exposent bien `/metrics` et kube-state-metrics les voit à 0 réplica disponible.
- **Échantillons « out-of-order » de cAdvisor** : cAdvisor horodate ses échantillons.
  Résolution : `honor_timestamps: false` sur ce job.
- **`up` n'est pas touché par `metric_relabel_configs`** : pour que `up` porte `env`,
  le label est posé dans `relabel_configs` (cibles) pour les jobs par pod.
- **Piège de test** : `query_range` masque les trous (fenêtre de staleness de 5 min).
  Le test de résilience lit les échantillons bruts (`up[...]`).

### Validation (tout en local, aucun appel AWS)

- `kubeconform -strict` : 5 overlays valides. `trivy config` : 0 finding HIGH/CRITICAL
  (hors les 2 règles node-exporter ignorées avec justification).
- `promtool check config` sur la config de l'agent (overlays kind et aws).
- `k8s/kind/test.sh` : backends joignables sur `/health`, tunnels exposant `/metrics`,
  séries de l'agent reçues par un faux NAS avec `cluster` et `env` corrects.
- Scan Sherlock réel (nom d'utilisateur fictif) sous `readOnlyRootFilesystem` : fonctionne,
  le doute sur une écriture de `<user>.txt` est levé.
- `k8s/kind/test-resilience.sh` : liaison coupée 90 s puis rétablie, aucun trou
  (écart max entre échantillons bruts = intervalle de scrape).

### Questions repoussées aux étapes suivantes

- Transport vers le NAS (Tailscale recommandé) : étape 7, l'URL `remote_write` de
  l'overlay `aws` est un **placeholder** (`100.64.0.1`).
- Mise à jour des digests : les PR `bump/*` des backends visent `cyberlab-infra` et ne
  touchent que son compose (la production NAS).
  À traiter (sed supplémentaire côté backends, ou workflow de synchronisation ici).
- Secrets réels (SOPS + age + KSOPS) : étape 4 ; les overlays staging/production n'ont
  pas encore leurs Secrets.

## Étape 2 — CI de validation des manifestes

### Ce que fait la CI (`.github/workflows/ci.yml`)

| Étape | Contrôles | Bloquant |
|---|---|---|
| ① Code Quality | yamllint `--strict`, shellcheck, rendu Kustomize puis kubeconform `-strict` (schémas Kubernetes), promtool sur la config de l'agent (overlays kind et aws) | oui |
| ② Security | Gitleaks, signatures Cosign des images backends, Trivy config (HIGH/CRITICAL) sur les manifestes rendus, scan Trivy des images | tout sauf le scan des images |
| ③ Tests (kind) | déploiement complet sur un cluster kind jetable, puis test de résilience du `remote_write` | oui |

Principe : on valide ce que le cluster va réellement recevoir (la sortie de
`kubectl kustomize`), pas les fichiers sources. C'est ce qui l'a justifié : les
`images:`/`digest:` des overlays n'existent que dans le rendu.

### Décisions

- **Runners hébergés par GitHub, pas le runner du NAS.** Le dépôt est public : un
  runner auto-hébergé y exécuterait le code des PR de forks (risque connu), alors qu'un
  runner GitHub est jetable. kind y est disponible, et la CI de ce dépôt ne dépend plus
  de la disponibilité du NAS.
  La CI de `cyberlab-infra` (NAS) n'est pas touchée.
  *Alternative écartée* : runner auto-hébergé sur le NAS (Synology + kind dedans :
  fragile, et mélange validation AWS et production NAS).
- **Outils exécutés en conteneurs épinglés par digest**, comme dans la CI du NAS ; les
  actions GitHub sont épinglées par SHA de commit.
- **Version de Kubernetes de kubeconform** : 1.33, à aligner sur la version de K3s
  choisie pour le bootstrap de l'instance.
- **Cosign dans la CI** : la signature est vérifiée dès la PR. Une image non signée par
  la CI de son dépôt n'atteint jamais ArgoCD. (Vérifié en local sur les 3 images actuelles.)
- **Pas de job « Deploy »** : le déploiement est fait par ArgoCD (GitOps, étape 6), pas
  par la CI. La CI est donc la porte d'entrée de `main` (protection de branche à activer).

### Constat : le scan des images est informatif, pas bloquant

Premier scan Trivy (HIGH/CRITICAL, correctif disponible) : les 7 images remontent des
vulnérabilités, dont les 3 backends (sherlock 21 HIGH + 1 CRITICAL, dns-analyzer 59 + 2,
audit-orchestrator 13 + 1), kube-state-metrics (50 + 2) et Prometheus/node-exporter
(binaires Go compilés avec une ancienne version de Go). Un scan bloquant aurait empêché
tout déploiement dès le premier jour.
- Décision : le scan est publié dans le résumé du job à chaque exécution ; le gate
  bloquant reste le scan de configuration (misconfigurations) et la signature.
- Action de fond (hors de ce dépôt) : reconstruire les images des backends sur une base à
  jour (la CI de chaque backend scanne déjà ses images), mettre à jour Prometheus,
  node-exporter et kube-state-metrics via Renovate. Une fois la dette résorbée, passer le
  scan en bloquant (`--exit-code 1`).
- À présenter au jury comme un risque connu, mesuré et suivi, plutôt que caché.

### Difficultés rencontrées

- **yamllint et regex longues** : les listes `keep` de métriques dépassaient 200
  caractères. Résolution : chaînes entre guillemets avec continuation de ligne (`\`),
  vérifiées identiques après relecture du YAML.
- **shellcheck** a signalé des variables de boucle inutilisées dans les scripts de test
  (`for _ in …`).

### Reste à décider (étape 6)

Comment une nouvelle image backend arrive dans `k8s/` : les PR `bump/*` des backends
visent `cyberlab-infra`. Options : un `sed` en plus dans la CI des 3 backends (nécessite
un jeton vers ce dépôt), ou un workflow ici qui lit les digests du compose de
`cyberlab-infra` et ouvre une PR sur l'overlay staging.

## Étape 3 — Terraform (infrastructure AWS)

### Décisions

- **Deux modules** : `terraform/bootstrap` (bucket d'état S3, créé à part, `prevent_destroy`)
  et `terraform/main` (tout le reste, détruisible). Le bucket d'état ne peut pas être créé
  par le module qui l'utilise (œuf et poule) et ne doit jamais partir avec un `destroy`.
  L'état du bootstrap reste local (il ne décrit qu'un bucket, réimportable).
  *Alternative écartée* : tout dans un module avec un bucket `prevent_destroy` : un `destroy`
  échouerait au lieu de détruire le reste.
- **Verrou d'état S3 natif** (`use_lockfile`, Terraform ≥ 1.10) plutôt qu'une table DynamoDB :
  une ressource de moins à créer, à payer et à expliquer.
- **Backend partiel** : le nom du bucket (qui contient l'identifiant du compte) n'est pas
  dans le dépôt ; il est fourni par `backend.hcl` (ignoré par git).
- **Région `eu-west-3` (Paris)** par défaut, modifiable par variable.
- **Instance `t3.small`** (x86 : les images backends sont en amd64), modifiable. Passage à
  `t3.medium` si le nœud manque de mémoire (OOMKilled) : une ligne et un `apply`.
- **Ubuntu 24.04 LTS** via le paramètre SSM public de Canonical. `ignore_changes = [ami]` :
  sans cela, une nouvelle AMI ferait remplacer l'instance au prochain `plan`.
- **Réseau** : 1 VPC, 1 sous-réseau public, pas de NAT Gateway (coût).
- **Aucune entrée publique** : SSH limité à `ssh_allowed_cidrs` (jamais `0.0.0.0/0`,
  validation Terraform) ; liste vide = accès par Systems Manager uniquement. Le rôle IAM
  de l'instance n'a que `AmazonSSMManagedInstanceCore`.
  *Alternative écartée* : SSH ouvert à tous (inacceptable) ; Session Manager seul par défaut
  (demande le plugin SSM sur le poste, plus lourd pour se connecter à l'instance).
- **Sorties ouvertes** : le cahier des charges prévoyait des sorties limitées vers le NAS.
  Impossible sans casser les backends : sherlock sonde des centaines de sites,
  dns-analyzer interroge des serveurs DNS et des ports choisis par l'utilisateur,
  cloudflared exige 7844 (tcp/udp). Compromis : entrée fermée, sorties libres, contrôle fin
  par NetworkPolicies. L'exception Trivy est écrite à côté de la règle (`#trivy:ignore`).
  Resserrer (53, 80, 443, 7844, 123, Tailscale) casserait la fonction « interroger ce
  serveur DNS sur ce port » : à arbitrer avec le jury si la question est posée.
- **IMDSv2 obligatoire avec hop limit 1** : un pod (un saut réseau de plus) ne peut pas lire
  les métadonnées de l'instance. Les backends effectuent des requêtes vers des cibles
  choisies par l'utilisateur (risque SSRF) ; c'est la parade côté infrastructure.
- **IP élastique dans le module principal** : stable aux arrêts/démarrages (ce que fait
  `scripts/instance.sh`), libérée par un `destroy`. Avec Tailscale, le lien avec le NAS ne
  dépend pas de l'IP publique. *Alternative écartée* : l'allouer dans le bootstrap pour
  qu'elle survive aux `destroy` (coût permanent, utile seulement si le NAS filtrait par IP).
- **Budget** : alerte à 80 % du réel et 100 % du prévu, 15 $/mois par défaut ; l'adresse
  e-mail est une variable (jamais committée).
- **Aucun volume de données** : disque racine gp3 chiffré, `delete_on_termination` ;
  l'instance est jetable, tout se reconstruit.

### Validation (aucun appel à AWS)

`terraform fmt -check`, `init -backend=false` avec lockfile en lecture seule et `validate`
sur les deux modules (en local et dans la CI) ; Trivy config sans finding HIGH/CRITICAL.
Findings de moindre gravité connus et non traités : journaux d'accès du bucket d'état (LOW)
et VPC Flow Logs (MEDIUM, coût et volume disproportionnés ici).
`terraform plan` n'a **pas** été lancé : il interroge AWS et demande des identifiants.

### Difficultés rencontrées

- **Lockfile et architectures** : un `init` sur Mac Apple Silicon ne verrouille que
  `darwin_arm64` ; la CI (linux amd64) échouait sur le checksum. Résolution :
  `terraform providers lock` pour `linux_amd64`, `linux_arm64` et `darwin_arm64`.
- **Règle Trivy AWS-0132** (clé KMS gérée par le client) : refusée pour des raisons de coût
  (≈ 1 $/mois) ; SSE-S3 retenu, exception justifiée dans le code.
- **Commentaire d'étape YAML** : un « : » dans un nom d'étape de workflow cassait le YAML.

## Décision — pas d'Ansible côté AWS

Ansible était prévu pour installer K3s et ArgoCD et injecter la clé age. Décision :
s'en passer pour ne pas ajouter de difficulté, et faire ce bootstrap par `cloud-init`
(script passé en `user_data` de l'instance Terraform). Terraform seul reconstruit
alors tout : `terraform apply`, puis ArgoCD synchronise les applications.

- **Pourquoi c'est possible** : les compétences évaluées demandent d'automatiser le
  déploiement d'une infrastructure (Terraform) et de gérer les conteneurs et leur
  orchestration (Kubernetes) ; aucune n'exige Ansible. Il reste utilisé en production sur
  le NAS (dépôt `cyberlab-infra`), ce qui prouve la compétence par ailleurs.
- **Point délicat : la clé age.** Elle ne doit pas figurer dans `user_data` (lisible par les
  métadonnées de l'instance et la console AWS), ni dans le dépôt, ni dans l'état Terraform.
  Solution retenue : la clé (et les autres secrets de démarrage) est placée une seule fois
  par l'utilisateur dans AWS Systems Manager Parameter Store (SecureString, créé hors
  Terraform) ; le rôle IAM de l'instance reçoit le droit de lire uniquement ces paramètres ;
  le script de démarrage les lit et crée le Secret Kubernetes. Les pods ne peuvent pas
  utiliser ce rôle (IMDSv2, hop limit 1). Reconstruction complète sans geste manuel.
- **Limites acceptées** : cloud-init ne s'exécute qu'au premier démarrage (modifier le
  script revient à recréer l'instance, ce que `terraform plan` montre explicitement) ;
  le diagnostic passe par `/var/log/cloud-init-output.log` ; pas de durcissement système
  détaillé (le groupe de sécurité ferme déjà toute entrée publique, Ubuntu applique les
  mises à jour de sécurité automatiquement et refuse l'authentification SSH par mot de passe).
- **Conséquence sur le plan** : l'étape « Ansible » devient « bootstrap cloud-init »
  (K3s, ArgoCD, clé age, éventuellement Tailscale), et la reconstruction se résume à
  `terraform apply`.

### Protection de `main` et CI sans filtre de chemins

`main` est protégé par un ruleset (PR obligatoire, pas de force-push, trois checks
obligatoires : ① Code Quality, ② Security, ③ Tests (kind)). Avec un filtre de chemins sur
la CI, une PR qui ne touche que la documentation n'aurait jamais ses checks et resterait
bloquée : le filtre a été retiré (quelques minutes de CI en plus).

*Difficulté rencontrée* : des PR empilées (#2 sur #1, #3 sur #2) ont été fusionnées dans
leurs branches de base au lieu de `main` ; une PR d'intégration (#4) a été nécessaire.
Leçon : une PR par branche, toutes ouvertes directement sur `main`.

## Étape 4 — Secrets chiffrés (SOPS + age)

### Décisions

- **SOPS + age, clé privée gardée par l'utilisateur.** La clé publique est dans `.sops.yaml`
  (versionnable), la clé privée n'est jamais dans le dépôt. Seules les *valeurs* des
  Secrets Kubernetes sont chiffrées (`encrypted_regex`) : les diffs de PR restent lisibles.
- **Déchiffrement par un script, pas par ArgoCD.** `scripts/secrets.sh apply <env>` fait
  `sops --decrypt | kubectl apply`. Le script d'amorçage de l'instance l'exécutera au
  démarrage (étape suivante). ArgoCD gère les applications ; les Secrets sont créés à part.
  *Alternative écartée* : KSOPS dans ArgoCD (vrai GitOps pour les secrets, mais exige une
  image `repo-server` modifiée et un plugin à maintenir : la complexité que l'on veut éviter).
  *Contrepartie assumée* : modifier un secret demande de relancer le script plutôt qu'un
  simple `git push`.
- **Un fichier par Secret** (`secrets/<env>/<nom>.sops.yaml`), des modèles dans
  `secrets/templates/`. Le tunnel ne reçoit que son `TUNNEL_TOKEN` (moindre privilège).
- **Les noms de variables** viennent de la lecture du code des backends
  (`INTERNAL_API_TOKEN`, `DNS_ANALYZER_INTERNAL_TOKEN`, `GEMINI_API_KEY`, `ALLOWED_ORIGINS`) ;
  les `.env` réels du NAS n'ont pas été lus : l'utilisateur les compare aux modèles.
- **Garde-fou CI** (`ci/check-secrets-encrypted.sh`) : refuse tout fichier de `secrets/<env>/`
  sans bloc `sops:` ou avec une valeur non chiffrée, en plus de Gitleaks.
- **Comment la clé arrive au cluster à la reconstruction** : placée une fois par
  l'utilisateur dans AWS Systems Manager Parameter Store (SecureString, hors Terraform),
  lue au démarrage par l'instance via son rôle IAM, jamais dans le dépôt, `user_data` ni
  l'état Terraform. Mise en œuvre à l'étape suivante.

### Validation

`k8s/kind/test-secrets.sh` : avec une clé **jetable**, dans un dépôt temporaire, `keygen`,
`init`, `edit`, contrôle qu'aucune valeur n'est en clair, `apply` sur kind avec relecture de
la valeur dans le cluster, et refus de déchiffrer avec une autre clé.

### Difficultés rencontrées

- **Bug trouvé par le test** : `keygen` remplaçait mal la clé publique dans `.sops.yaml` (le
  marqueur contient des majuscules et des tirets bas, l'expression régulière attendait de
  l'age réel). Le marqueur restait collé à la vraie clé et `init` refusait de continuer.
- **Contexte kubectl** : le script d'application accepte `KUBE_CONTEXT` pour viser kind sans
  toucher au contexte courant.
- **Limite connue** : ce test n'est pas dans la CI (il exige sops, age et un cluster kind
  avec le test principal) ; seul le garde-fou « tout est chiffré » y tourne.

## Étape 5 — Bootstrap de l'instance (cloud-init, sans Ansible)

### Ce qui a été fait

- `scripts/bootstrap-node.sh`, exécuté une fois par cloud-init (`user_data` de l'instance) :
  paquets, AWS CLI, SOPS, K3s, Argo CD, puis dépôt cloné, clé age lue dans SSM, `secrets.sh
  check` + `apply` pour staging et production, clé supprimée du disque.
- Terraform : `user_data` (script précédé de ses paramètres), `user_data_replace_on_change`,
  politique IAM `ssm:GetParameter` sur **un seul** paramètre (la clé age), variables
  `repo_url`, `repo_ref`, `age_key_parameter`.
- CI : le script passe dans shellcheck.

### Choix et justifications

- **Un script plutôt qu'Ansible** : une seule exécution au premier démarrage suffit, puisque
  l'instance est jetable (destroy/apply). Le script est un fichier du dépôt (relisible,
  shellchecké), Terraform ne fait que le transmettre.
- **Tout est épinglé et vérifié** : K3s (script d'installation du tag), Argo CD
  (`install.yaml` du tag), SOPS (binaire) : version fixée + SHA-256 contrôlé. Une release
  modifiée après coup fait échouer le bootstrap au lieu de s'exécuter.
- **La clé age n'a pas besoin d'un droit KMS** : le SecureString est chiffré par la clé gérée
  `aws/ssm`, dont la politique autorise déjà le déchiffrement via SSM.
- **Les pods ne peuvent pas lire cette clé** : IMDSv2 avec hop limit 1 (voir étape 3). Seul
  le processus de l'hôte obtient les identifiants du rôle.
- **Les Secrets survivent aux arrêts/démarrages** (ils sont dans K3s, sur le disque chiffré) :
  le script ne tourne qu'au premier démarrage, la clé n'est donc pas gardée sur l'instance.
- **Mémoire** : K3s sans traefik, servicelb ni metrics-server ; Argo CD sans Dex ni
  notifications (mis à l'échelle 0). Si le noeud manque de mémoire : `instance_type = "t3.medium"`.
- **Stockage des Secrets dans K3s** : non chiffrés dans la base (disque EBS chiffré).
  Acceptable pour ce périmètre ; le chiffrement au repos d'etcd serait une amélioration.

### Validation

Statique : shellcheck, `terraform fmt/validate`, Trivy. Le bootstrap lui-même n'est **pas**
testable sur kind (il installe K3s sur une vraie VM) : le premier démarrage réel est le test.

## Étape 6 — GitOps : Argo CD, promotion, rollback

### Ce qui a été fait

- Trois `Application` Argo CD (`k8s/argocd/applications/`) : staging, production, supervision.
  Sync automatique avec `prune` et `selfHeal`. Créées par le bootstrap (étape 7 du script), avec
  l'URL et la branche de Terraform (`repo_url`, `repo_ref`) réécrites par `sed`.
- Promotion : `scripts/promote.sh` copie les digests de staging vers production ; la
  production ne reçoit jamais directement une image.
- Synchronisation des digests (**option A** retenue) : `ci/sync-digests.sh` lit le compose de
  `cyberlab-infra` (lecture seule) et le workflow `sync-digests.yml` ouvre une PR sur staging.
- Rollback : `git revert` de la fusion fautive ; Argo CD réapplique l'ancien digest.
- Test `k8s/kind/test-argocd.sh` : Argo CD (même version et même empreinte que le bootstrap,
  lues dans le script) clone ce dépôt sur GitHub et déploie l'overlay kind ; on vérifie
  Synced + Healthy, le selfHeal et la recréation d'une ressource supprimée. Ajouté à la CI.

### Choix et justifications

- **Pas d'app-of-apps** : trois `Application` appliquées par le bootstrap suffisent et
  permettent de tester une branche (`repo_ref`) sans modifier les fichiers. Ajouter une
  application demande donc de relancer le bootstrap (ou un `kubectl apply`) : acceptable ici.
- **Une branche, deux dossiers** : staging et production suivent `main` mais des dossiers
  différents (`overlays/staging`, `overlays/production`). La promotion est une PR, donc relue
  et soumise aux 3 checks (dont la signature Cosign des images).
- **Option A pour les digests** : les 3 CI de backends restent intactes et `cyberlab-infra`
  n'est jamais modifié. Contrepartie : un délai (cron toutes les 6 h, déclenchable à la main).
- **Secrets hors Argo CD** : appliqués par le bootstrap, donc jamais élagués (`prune`) et
  jamais dans le dépôt en clair.
- **Rollback par Git** plutôt que par l'interface : seul le revert laisse une trace durable.

### Difficultés et limites

- Une PR ouverte par `GITHUB_TOKEN` ne déclenche pas la CI : le workflow lance `ci.yml` à la
  main sur la branche (`workflow_dispatch`). Réglage de dépôt requis (voir docs/gitops.md).
  **À confirmer au premier déclenchement réel.**
- Le test de bascule staging → production et le `git revert` ne sont pas rejoués sur kind
  (il faudrait un serveur Git dans le cluster) : ils se vérifient en démonstration sur AWS.
- Le premier démarrage réel du bootstrap complet (étape 7) reste à valider sur AWS ; la
  supervision enverra ses métriques vers une URL provisoire jusqu'à l'étape suivante.

## Étape 7 — Lien avec le NAS (Tailscale, remote_write, alertes)

### Ce qui a été fait

- **Transport : Tailscale**, déjà en place sur le NAS (`100.104.202.81`). L'instance l'installe au
  bootstrap (version et SHA-256 épinglés), avec une clé d'authentification lue dans SSM
  (`/cyberlab-aws/tailscale-authkey`, même mécanisme que la clé age) ; l'agent écrit sur
  `http://100.104.202.81:9090/api/v1/write`.
- Règles d'alerte pour le Prometheus du NAS (`nas-monitoring/cyberlab-aws.rules.yml`) et leurs
  tests unitaires `promtool`, vérifiés par la CI. Guide des changements à appliquer sur le NAS :
  `docs/changements-nas-monitoring.md` (le dépôt HomeServer-monitoring n'est pas modifié ici).

### Choix et justifications

- **Tailscale plutôt que tunnel cloudflared + Access** : déjà là, aucun port ouvert, accès limité
  par ACL au seul port 9090 du NAS. Le tunnel + Access aurait exigé d'envoyer deux en-têtes
  secrets avec chaque écriture ; Prometheus ne les lit pas dans un fichier, donc le secret
  aurait fini dans la configuration ou nécessité un proxy en plus. Il aurait aussi exposé un
  point d'écriture sur Internet, protégé seulement par Access.
- **Clé Tailscale non éphémère** : une machine éphémère est retirée du tailnet pendant l'arrêt
  du soir et ne pourrait pas se reconnecter au redémarrage (l'authentification n'a lieu qu'au
  premier démarrage). Contrepartie : les anciennes instances restent listées après un destroy.
- **Pas de DNS Tailscale** (`--accept-dns=false`) : les pods gardent le DNS du cluster.
- **Bootstrap tolérant** : sans paramètre SSM, l'instance démarre quand même (avertissement dans
  le journal), seule la supervision ne remonte pas.
- **Alertes bornées à `cluster="aws-k3s"`** et jobs `aws-*` : aucune interaction avec les règles
  existantes du NAS. Pas d'alerte « métriques absentes » : l'instance est arrêtée chaque soir.
- **Démo d'alerte et Argo CD** : le selfHeal rétablit un backend mis à 0 en quelques secondes ;
  pour la démo on suspend la synchronisation automatique de l'application, puis on la rétablit.

### Difficultés et limites

- **Bug trouvé par le test unitaire** : dans la règle mémoire, la jointure `on(...)` supprimait
  les labels `env` et `cluster` (le résumé de l'alerte aurait affiché un environnement vide).
  Corrigé avec `group_left`.
- **Vérification des labels** sur de vraies séries : les expressions des règles (hors seuils)
  ont été rejouées sur le faux NAS du test kind ; elles renvoient bien des séries.
- **Non testé de bout en bout** : l'envoi réel vers le NAS, l'ACL Tailscale et le déclenchement
  de l'alerte sur Discord demandent le NAS et AWS ; ils se vérifient au premier test réel.
  Les commandes de suspension/rétablissement de la synchronisation Argo CD aussi.
- **Clé Tailscale limitée à 90 jours** : à renouveler avant une reconstruction après ce délai.
- **Bug trouvé au premier test réel** : `tailscale up` ignore la variable `TS_AUTHKEY` (je l'avais
  supposé sans le vérifier). Sans clé, il affiche une URL de connexion interactive et attend
  indéfiniment : le bootstrap restait bloqué à l'étape 7. Corrigé : la clé est passée par
  `--auth-key=file:...`, avec un délai de 120 s et un avertissement, pour qu'un échec Tailscale
  ne bloque plus jamais K3s, Argo CD ni les applications.
