#!/usr/bin/env bash
# Arrete / demarre / interroge l'instance du cyberlab (sans la detruire).
# A l'arret, plus de facturation de calcul : seuls restent le disque et l'IP elastique.
# Au redemarrage, K3s relance les pods tout seul et l'IP publique ne change pas.
# Usage : scripts/instance.sh {start|stop|status|ip}
# Prerequis : AWS CLI configure (profil/variables habituels), terraform init fait dans terraform/main.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tf_out() { terraform -chdir="$ROOT/terraform/main" output -raw "$1"; }
ID="$(tf_out instance_id)"
REGION="$(tf_out region)"
aws_ec2() { aws --region "$REGION" ec2 "$@"; }

case "${1:-}" in
  start)
    aws_ec2 start-instances --instance-ids "$ID" > /dev/null
    aws_ec2 wait instance-running --instance-ids "$ID"
    aws_ec2 wait instance-status-ok --instance-ids "$ID"
    echo "Instance demarree : $(tf_out public_ip)"
    ;;
  stop)
    aws_ec2 stop-instances --instance-ids "$ID" > /dev/null
    aws_ec2 wait instance-stopped --instance-ids "$ID"
    echo "Instance arretee."
    ;;
  status)
    aws_ec2 describe-instances --instance-ids "$ID" \
      --query 'Reservations[0].Instances[0].State.Name' --output text
    ;;
  ip)
    tf_out public_ip
    ;;
  *)
    echo "Usage : $0 {start|stop|status|ip}" >&2
    exit 2
    ;;
esac
