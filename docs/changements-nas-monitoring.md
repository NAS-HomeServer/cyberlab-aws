# Changements à appliquer sur le NAS (supervision d'AWS)

> **À retenir** : annexe hors cœur DevOps ; ce sont les réglages à faire sur le NAS pour recevoir les métriques d'AWS (Tailscale, récepteur Prometheus, règles d'alerte).

Ce document décrit ce qu'il faut appliquer **soi-même** côté NAS pour que le Prometheus du NAS reçoive et surveille le cyberlab AWS. Rien n'est modifié dans le dépôt `HomeServer-monitoring` depuis ici.

## Le flux

```
 Instance AWS (K3s)                                   NAS (Synology)
 ┌──────────────────────┐   WireGuard (Tailscale)    ┌──────────────────────────┐
 │ Prometheus Agent     │ ─────────────────────────▶ │ Prometheus :9090         │
 │  scrape : kubelet,   │  remote_write              │  /api/v1/write (récepteur)│
 │  cAdvisor, node,     │  http://100.104.202.81:    │  règles cyberlab-aws.yml │
 │  kube-state, tunnels │  9090/api/v1/write         │          │               │
 └──────────────────────┘                            │   Alertmanager ─▶ Discord│
   labels : cluster=aws-k3s, env=staging|production  └──────────────────────────┘
```

- L'agent **pousse** : aucun port n'est ouvert sur AWS, et le NAS n'est joint que par le réseau privé Tailscale (chiffré). Il ne passe rien par Internet.
- Chaque série porte `cluster="aws-k3s"` et `env="staging|production|shared"`. Les séries du NAS n'ont pas ces labels, et les jobs AWS sont préfixés `aws-` : **les règles et tableaux existants ne voient pas AWS, et inversement**.

## 1. Tailscale : clé d'authentification et ACL

L'instance rejoint le réseau Tailscale (« tailnet ») du propriétaire au premier démarrage, avec une clé créée une seule fois.

1. **ACL** (console Tailscale → *Access controls*). Déclarer le tag et limiter ce qu'il peut joindre :
   ```json
   "tagOwners": {
     "tag:cyberlab-aws": ["autogroup:admin"]
   },
   "acls": [
     // ... règles existantes ...
     {"action": "accept", "src": ["tag:cyberlab-aws"], "dst": ["100.104.202.81:9090"]}
   ]
   ```
   L'instance ne peut alors joindre **que le port 9090 du NAS**, rien d'autre sur le tailnet. Attention : si la politique contient déjà une règle `"src": ["*"], "dst": ["*:*"]`, elle couvre aussi les appareils étiquetés ; remplace `"*"` par `"autogroup:member"` (les appareils du propriétaire) pour que la limite s'applique.
2. **Clé** (*Settings → Keys → Generate auth key*) :
   - *Reusable* : **oui** (chaque reconstruction de l'instance réutilise la même clé) ;
   - *Ephemeral* : **non** : une machine éphémère serait retirée du tailnet pendant l'arrêt du soir, et ne pourrait plus se reconnecter au redémarrage ;
   - *Pre-approved* : oui ; *Tags* : `tag:cyberlab-aws` ; *Expiration* : 90 jours (maximum). Passé ce délai, il faut créer une nouvelle clé et mettre à jour le paramètre SSM (l'instance déjà enregistrée n'est pas affectée).
3. **Stocker la clé dans AWS** (saisie masquée, rien dans l'historique du shell) :
   ```bash
   read -rs TSKEY
   aws --region eu-west-3 ssm put-parameter --name /cyberlab-aws/tailscale-authkey --type SecureString --value "$TSKEY"
   unset TSKEY
   ```

4. **Une seule machine dans la console (facultatif)** : sans cela, chaque `destroy` puis `apply` laisse l'ancien nœud hors ligne et le nouveau s'appelle `cyberlab-aws-1`, `-2`… (à supprimer à la main). Avec un client OAuth, le bootstrap supprime lui-même les anciens nœuds `cyberlab-aws*` portant `tag:cyberlab-aws` avant de rejoindre le réseau :
   - console Tailscale → *Settings → Trust credentials* → *Add credential* → type **OAuth** (et non OIDC), scope **Devices → Core : Write**, tag `tag:cyberlab-aws` (déjà présent dans les `tagOwners` de la policy). Le `client_secret` n'est affiché qu'une fois ;
   - stocker `client_id:client_secret` :
     ```bash
     read -rs TSOAUTH   # coller : client_id:client_secret
     aws --region eu-west-3 ssm put-parameter --name /cyberlab-aws/tailscale-oauth --type SecureString --value "$TSOAUTH"
     unset TSOAUTH
     ```
   Absent ou refusé, le bootstrap continue sans rien supprimer. L'adresse `100.x` change à chaque reconstruction (le nœud est neuf) ; seul le nom reste `cyberlab-aws`.

## 2. Prometheus du NAS : activer le récepteur

Dans `monitoring/docker-compose.yml` de `HomeServer-monitoring`, ajouter **une ligne** aux arguments de Prometheus :

```yaml
    command:
      # ... arguments existants ...
      - '--web.enable-remote-write-receiver'
```

Puis redéployer le service (Ansible habituel, ou `docker compose up -d prometheus`).

Le port `9090` est déjà publié sur toutes les interfaces : l'adresse `100.104.202.81:9090` (Tailscale) répond sans toucher au reverse proxy DSM (`prometheus-lan` n'est pas concerné, il ne sert que l'accès web par nom d'hôte). Si le **pare-feu DSM** est actif, autorise le port 9090 depuis l'interface Tailscale ou depuis la plage `100.64.0.0/10`.

Ce récepteur accepte les écritures de **n'importe quel client qui atteint le port 9090** ; c'est l'ACL Tailscale ci-dessus qui limite cela à l'instance AWS (et au LAN, comme avant).

## 3. Règles d'alerte

Copier [`nas-monitoring/cyberlab-aws.rules.yml`](../nas-monitoring/cyberlab-aws.rules.yml) dans `config/rules/` de `HomeServer-monitoring` (le dossier est déjà chargé par `rule_files: rules/*.yml`), puis recharger Prometheus :

```bash
curl -X POST http://localhost:9090/-/reload     # --web.enable-lifecycle est déjà actif
```

| Alerte | Se déclenche quand | Gravité |
|---|---|---|
| `AwsProductionWorkloadDown` | un deployment (backend **ou** tunnel) de production n'a plus aucun replica disponible pendant 2 min | critical |
| `AwsStagingWorkloadDown` | idem en staging, pendant 5 min | warning |
| `AwsTunnelNoConnection` | un tunnel cloudflared n'a plus de connexion vers Cloudflare pendant 3 min | critical |
| `AwsPodRestarting` | plus de 3 redémarrages d'un conteneur en 15 min | warning |
| `AwsContainerHighMemory` | un conteneur dépasse 85 % de sa limite mémoire pendant 5 min | warning |
| `AwsNodeLowMemory` | moins de 10 % de mémoire disponible sur l'instance pendant 10 min | warning |

Elles partent par l'Alertmanager existant, vers Discord, sans changement de sa configuration. **Il n'y a pas d'alerte « métriques absentes »** : l'instance n'est allumée que pour les démonstrations, l'alerte sonnerait en permanence.

Les règles sont vérifiées par `yamllint` dans la CI.

## 4. Vérifier que ça marche

Depuis l'instance AWS (`ssh`), une fois démarrée :

```bash
sudo tailscale status | head -3                          # le NAS apparaît
curl -s http://100.104.202.81:9090/-/healthy             # "Prometheus Server is Healthy."
sudo kubectl -n monitoring logs deploy/prometheus-agent --tail=10   # aucune erreur "remote write"
```

Sur le NAS (interface Prometheus, onglet *Graph*) :

```promql
count by (env, job) (up{cluster="aws-k3s"})
```

On doit voir les jobs `aws-kubelet`, `aws-cadvisor`, `aws-node`, `aws-kube-state-metrics`, `aws-cloudflared` et `aws-prometheus-agent`. Requêtes utiles pour un tableau de bord :

| Panneau | Requête |
|---|---|
| Replicas disponibles par service | `kube_deployment_status_replicas_available{cluster="aws-k3s"}` |
| Mémoire par conteneur | `container_memory_working_set_bytes{cluster="aws-k3s", namespace=~"cyberlab-.*"}` |
| Connexions des tunnels | `cloudflared_tunnel_ha_connections{cluster="aws-k3s"}` |
| Mémoire disponible sur l'instance | `node_memory_MemAvailable_bytes{cluster="aws-k3s"}` |
| Retard du remote_write (agent) | `time() - prometheus_remote_storage_queue_highest_sent_timestamp_seconds{cluster="aws-k3s"}` |

Si l'agent perd le NAS (coupure, redémarrage), il garde ses échantillons en mémoire et dans son WAL (4 h) puis les renvoie : sans trou visible (testé une fois à la main, 90 s de coupure).

À surveiller sur le NAS : la mémoire de Prometheus est limitée à 768 Mo ; le cyberlab AWS ajoute quelques milliers de séries (bornées par `sample_limit` dans l'agent). Contrôler `prometheus_tsdb_head_series` après quelques jours.

## 5. Démonstration : déclencher une alerte

La production n'a pas de synchronisation automatique (voir [gitops.md](gitops.md)) : Argo CD n'annule donc pas une modification manuelle, il se contente de marquer l'application `OutOfSync`. Aucune suspension préalable n'est nécessaire :

```bash
# Sur l'instance : couper un backend
sudo kubectl -n cyberlab-production scale deploy/sherlock --replicas=0
```

Après environ 2 min 30 (`for: 2m` + délai de regroupement de l'Alertmanager), `AwsProductionWorkloadDown` apparaît dans Prometheus (*Alerts*) et sur Discord. Pour tout rétablir, cliquer sur **Sync** dans Argo CD, ou :

```bash
sudo kubectl -n argocd patch application cyberlab-production --type merge -p '{"operation":{"sync":{}}}'
```

Argo CD ramène `sherlock` à 2 replicas, l'alerte se résout (message « résolu » sur Discord). **Lancer la coupure en début de démonstration**, pour que l'alerte soit visible au moment d'y revenir.

## Résumé : ce qu'il faut faire, dans l'ordre

1. Tailscale : ACL avec le tag, création de la clé, `put-parameter` (§1).
2. NAS : ajouter `--web.enable-remote-write-receiver`, redéployer (§2).
3. NAS : copier les règles, recharger Prometheus (§3).
4. Fusionner la PR, démarrer l'instance, vérifier (§4).
