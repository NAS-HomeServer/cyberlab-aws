# Résumé du projet

Un `terraform apply` crée l'infrastructure AWS, puis Argo CD déploie tout depuis Git ; la CI valide chaque pull request, staging se synchronise automatiquement et la production attend une validation manuelle (clic « Sync »).
