variable "region" {
  description = "Region AWS (la meme que le bucket d'etat)."
  type        = string
  default     = "eu-west-3" # Paris
}

variable "instance_type" {
  description = "Type d'instance EC2 (x86 : les images des backends ne sont publiees qu'en amd64)."
  type        = string
  default     = "t3.small"
  validation {
    condition     = can(regex("^t3\\.", var.instance_type))
    error_message = "Utiliser un type t3.* (x86) : les images backends sont en amd64 seulement."
  }
}

variable "root_volume_gb" {
  description = "Taille du disque racine en Go (gp3, chiffre)."
  type        = number
  default     = 20
}

variable "ssh_public_key" {
  description = "Cle publique SSH installee sur l'instance (utilisateur ubuntu), pour Ansible."
  type        = string
}

variable "ssh_allowed_cidrs" {
  description = "CIDR autorises a joindre SSH (22). Liste vide : aucun port entrant, acces par SSM."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for c in var.ssh_allowed_cidrs : c != "0.0.0.0/0" && can(cidrhost(c, 0))])
    error_message = "Chaque entree doit etre un CIDR valide, et 0.0.0.0/0 est interdit."
  }
}

variable "vpc_cidr" {
  description = "Plage du VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "monthly_budget_usd" {
  description = "Budget mensuel en dollars ; des alertes sont envoyees a 80 % (reel) et 100 % (prevu)."
  type        = number
  default     = 15
}

variable "budget_email" {
  description = "Adresse qui recoit les alertes de budget."
  type        = string
}
