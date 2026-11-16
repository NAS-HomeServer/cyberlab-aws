# Bootstrap : bucket S3 de l'etat Terraform, cree A PART et jamais detruit.
#
# Pourquoi un module separe : le module principal stocke son etat dans ce bucket.
# Il ne peut donc pas le creer lui-meme (oeuf et poule), et un
# "terraform destroy" du module principal ne doit jamais le supprimer.
# L'etat de CE module reste local (terraform.tfstate, ignore par git) : il ne decrit
# qu'un bucket, que l'on peut reimporter (terraform import) si le fichier est perdu.
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "region" {
  description = "Region AWS du bucket d'etat (la meme que le module principal)."
  type        = string
  default     = "eu-west-3"
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = "cyberlab-aws"
      ManagedBy = "terraform-bootstrap"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  # Le nom d'un bucket S3 est unique au monde : on y met l'identifiant du compte.
  bucket_name = "cyberlab-aws-tfstate-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name

  # Garde-fou : "terraform destroy" refusera de supprimer le bucket d'etat.
  lifecycle {
    prevent_destroy = true
  }
}

# Historique des versions : on peut revenir a un etat anterieur en cas d'erreur.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3 (cle geree par AWS) plutot qu'une cle KMS dediee : une cle geree par le
# client coute environ 1 $/mois et n'apporte rien ici (acces deja limite par IAM et
# public access block). Risque accepte, a revoir si l'etat contient un jour des
# secrets plus sensibles.
#trivy:ignore:AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# L'etat peut contenir des valeurs sensibles : aucun acces public, jamais.
resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Refuse tout acces non chiffre (HTTP simple).
data "aws_iam_policy_document" "tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket     = aws_s3_bucket.state.id
  policy     = data.aws_iam_policy_document.tls_only.json
  depends_on = [aws_s3_bucket_public_access_block.state]
}

# Les anciennes versions ne s'accumulent pas indefiniment.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

output "state_bucket" {
  description = "Nom du bucket a reporter dans terraform/main/backend.hcl."
  value       = aws_s3_bucket.state.bucket
}
