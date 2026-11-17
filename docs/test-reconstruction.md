# Test de reconstruction : `terraform destroy` puis `terraform apply`

**Ce que ce test prouve** : toute l'infrastructure se reconstruit à partir de rien, **sans aucune intervention manuelle**, et le cyberlab fonctionne à nouveau (backends, tunnels, supervision sur le NAS). C'est la preuve que Git + Terraform décrivent *vraiment* l'infrastructure.

## Ce qui est détruit, ce qui reste

| Détruit par `terraform destroy` | Conservé (volontairement) |
|---|---|
| VPC, sous-réseau, groupe de sécurité, instance EC2, rôle IAM, IP élastique, budget | Bucket S3 de l'état Terraform (module `bootstrap/`, `prevent_destroy`) |
| Tout le cluster K3s, Argo CD, les pods, les Secrets du cluster | Paramètres SSM `/cyberlab-aws/age-key` et `/cyberlab-aws/tailscale-authkey` (créés à la main, une fois) |
| | Le dépôt Git (source de vérité), la clé age sur le poste, la configuration du NAS |

L'IP publique change après un destroy (nouvelle IP élastique) : sans conséquence, le trafic passe par les tunnels Cloudflare (connexions sortantes), et le NAS n'a besoin que de l'accès **de** l'instance **vers** lui.

## Avant de commencer

- `terraform/main/terraform.tfvars` et `backend.hcl` présents (voir [terraform/README.md](../terraform/README.md)).
- Les deux paramètres SSM existent : `aws --region eu-west-3 ssm describe-parameters --query 'Parameters[].Name'`.
- Clé Tailscale non expirée (90 jours maximum, voir [changements-nas-monitoring.md](changements-nas-monitoring.md) §1).
- `main` contient tout ce qu'on veut tester : le bootstrap clone `repo_ref` (`main` par défaut).

## Déroulé

```bash
cd terraform/main

# 1. Tout détruire. Relire la liste : rien d'autre que les ressources de ce module.
terraform destroy

# 2. Vérifier que l'état est vide (le bucket d'état, lui, n'est pas concerné).
terraform state list            # ne doit rien afficher

# 3. Tout reconstruire. C'est la SEULE commande ; ensuite on n'intervient plus.
terraform apply

# 4. Vérifier de l'extérieur (réessaie tout seul jusqu'à ce que tout soit prêt).
cd ../..
scripts/verify-rebuild.sh
```

Mesurer le temps entre `terraform apply` et « TOUT EST OK » : c'est la durée de reconstruction à annoncer au jury. Attendu : une dizaine de minutes au plus (création AWS ~1 min, bootstrap cloud-init environ 3 min, puis démarrage des pods et premières métriques).

Pendant l'attente, on peut suivre le bootstrap sans y toucher :

```bash
ssh -i ~/.ssh/cyberlab-aws ubuntu@$(terraform -chdir=terraform/main output -raw public_ip) \
  "sudo tail -f /var/log/cyberlab-bootstrap.log"
```

## Ce que contrôle `scripts/verify-rebuild.sh`

| Contrôle | Prouve que |
|---|---|
| `/var/lib/cyberlab-bootstrap.done` + « Bootstrap termine » | le script cloud-init est allé jusqu'au bout (les 8 étapes) |
| Noeud K3s `Ready` | K3s est installé et fonctionnel |
| 3 applications Argo CD `Synced/Healthy` | Argo CD a lu Git et déployé staging, production et la supervision |
| 6 deployments disponibles + Secrets présents par namespace | backends et tunnels tournent, secrets déchiffrés (SOPS) et appliqués |
| Clé age absente du disque | la clé privée n'a pas été laissée sur l'instance |
| Tailscale connecté, NAS joignable | le lien privé vers le NAS fonctionne |
| 6 jobs `aws-*` avec `up == 1` côté NAS | **les métriques arrivent réellement sur le NAS** (la requête est posée au Prometheus du NAS) |

Le script sort avec le code 0 si tout est bon, 1 sinon (lignes `KO` + journal à consulter).

## En cas d'échec

| Symptôme | Où regarder |
|---|---|
| Bootstrap non terminé | `sudo tail -50 /var/log/cyberlab-bootstrap.log` : la dernière étape atteinte indique la cause (réseau, empreinte SHA-256 refusée, paramètre SSM illisible) |
| Applications non `Healthy` | `sudo kubectl -n argocd get applications` puis `describe application <nom>` |
| Aucun job `aws-*` sur le NAS | `sudo tailscale status` (clé expirée ? ACL ?), `sudo kubectl -n monitoring logs deploy/prometheus-agent --tail=20` |
| Pods `Pending` / `OOMKilled` | mémoire : `instance_type = "t3.medium"` (une `t3.small` est trop juste) |

Le bootstrap ne s'exécute qu'**une fois** par instance (`/var/lib/cyberlab-bootstrap.done`) ; pour le rejouer il faut recréer l'instance (`terraform apply -replace=aws_instance.node`) plutôt que de le relancer à la main.

## Résultat à consigner

Après chaque essai réel, noter dans [notes-projet.md](notes-projet.md) la date, la durée mesurée et les écarts constatés : c'est l'historique que le jury pourra consulter.
