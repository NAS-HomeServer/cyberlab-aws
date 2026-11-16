# Role de l'instance : uniquement AWS Systems Manager (acces de secours par
# Session Manager si SSH est ferme ou injoignable). Aucun droit sur S3, EC2 ni IAM :
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

resource "aws_iam_instance_profile" "node" {
  name = "cyberlab-aws-node"
  role = aws_iam_role.node.name
}
