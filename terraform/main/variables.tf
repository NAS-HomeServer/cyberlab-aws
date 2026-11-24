variable "region" {
  description = "Region AWS."
  type        = string
  default     = "eu-west-3" # Paris
}

variable "instance_type" {
  description = "Type d'instance EC2 (x86 : les images des backends ne sont publiees qu'en amd64). t3.medium : K3s, Argo CD et les 13 pods ne tiennent pas dans les 2 Go d'une t3.small."
  type        = string
  default     = "t3.medium"
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
  description = "Cle publique SSH installee sur l'instance (utilisateur ubuntu), pour s'y connecter."
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

variable "repo_url" {
  description = "Depot Git public clone par l'instance au demarrage (modeles de Secrets, script secrets.sh)."
  type        = string
  default     = "https://github.com/NAS-HomeServer/cyberlab-aws.git"
}

variable "repo_ref" {
  description = "Branche ou tag clone par l'instance. Mettre une branche pour tester avant fusion."
  type        = string
  default     = "main"
}

variable "age_key_parameter" {
  description = "Nom du parametre SSM (SecureString) qui contient la cle privee age. Cree a la main, une fois, hors Terraform."
  type        = string
  default     = "/cyberlab-aws/age-key"
}

variable "tailscale_authkey_parameter" {
  description = "Nom du parametre SSM (SecureString) qui contient la cle d'authentification Tailscale. Cree a la main, une fois ; absent, l'instance demarre sans lien vers le NAS."
  type        = string
  default     = "/cyberlab-aws/tailscale-authkey"
}

variable "tailscale_oauth_parameter" {
  description = "Nom du parametre SSM (SecureString, format client_id:client_secret) d'un client OAuth Tailscale (scope devices:core en ecriture). Facultatif : sert a supprimer l'ancien noeud cyberlab-aws a chaque reconstruction, pour n'avoir qu'une machine dans Tailscale."
  type        = string
  default     = "/cyberlab-aws/tailscale-oauth"
}
