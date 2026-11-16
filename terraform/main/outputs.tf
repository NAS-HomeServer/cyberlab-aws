output "instance_id" {
  description = "Identifiant de l'instance (arret/demarrage : scripts/instance.sh)."
  value       = aws_instance.node.id
}

output "public_ip" {
  description = "IP elastique de l'instance (inventaire Ansible)."
  value       = aws_eip.node.public_ip
}

output "ssh_user" {
  description = "Utilisateur SSH par defaut de l'AMI Ubuntu."
  value       = "ubuntu"
}

output "region" {
  value = var.region
}
