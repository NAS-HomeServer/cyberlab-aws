resource "aws_security_group" "node" {
  name        = "cyberlab-aws-node"
  description = "Noeud K3s cyberlab : aucune entree publique, sorties libres"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "cyberlab-aws-node" }
}

# SSH uniquement depuis les adresses listees (jamais 0.0.0.0/0, voir variables.tf).
# Ni 80/443 (le trafic arrive par les tunnels cloudflared, sortants), ni 6443
# (API Kubernetes : on y accede par SSH), ni 9100 (metriques : le noeud pousse
# vers le NAS, rien ne vient le chercher).
resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each          = toset(var.ssh_allowed_cidrs)
  security_group_id = aws_security_group.node.id
  description       = "SSH depuis ${each.value}"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = each.value
}

# Sorties ouvertes, choix assume : sherlock interroge des centaines de sites,
# dns-analyzer interroge des serveurs DNS choisis par l'utilisateur sur des ports
# arbitraires, cloudflared a besoin de 7844 (tcp/udp), l'agent de la liaison vers le
# NAS (Tailscale : UDP 41641 ou 443). Filtrer les sorties casserait les fonctions des
# backends ; le controle se fait cote entree (aucune) et par les NetworkPolicies.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.node.id
  description       = "Toutes les sorties (voir le commentaire ci-dessus)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
