# Role de l'instance : AWS Systems Manager (acces de secours par Session Manager si SSH est
# ferme ou injoignable) et lecture d'UN seul parametre SSM, la cle age (voir plus bas).
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

# Lecture de la cle age, et d'elle seule : le bootstrap en a besoin pour dechiffrer les secrets.
# La cle est un SecureString chiffre par la cle AWS geree "aws/ssm", dont la politique autorise
# deja le dechiffrement via SSM : aucun droit KMS a ajouter.
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "age_key" {
  statement {
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.age_key_parameter}"]
  }
}

resource "aws_iam_role_policy" "age_key" {
  name   = "lecture-cle-age"
  role   = aws_iam_role.node.id
  policy = data.aws_iam_policy_document.age_key.json
}

resource "aws_iam_instance_profile" "node" {
  name = "cyberlab-aws-node"
  role = aws_iam_role.node.name
}
