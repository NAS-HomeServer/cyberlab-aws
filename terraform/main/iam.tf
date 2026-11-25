# Role de l'instance : AWS Systems Manager (acces de secours par Session Manager si SSH est
# ferme ou injoignable) et lecture des TROIS parametres SSM du demarrage (cle age, cle Tailscale, client OAuth ; voir plus bas).
# Aucun droit sur S3, EC2 ni IAM :
# un pod compromis qui atteindrait les metadonnees n'aurait rien d'exploitable
# (et IMDSv2 avec hop limit 1 l'en empeche, voir compute.tf).
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "cyberlab-aws-node"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Lecture de la cle age, de la cle d'authentification Tailscale et du client OAuth : le bootstrap
# en a besoin pour dechiffrer les secrets et rejoindre le reseau prive du NAS.
# La cle est un SecureString chiffre par la cle AWS geree "aws/ssm", dont la politique autorise
# deja le dechiffrement via SSM : aucun droit KMS a ajouter.
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "age_key" {
  statement {
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.age_key_parameter}",
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.tailscale_authkey_parameter}",
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.tailscale_oauth_parameter}",
    ]
  }
}

resource "aws_iam_role_policy" "age_key" {
  name   = "lecture-parametres-bootstrap"
  role   = aws_iam_role.node.id
  policy = data.aws_iam_policy_document.age_key.json
}

resource "aws_iam_instance_profile" "node" {
  name = "cyberlab-aws-node"
  role = aws_iam_role.node.name
}
