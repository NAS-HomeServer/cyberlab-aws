# Changements à appliquer sur le NAS (supervision d'AWS)

Ce document décrit ce que **tu appliques toi-même** côté NAS pour que le Prometheus du NAS reçoive et surveille le cyberlab AWS. Rien n'est modifié dans le dépôt `HomeServer-monitoring` depuis ici.

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

L'instance rejoint ton réseau Tailscale (« tailnet ») au premier démarrage, avec une clé que tu crées une fois.

1. **ACL** (console Tailscale → *Access controls*). Déclare le tag et limite ce qu'il peut joindre :
   ```json
   "tagOwners": {
     "tag:cyberlab-aws": ["autogroup:admin"]
   },
   "acls": [
     // ... tes règles existantes ...
     {"action": "accept", "src": ["tag:cyberlab-aws"], "dst": ["100.104.202.81:9090"]}
   ]
   ```
   L'instance ne peut alors joindre **que le port 9090 du NAS**, rien d'autre sur le tailnet. Attention : si ta politique contient déjà une règle `"src": ["*"], "dst": ["*:*"]`, elle couvre aussi les appareils étiquetés ; remplace `"*"` par `"autogroup:member"` (tes appareils) pour que la limite s'applique.
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

À chaque `terraform destroy` puis `apply`, la nouvelle instance apparaît dans la console sous un nom en `-1`, `-2`… : tu peux supprimer les anciennes entrées hors ligne.

## 2. Prometheus du NAS : activer le récepteur

Dans `monitoring/docker-compose.yml` de `HomeServer-monitoring`, ajoute **une ligne** aux arguments de Prometheus :

```yaml
    command:
      # ... arguments existants ...
      - '--web.enable-remote-write-receiver'
```

Puis redéploie le service (ton Ansible habituel, ou `docker compose up -d prometheus`).

Le port `9090` est déjà publié sur toutes les interfaces : l'adresse `100.104.202.81:9090` (Tailscale) répond sans toucher au reverse proxy DSM (`prometheus-lan` n'est pas concerné, il ne sert que l'accès web par nom d'hôte). Si le **pare-feu DSM** est actif, autorise le port 9090 depuis l'interface Tailscale ou depuis la plage `100.64.0.0/10`.

Ce récepteur accepte les écritures de **n'importe quel client qui atteint le port 9090** ; c'est l'ACL Tailscale ci-dessus qui limite cela à l'instance AWS (et à ton LAN, comme avant).

## 3. Règles d'alerte

Copie [`nas-monitoring/cyberlab-aws.rules.yml`](../nas-monitoring/cyberlab-aws.rules.yml) dans `config/rules/` de `HomeServer-monitoring` (le dossier est déjà chargé par `rule_files: rules/*.yml`), puis recharge Prometheus :

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

Elles partent par ton Alertmanager existant, vers Discord, sans changement de sa configuration. **Il n'y a pas d'alerte « métriques absentes »** : l'instance est arrêtée chaque soir, elle sonnerait tous les jours.

Les règles sont vérifiées par `yamllint` dans la CI (les tests unitaires `promtool` ont été retirés pour simplifier).

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

Tu dois voir les jobs `aws-kubelet`, `aws-cadvisor`, `aws-node`, `aws-kube-state-metrics`, `aws-cloudflared` et `aws-prometheus-agent`. Requêtes utiles pour un tableau de bord :

| Panneau | Requête |
|---|---|
| Replicas disponibles par service | `kube_deployment_status_replicas_available{cluster="aws-k3s"}` |
| Mémoire par conteneur | `container_memory_working_set_bytes{cluster="aws-k3s", namespace=~"cyberlab-.*"}` |
| Connexions des tunnels | `cloudflared_tunnel_ha_connections{cluster="aws-k3s"}` |
| Mémoire disponible sur l'instance | `node_memory_MemAvailable_bytes{cluster="aws-k3s"}` |
| Retard du remote_write (agent) | `time() - prometheus_remote_storage_queue_highest_sent_timestamp_seconds{cluster="aws-k3s"}` |

Si l'agent perd le NAS (coupure, redémarrage), il garde ses échantillons en mémoire et dans son WAL (4 h) puis les renvoie : sans trou visible (testé une fois à la main, 90 s de coupure).

À surveiller sur le NAS : la mémoire de Prometheus est limitée à 768 Mo ; le cyberlab AWS ajoute quelques milliers de séries (bornées par `sample_limit` dans l'agent). Contrôle `prometheus_tsdb_head_series` après quelques jours.

## 5. Démonstration : déclencher une alerte

Argo CD **annule** toute modification manuelle (`selfHeal`) : si on met un backend à 0 replica, il le rétablit en quelques secondes et l'alerte n'a pas le temps d'apparaître. Pour la démo on suspend d'abord la synchronisation automatique de l'application :

```bash
# Sur l'instance. 1) suspendre la synchro automatique de la production
sudo kubectl -n argocd patch application cyberlab-production --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
# 2) couper un backend
sudo kubectl -n cyberlab-production scale deploy/sherlock --replicas=0
```

Après environ 2 min 30 (`for: 2m` + délai de regroupement de l'Alertmanager), `AwsProductionWorkloadDown` apparaît dans Prometheus (*Alerts*) et sur Discord. Pour tout rétablir :

```bash
sudo kubectl -n argocd patch application cyberlab-production --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

Argo CD ramène `sherlock` à 1 replica, l'alerte se résout (message « résolu » sur Discord). **Lance la coupure en début de démonstration**, pour que l'alerte soit visible quand tu y reviens.

## Résumé : ce que tu dois faire, dans l'ordre

1. Tailscale : ACL avec le tag, création de la clé, `put-parameter` (§1).
2. NAS : ajouter `--web.enable-remote-write-receiver`, redéployer (§2).
3. NAS : copier les règles, recharger Prometheus (§3).
4. Fusionner la PR, démarrer l'instance, vérifier (§4).
