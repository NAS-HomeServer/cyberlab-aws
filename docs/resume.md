# Résumé du projet

Un `terraform apply` crée l'infrastructure AWS, puis Argo CD déploie tout depuis Git sur Kubernetes (K3s), qui orchestre les 3 conteneurs de l'application (`sherlock`, `dns-analyzer`, `audit-orchestrator`).
La CI valide chaque pull request, staging se synchronise automatiquement et la production attend une validation manuelle (clic « Sync »). 
La supervision est assurée par Prometheus et Grafana sur le NAS et Alertmanager envoie les alertes sur Discord.
