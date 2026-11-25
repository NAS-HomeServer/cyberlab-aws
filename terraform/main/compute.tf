# Ubuntu Server 24.04 LTS (amd64), image officielle Canonical publiee par AWS.
data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_key_pair" "admin" {
  key_name   = "cyberlab-aws-admin"
  public_key = var.ssh_public_key
}

resource "aws_instance" "node" {
  ami                    = nonsensitive(data.aws_ssm_parameter.ubuntu_ami.value)
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.node.id]
  iam_instance_profile   = aws_iam_instance_profile.node.name
  key_name               = aws_key_pair.admin.key_name

  # Bootstrap au premier demarrage (cloud-init) : K3s, Argo CD, secrets.
  # user_data = les "export" ci-dessous (parametres), suivis du contenu de
  # scripts/bootstrap-node.sh (fichier separe, verifiable par shellcheck).
  # Aucun secret ici : seule la clef age est lue dans SSM, par l'instance.
  user_data = <<-EOT
    #!/usr/bin/env bash
    export REPO_URL='${var.repo_url}'
    export REPO_REF='${var.repo_ref}'
    export AWS_REGION='${var.region}'
    export AGE_PARAM='${var.age_key_parameter}'
    export TS_PARAM='${var.tailscale_authkey_parameter}'
    export TS_OAUTH_PARAM='${var.tailscale_oauth_parameter}'
    ${file("${path.module}/../../scripts/bootstrap-node.sh")}
  EOT
  # Changer le script ou ses parametres recree l'instance : l'etat voulu est toujours
  # celui que decrit le depot, jamais une instance modifiee a la main.
  user_data_replace_on_change = true

  # IMDSv2 obligatoire, et hop limit 1 : un pod (un saut reseau de plus que l'hote)
  # ne peut pas lire les metadonnees de l'instance. audit-orchestrator et sherlock
  # font des requetes vers des cibles choisies par l'utilisateur : c'est la parade
  # contre le vol d'identifiants par SSRF.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
    # Aucune donnee durable sur l'instance : tout se reconstruit (Terraform, cloud-init, ArgoCD).
    delete_on_termination = true
  }

  # Detail "monitoring" des metriques CloudWatch inutile : on supervise via Prometheus.
  monitoring = false

  tags = { Name = "cyberlab-aws-k3s" }

  lifecycle {
    # Ubuntu publie de nouvelles AMI : sans cela, un simple "plan" proposerait de
    # REMPLACER l'instance. On ne change d'image que volontairement (taint/destroy).
    ignore_changes = [ami]
  }
}

# IP publique fixe : survit aux arrets/demarrages de l'instance (sans elle,
# l'adresse change a chaque "start"). Detruite avec le reste par un "destroy".
resource "aws_eip" "node" {
  domain = "vpc"
  tags   = { Name = "cyberlab-aws-k3s" }
}

resource "aws_eip_association" "node" {
  instance_id   = aws_instance.node.id
  allocation_id = aws_eip.node.id
}
