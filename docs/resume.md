# Résumé du projet

1. **Infrastructure** : un `terraform apply` crée l'infrastructure AWS. Le script de démarrage de l'instance y installe Kubernetes (K3s) et Argo CD.
2. **Déploiement** : Argo CD déploie tout depuis Git, et Kubernetes orchestre les 3 conteneurs de l'application (`sherlock`, `dns-analyzer`, `audit-orchestrator`).
   - la CI valide chaque pull request ;
   - **staging** se synchronise automatiquement ;
   - **production** attend une validation manuelle (clic « Sync »).
3. **Supervision** : Prometheus et Grafana sur le NAS, et Alertmanager envoie les alertes sur Discord.
