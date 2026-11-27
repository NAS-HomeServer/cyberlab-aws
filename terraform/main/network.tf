# Reseau minimal : 1 VPC, 1 sous-reseau public, 1 passerelle Internet.
# Pas de NAT Gateway (environ 35 $/mois a elle seule) : l'instance est dans un
# sous-reseau public mais n'accepte aucune connexion entrante non demandee
# (voir security.tf) ; l'entree du trafic passe par les tunnels cloudflared, qui
# sont des connexions SORTANTES.
data "aws_availability_zones" "available" {
  #checkov:skip=CKV_AWS_394:Un seul sous-reseau, la premiere zone disponible suffit
  state = "available"
}

resource "aws_vpc" "main" {
  #checkov:skip=CKV2_AWS_11:VPC Flow Logs non actives, cout et volume disproportionnes
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "cyberlab-aws" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "cyberlab-aws" }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 1)
  availability_zone = data.aws_availability_zones.available.names[0]
  # L'adresse publique vient de l'IP elastique, pas d'une attribution automatique
  # (qui changerait a chaque arret/demarrage).
  map_public_ip_on_launch = false
  tags                    = { Name = "cyberlab-aws-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "cyberlab-aws-public" }

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Le groupe de securite par defaut du VPC est vide (aucun trafic) : on ne s'en sert pas.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
}
