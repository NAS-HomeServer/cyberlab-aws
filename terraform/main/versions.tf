terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Etat local (terraform.tfstate, ignore par git) : voir docs/notes-projet.md.
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
