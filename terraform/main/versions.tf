terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Etat dans le bucket cree par terraform/bootstrap (jamais detruit).
  # Le nom du bucket n'est pas ecrit ici (les variables sont interdites dans ce
  # bloc) : il est fourni a l'init par un fichier backend.hcl, voir backend.hcl.example.
  backend "s3" {
    # Verrou natif S3 (Terraform >= 1.10) : pas besoin de table DynamoDB.
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "cyberlab-aws"
      ManagedBy   = "terraform"
      Environment = "shared" # un seul cluster K3s porte staging et production (namespaces)
    }
  }
}
