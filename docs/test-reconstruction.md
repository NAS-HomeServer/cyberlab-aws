# Test de reconstruction : `terraform destroy` puis `terraform apply`

> **À retenir** : `terraform destroy` puis `apply` rétablit tout sans intervention manuelle ; ce test sert de preuve de reproductibilité.

**Ce que ce test prouve** : toute l'infrastructure se reconstruit à partir de rien, **sans aucune intervention manuelle**, et le cyberlab fonctionne à nouveau (backends, tunnels, supervision sur le NAS). C'est la preuve que Git + Terraform décrivent *vraiment* l'infrastructure.

## Ce qui est détruit, ce qui reste

| Détruit par `terraform destroy` | Conservé (volontairement) |
|---|---|
| VPC, sous-réseau, groupe de sécurité, instance EC2, rôle IAM, IP élastique, budget | L'état Terraform local (`terraform/main/terraform.tfstate`, sur le poste) |
| Tout le cluster K3s, Argo CD, les pods, les Secrets du cluster | Paramètres SSM `/cyberlab-aws/age-key` et `/cyberlab-aws/tailscale-authkey` (créés à la main, une fois) |
| | Le dépôt Git (source de vérité), la clé age sur le poste, la configuration du NAS |

L'IP publique change après un destroy (nouvelle IP élastique) : sans conséquence, le trafic passe par les tunnels Cloudflare (connexions sortantes), et le NAS n'a besoin que de l'accès **de** l'instance **vers** lui.

## Avant de commencer

- `terraform/main/terraform.tfvars` présent (voir [terraform.md](terraform.md)) et le fichier `terraform.tfstate` de la dernière exécution, sur le même poste : sans lui, Terraform ne retrouve pas ce qu'il a créé.
- Les deux paramètres SSM existent : `aws --region eu-west-3 ssm describe-parameters --query 'Parameters[].Name'`.
- Clé Tailscale non expirée (90 jours maximum, voir [changements-nas-monitoring.md](changements-nas-monitoring.md) §1).
- `main` contient tout ce qu'on veut tester : le script de démarrage clone `repo_ref` (`main` par défaut).

## Déroulé

```bash
cd terraform/main

# 1. Tout détruire. Relire la liste : rien d'autre que les ressources de ce module.
terraform destroy

# 2. Vérifier que l'état est vide.
terraform state list            # ne doit rien afficher

# 3. Tout reconstruire. C'est la SEULE commande ; ensuite on n'intervient plus.
terraform apply
```

Mesurer le temps entre `terraform apply` et le moment où tout est `Healthy` : c'est la durée de reconstruction à annoncer au jury. Attendu : une dizaine de minutes au plus (création AWS ~1 min, script de démarrage (cloud-init) environ 3 min, puis démarrage des pods). Les « moins de 3 minutes » du README ne mesurent que le script de démarrage.

## Vérifier que tout est revenu

Se connecter à l'instance et regarder trois choses :

```bash
ssh -i ~/.ssh/cyberlab-aws ubuntu@$(terraform -chdir=terraform/main output -raw public_ip)

sudo tail -5 /var/log/cyberlab-bootstrap.log     # « Bootstrap termine. »
sudo kubectl -n argocd get applications          # staging et monitoring : Synced / Healthy ; cyberlab-production : OutOfSync jusqu au clic « Sync »
sudo kubectl get pods -A                         # backends et tunnels : Running
```

| Contrôle | Prouve que |
|---|---|
| « Bootstrap termine » dans le journal | le script de démarrage est allé jusqu'au bout |
| 3 applications Argo CD `Synced/Healthy` | Argo CD a lu Git et déployé staging, production et la supervision |
| Pods `Running` dans `cyberlab-staging` et `cyberlab-production` | backends et tunnels tournent, secrets déchiffrés (SOPS) et appliqués |

Pour suivre le script de démarrage en direct pendant l'attente : `sudo tail -f /var/log/cyberlab-bootstrap.log`.

## Se connecter à l'interface Argo CD

Argo CD n'est pas exposé sur Internet : on y accède par un tunnel SSH. Deux commandes, à lancer **depuis la racine du dépôt** sur le poste.

**1. Récupérer le mot de passe `admin`** (généré par Argo CD au premier démarrage) :

```bash
ssh -i ~/.ssh/cyberlab-aws ubuntu@$(terraform -chdir=terraform/main output -raw public_ip) "sudo kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
```

**2. Ouvrir le tunnel** (à laisser tourner dans ce terminal) :

```bash
ssh -i ~/.ssh/cyberlab-aws -L 8080:localhost:8080 ubuntu@$(terraform -chdir=terraform/main output -raw public_ip) "sudo kubectl -n argocd port-forward svc/argocd-server 8080:443"
```

Puis ouvrir <https://localhost:8080> (accepter l'avertissement du certificat auto-signé) et se connecter avec l'utilisateur `admin` et le mot de passe de l'étape 1. C'est aussi là que se fait le clic « Sync » de `cyberlab-production`.

## En cas d'échec

| Symptôme | Où regarder |
|---|---|
| Script de démarrage non terminé | `sudo tail -50 /var/log/cyberlab-bootstrap.log` : la dernière étape atteinte indique la cause (réseau, empreinte SHA-256 refusée, paramètre SSM illisible) |
| Applications non `Healthy` | `sudo kubectl -n argocd get applications` puis `describe application <nom>` |
| Aucun job `aws-*` sur le NAS | `sudo tailscale status` (clé expirée ? ACL ?), `sudo kubectl -n monitoring logs deploy/prometheus-agent --tail=20` |
| Pods `Pending` / `OOMKilled` | mémoire : `instance_type = "t3.medium"` (une `t3.small` est trop juste) |

Le script de démarrage ne s'exécute qu'**une fois** par instance (`/var/lib/cyberlab-bootstrap.done`) ; pour le rejouer il faut recréer l'instance (`terraform apply -replace=aws_instance.node`) plutôt que de le relancer à la main.

## Résultat à consigner

Après chaque essai réel, noter dans [notes-projet.md](notes-projet.md) la date, la durée mesurée et les écarts constatés : c'est l'historique que le jury pourra consulter.
