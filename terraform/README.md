# Terraform

> Vue d'ensemble, state et aide-mémoire : [docs/terraform.md](../docs/terraform.md). Côté Kubernetes : [docs/kubernetes.md](../docs/kubernetes.md).

Un seul module, `main/` : VPC, sous-réseau public, groupe de sécurité, instance EC2 (Ubuntu 24.04), rôle IAM, IP élastique, budget. Il se détruit et se recrée à volonté.

**État local** : Terraform garde la correspondance code ↔ ressources AWS dans `main/terraform.tfstate` (ignoré par git, il peut contenir des données sensibles). Ce fichier survit à `terraform destroy`, ce qui permet de reconstruire. À conserver sur le poste : sans lui, Terraform ne retrouve plus ce qu'il a créé.

Ressources créées par `main/` : un VPC (`10.20.0.0/16`), une passerelle Internet, un sous-réseau public (**pas de NAT Gateway**), un groupe de sécurité, une instance `t3.medium` (disque gp3 20 Go chiffré), un rôle IAM limité à Systems Manager, une IP élastique et un budget mensuel avec alertes.

## Prérequis

- Terraform ≥ 1.10, AWS CLI configuré (profil habituel), région `eu-west-3` par défaut.
- Une clé SSH dédiée (`ssh-keygen -t ed25519 -f ~/.ssh/cyberlab-aws`).

## 1. Créer l'infrastructure

```bash
cd terraform/main
cp terraform.tfvars.example terraform.tfvars  # clé publique, son IP en /32, e-mail du budget
terraform init
terraform plan                                # relire : rien ne doit être détruit par surprise
terraform apply                               # ⚠ crée des ressources facturées (instance, IP élastique)
terraform output
```

`terraform.tfvars` et `terraform.tfstate` sont ignorés par git. Aucun secret n'est versionné.

## 2. Donner la clé age à l'instance (une seule fois, hors Terraform)

Au premier démarrage, l'instance a besoin de la clé privée age pour déchiffrer les secrets. Elle la lit dans AWS Systems Manager Parameter Store ; elle n'est jamais dans le dépôt, ni dans `user_data`, ni dans l'état Terraform.

```bash
aws --region eu-west-3 ssm put-parameter --name /cyberlab-aws/age-key --type SecureString \
  --value "$(cat ~/.config/sops/age/keys.txt)"
```

Ce paramètre n'est pas détruit par `terraform destroy` (il n'est pas géré par Terraform) : à ne faire qu'une fois. Coût : nul (paramètre standard).

## 3. Clé Tailscale (lien privé vers le NAS, une seule fois)

Même principe que la clé age : un paramètre SSM, créé à la main, lu par l'instance au premier démarrage. La création de la clé et les règles ACL sont décrites dans [docs/changements-nas-monitoring.md](../docs/changements-nas-monitoring.md) (§1). Sans ce paramètre l'instance démarre normalement, mais la supervision ne remonte pas au NAS (un avertissement apparaît dans le journal du script de démarrage).

## 4. Ce que fait l'instance au premier démarrage

Le script de démarrage `scripts/bootstrap-node.sh` (exécuté par cloud-init, environ 3 minutes mesurées), journal dans `/var/log/cyberlab-bootstrap.log` :

1. paquets de base, AWS CLI ;
2. SOPS ;
3. K3s (sans traefik ni servicelb) ;
4. Argo CD ;
5. clonage de ce dépôt (`repo_ref`, `main` par défaut) ;
6. lecture de la clé age dans SSM, `secrets.sh check` puis `apply` pour staging et production, puis suppression de la clé du disque ;
7. Tailscale (version et empreinte épinglées) : l'instance rejoint le tailnet avec le tag `tag:cyberlab-aws` ;
8. création des `Application` Argo CD (`k8s/argocd/applications/`) : les backends, les tunnels et la supervision se déploient ensuite depuis Git (voir [docs/gitops.md](../docs/gitops.md)).

**Mémoire** : K3s, Argo CD, les 13 pods applicatifs (production : `dns-analyzer` en 2 réplicas) et la supervision ne tiennent pas dans les 2 Go d'une `t3.small` (il restait ~750 Mo avec Argo CD seul) : le défaut est donc `t3.medium` (4 Go).

Chaque téléchargement est épinglé par version **et** par empreinte SHA-256. Pour tester une branche avant fusion : `repo_ref = "ma-branche"` dans `terraform.tfvars`.

Vérifier après un `apply` :

```bash
ssh -i ~/.ssh/cyberlab-aws ubuntu@$(terraform output -raw public_ip)
sudo cloud-init status --wait        # attendre "status: done"
sudo tail -5 /var/log/cyberlab-bootstrap.log   # "Bootstrap termine."
sudo kubectl get pods -A             # argocd-* Running
sudo kubectl -n cyberlab-staging get secrets   # 5 secrets
sudo kubectl -n argocd get applications        # staging et monitoring : Synced / Healthy ; cyberlab-production : OutOfSync jusqu au clic « Sync »
sudo kubectl -n cyberlab-production get pods   # vide tant que « Sync » n a pas ete valide ; ensuite 3 backends + 3 tunnels Running
```

## 5. Fin de démonstration

`terraform destroy` supprime tout (l'IP élastique est libérée, une nouvelle est attribuée au `apply` suivant : `terraform output public_ip` l'affiche). Le fichier d'état local et les paramètres SSM sont conservés.

## Choix de sécurité à connaître

- **Aucun port entrant public.** SSH (22) n'est ouvert que depuis `ssh_allowed_cidrs` (jamais `0.0.0.0/0`, refusé par une validation). Liste vide : accès uniquement par AWS Systems Manager (Session Manager). Le trafic des backends arrive par les tunnels cloudflared, qui sont des connexions **sortantes**.
- **Sorties ouvertes** (choix assumé, voir `docs/notes-projet.md`) : sherlock et dns-analyzer interrogent des cibles et des ports choisis par l'utilisateur.
- **IMDSv2 obligatoire, hop limit 1** : un pod ne peut pas lire les métadonnées de l'instance (protection contre le vol d'identifiants par SSRF). Le rôle IAM n'a de toute façon que les droits Systems Manager.
- **Disque chiffré**, fichier d'état jamais commité.
- **Pas de NAT Gateway** (≈ 35 $/mois à elle seule) : l'instance est dans un sous-réseau public, protégée par son groupe de sécurité.
- **`ignore_changes = [ami]`** : une nouvelle AMI Ubuntu ne remplace pas l'instance existante ; on ne change d'image qu'en recréant volontairement.
