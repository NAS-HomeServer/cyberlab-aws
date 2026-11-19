# Terraform : ce qui est en place, simplement

Cette page répond à deux questions : **qu'est-ce que Terraform crée sur AWS**, et **où est son *state* (état)** ? Pour la partie Kubernetes, voir [kubernetes.md](kubernetes.md).

Détails complémentaires : [terraform/README.md](../terraform/README.md) (mode d'emploi pas à pas).

## Vue d'ensemble

```
 terraform apply          crée sur AWS :  1 VPC + 1 instance EC2 (Ubuntu) + IP élastique + IAM + budget
        │
        ▼  cloud-init lance le script de démarrage (scripts/bootstrap-node.sh)
 instance EC2             installe : K3s (Kubernetes léger) → Argo CD → secrets → Tailscale
        │
        ▼
 la suite (manifestes, Argo CD) : voir kubernetes.md
```

Règle de base : **Terraform construit la machine, Git décrit ce qui tourne dessus.**

> **Terraform crée la machine et lui remet un script ; Ubuntu, grâce à cloud-init, l'exécute tout seul au premier démarrage.**
> Cloud-init est un outil déjà présent dans l'image Ubuntu d'AWS : il lit le script (le `user_data` de l'instance) et l'exécute une seule fois, en root. Personne ne le lance à la main. Le script lui-même est `scripts/bootstrap-node.sh` ; son journal est `/var/log/cyberlab-bootstrap.log`.

## Où est le code

Un seul module : [terraform/main/](../terraform/main/). Chaque fichier a un rôle :

| Fichier | Ce qu'il fait |
|---|---|
| [versions.tf](../terraform/main/versions.tf) | Version de Terraform (≥ 1.10), fournisseur AWS (`~> 6.0`), région, étiquettes communes (`Project`, `ManagedBy`, `Environment`) |
| [variables.tf](../terraform/main/variables.tf) | Les réglages : région, type d'instance, clé SSH, IP autorisées, budget, dépôt Git à cloner |
| [network.tf](../terraform/main/network.tf) | VPC `10.20.0.0/16`, passerelle Internet, 1 sous-réseau public, table de routage. **Pas de NAT Gateway** (≈ 35 $/mois) |
| [security.tf](../terraform/main/security.tf) | Groupe de sécurité : **aucune entrée** sauf SSH depuis `ssh_allowed_cidrs` ; toutes les sorties ouvertes |
| [compute.tf](../terraform/main/compute.tf) | Instance EC2 `t3.medium`, disque gp3 20 Go chiffré, clé SSH, IP élastique, script de démarrage (`user_data`) |
| [iam.tf](../terraform/main/iam.tf) | Rôle IAM de l'instance : Systems Manager + lecture de 2 paramètres SSM seulement |
| [budget.tf](../terraform/main/budget.tf) | Alerte e-mail à 80 % (réel) et 100 % (prévu) du budget mensuel |
| [outputs.tf](../terraform/main/outputs.tf) | Valeurs affichées après `apply` : `instance_id`, `public_ip`, `ssh_user`, `region` |
| [terraform.tfvars.example](../terraform/main/terraform.tfvars.example) | Modèle des réglages personnels (à copier en `terraform.tfvars`) |
| [.terraform.lock.hcl](../terraform/main/.terraform.lock.hcl) | Versions exactes du fournisseur AWS (versionné) |

## Ce que crée Terraform (18 ressources, plus 5 lectures seules)

| Famille | Ressources |
|---|---|
| Réseau | `aws_vpc.main`, `aws_internet_gateway.main`, `aws_subnet.public`, `aws_route_table.public`, `aws_route_table_association.public`, `aws_default_security_group.default` (verrouillé, vide) |
| Sécurité | `aws_security_group.node`, `aws_vpc_security_group_egress_rule.all`, `aws_vpc_security_group_ingress_rule.ssh` (une par CIDR autorisé : leur nombre dépend de `ssh_allowed_cidrs`) |
| Calcul | `aws_instance.node`, `aws_key_pair.admin`, `aws_eip.node`, `aws_eip_association.node` |
| IAM | `aws_iam_role.node`, `aws_iam_role_policy_attachment.ssm`, `aws_iam_role_policy.age_key`, `aws_iam_instance_profile.node` |
| Coût | `aws_budgets_budget.monthly` |
| Lectures seules (*data*) | zones de disponibilité, identité AWS, AMI Ubuntu 24.04 officielle (lue dans SSM), documents de politique IAM |

## Le state Terraform

### À quoi il sert

Le state est le **carnet de correspondance** entre le code et AWS : « la ressource `aws_instance.node` du code est l'instance `i-0abc…` réelle ». Sans lui, Terraform ne sait plus ce qu'il a créé et voudrait tout recréer (ou échouerait sur des doublons).

### Où il est

| | |
|---|---|
| Type | **Local** (aucun bloc `backend` : pas de bucket S3) |
| Fichier | `terraform/main/terraform.tfstate` |
| Sauvegarde auto | `terraform/main/terraform.tfstate.backup` (l'état *précédent*, écrit par Terraform à chaque `apply`/`destroy`) |
| Git | **Ignoré** (`*.tfstate`, `*.tfstate.*` dans `.gitignore`) : il peut contenir des données sensibles |
| Choix | Voulu et documenté dans [notes-projet.md](notes-projet.md) : un seul opérateur, pas de bucket à payer ni à sécuriser |

⚠ **Ce fichier n'existe que sur le poste.** Le perdre pendant que l'infrastructure existe = Terraform ne la retrouve plus (il faudrait tout supprimer à la main dans la console AWS). Le copier de temps en temps hors du poste est une bonne précaution.

### Comment le lire

Ne pas ouvrir le JSON à la main : utiliser les commandes (lecture seule, sans risque) :

```bash
cd terraform/main
terraform state list                        # toutes les ressources suivies
terraform state show aws_instance.node      # le détail d'une ressource
terraform output                            # les sorties (IP publique, etc.)
terraform plan                              # écart entre le code, le state et AWS
```

### Lire un state vide

Après un `terraform destroy`, `terraform.tfstate` est **vide** (0 ressource) : c'est normal, cela signifie « rien n'existe, rien n'est facturé ». `terraform.tfstate.backup` garde l'état juste avant la destruction. Un `terraform apply` recrée tout et remplit le fichier ; `terraform state list` indique à tout moment ce qui est suivi.

> Le state **survit** à `terraform destroy` (il est simplement vidé). C'est ce qui permet de détruire en fin de démonstration puis de reconstruire à l'identique.

## Ce qui est hors Terraform (volontairement)

Deux paramètres **AWS Systems Manager** (SecureString), créés à la main, une seule fois, donc **jamais dans le state** et jamais détruits par `destroy` :

| Paramètre | Contenu | Lu par |
|---|---|---|
| `/cyberlab-aws/age-key` | clé privée age (déchiffre les secrets SOPS) | le script de démarrage de l'instance |
| `/cyberlab-aws/tailscale-authkey` | clé Tailscale (lien privé vers le NAS) | le script de démarrage de l'instance |

Le rôle IAM n'a le droit de lire **que ces deux paramètres**.

## Commandes courantes

```bash
cd terraform/main
terraform init                 # une fois : télécharge le fournisseur AWS
terraform plan                 # prévisualise, ne change rien
terraform apply                # ⚠ crée des ressources facturées
terraform output public_ip     # IP à utiliser pour SSH
terraform destroy              # supprime tout (le state est conservé, vidé)
```

Points à savoir : `user_data_replace_on_change = true` (modifier le script de démarrage (`scripts/bootstrap-node.sh`) ou ses paramètres **recrée** l'instance : l'état voulu est toujours celui du dépôt) et `ignore_changes = [ami]` (une nouvelle image Ubuntu ne remplace pas l'instance existante).

## Aide-mémoire

| Je cherche… | C'est là |
|---|---|
| Le state | `terraform/main/terraform.tfstate` (local, hors Git) ; `terraform state list` |
| L'ancien state | `terraform/main/terraform.tfstate.backup` |
| Ce que Terraform crée | `terraform/main/*.tf` |
| Mes réglages | `terraform/main/terraform.tfvars` (hors Git) |
| Le script de démarrage de l'instance | `scripts/bootstrap-node.sh` |
