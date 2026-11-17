# Terraform

Deux modules indépendants :

| Module | Rôle | Cycle de vie |
|---|---|---|
| `bootstrap/` | Bucket S3 de l'état Terraform (versionné, chiffré, jamais public, protégé par `prevent_destroy`) | Créé **une fois**, jamais détruit |
| `main/` | VPC, sous-réseau public, groupe de sécurité, instance EC2 (Ubuntu 24.04), rôle IAM, IP élastique, budget | Détruit et recréé à volonté |

Ressources créées par `main/` : un VPC (`10.20.0.0/16`), une passerelle Internet, un sous-réseau public (**pas de NAT Gateway**), un groupe de sécurité, une instance `t3.small` (disque gp3 20 Go chiffré), un rôle IAM limité à Systems Manager, une IP élastique et un budget mensuel avec alertes.

## Prérequis

- Terraform ≥ 1.10, AWS CLI configuré (profil habituel), région `eu-west-3` par défaut.
- Une clé SSH dédiée (`ssh-keygen -t ed25519 -f ~/.ssh/cyberlab-aws`).

## 1. Créer le bucket d'état (une seule fois)

```bash
cd terraform/bootstrap
terraform init
terraform apply          # crée UN bucket S3 (quelques centimes par mois)
terraform output state_bucket
```

L'état de ce module reste **local** (`terraform.tfstate`, ignoré par git). Il ne décrit qu'un bucket : s'il est perdu, `terraform import aws_s3_bucket.state <nom>` le rattache.

## 2. Créer l'infrastructure

```bash
cd terraform/main
cp backend.hcl.example backend.hcl            # y reporter le nom du bucket
cp terraform.tfvars.example terraform.tfvars  # clé publique, votre IP en /32, e-mail du budget
terraform init -backend-config=backend.hcl
terraform plan                                # relire : rien ne doit être détruit par surprise
terraform apply                               # ⚠ crée des ressources facturées (instance, IP élastique)
terraform output
```

`backend.hcl` et `terraform.tfvars` sont ignorés par git. Aucun secret n'est versionné.

## 2 bis. Donner la clé age à l'instance (une seule fois, hors Terraform)

Au premier démarrage, l'instance a besoin de la clé privée age pour déchiffrer les secrets. Elle la lit dans AWS Systems Manager Parameter Store ; elle n'est jamais dans le dépôt, ni dans `user_data`, ni dans l'état Terraform.

```bash
aws --region eu-west-3 ssm put-parameter --name /cyberlab-aws/age-key --type SecureString \
  --value "$(cat ~/.config/sops/age/keys.txt)"
```

Ce paramètre n'est pas détruit par `terraform destroy` (il n'est pas géré par Terraform) : à ne faire qu'une fois. Coût : nul (paramètre standard).

## 2 ter. Ce que fait l'instance au premier démarrage

`scripts/bootstrap-node.sh` (cloud-init, environ 5 à 8 minutes), journal dans `/var/log/cyberlab-bootstrap.log` :

1. paquets de base, AWS CLI ;
2. SOPS ;
3. K3s (sans traefik ni servicelb) ;
4. Argo CD ;
5. clonage de ce dépôt (`repo_ref`, `main` par défaut) ;
6. lecture de la clé age dans SSM, `secrets.sh check` puis `apply` pour staging et production, puis suppression de la clé du disque.

Chaque téléchargement est épinglé par version **et** par empreinte SHA-256. Pour tester une branche avant fusion : `repo_ref = "ma-branche"` dans `terraform.tfvars`.

Vérifier après un `apply` :

```bash
ssh -i ~/.ssh/cyberlab-aws ubuntu@$(terraform output -raw public_ip)
sudo cloud-init status --wait        # attendre "status: done"
sudo tail -5 /var/log/cyberlab-bootstrap.log   # "Bootstrap termine."
sudo kubectl get pods -A             # argocd-* Running
sudo kubectl -n cyberlab-staging get secrets   # 5 secrets
```

## 3. Au quotidien : arrêter, ne pas détruire

```bash
scripts/instance.sh stop     # plus de facturation de calcul ; K3s repart tout seul au start
scripts/instance.sh start    # attend que l'instance soit prête ; l'IP ne change pas
```

`terraform destroy` est réservé au test de reconstruction : l'IP élastique est alors libérée et une nouvelle est attribuée au `apply` suivant (`terraform output public_ip` l'affiche).

## Choix de sécurité à connaître

- **Aucun port entrant public.** SSH (22) n'est ouvert que depuis `ssh_allowed_cidrs` (jamais `0.0.0.0/0`, refusé par une validation). Liste vide : accès uniquement par AWS Systems Manager (Session Manager). Le trafic des backends arrive par les tunnels cloudflared, qui sont des connexions **sortantes**.
- **Sorties ouvertes** (choix assumé, voir `docs/notes-projet.md`) : sherlock et dns-analyzer interrogent des cibles et des ports choisis par l'utilisateur.
- **IMDSv2 obligatoire, hop limit 1** : un pod ne peut pas lire les métadonnées de l'instance (protection contre le vol d'identifiants par SSRF). Le rôle IAM n'a de toute façon que les droits Systems Manager.
- **Disque chiffré**, état chiffré et versionné, jamais d'accès public au bucket.
- **Pas de NAT Gateway** (≈ 35 $/mois à elle seule) : l'instance est dans un sous-réseau public, protégée par son groupe de sécurité.
- **`ignore_changes = [ami]`** : une nouvelle AMI Ubuntu ne remplace pas l'instance existante ; on ne change d'image qu'en recréant volontairement.
