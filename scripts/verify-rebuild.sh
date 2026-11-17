#!/usr/bin/env bash
# Verifie, depuis le poste, qu'une instance (neuve apres un "terraform apply", ou redemarree) est
# entierement fonctionnelle : bootstrap termine, K3s, Argo CD, 3 applications, 12 pods, secrets,
# lien Tailscale et metriques recues par le Prometheus du NAS.
# Les controles s'executent sur l'instance (SSH) ; chacun reessaie jusqu'a son delai : on peut
# donc lancer ce script des la fin du "terraform apply", sans attendre a la main.
# Code de sortie 0 = tout est OK, 1 = au moins un controle a echoue.
# Usage : scripts/verify-rebuild.sh [adresse-ip]     (defaut : sortie Terraform "public_ip")
# Variables : SSH_KEY (defaut ~/.ssh/cyberlab-aws), NAS_PROM (defaut http://100.104.202.81:9090)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/cyberlab-aws}"
NAS_PROM="${NAS_PROM:-http://100.104.202.81:9090}"
IP="${1:-$(terraform -chdir="$ROOT/terraform/main" output -raw public_ip)}"

echo "== Verification de l'instance $IP"
# Premiere connexion : cloud-init est peut-etre encore en cours, sshd aussi.
for _ in $(seq 1 30); do
  ssh -i "$SSH_KEY" -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "ubuntu@$IP" true 2> /dev/null && break
  sleep 10
done

# Le corps ci-dessous est envoye tel quel a l'instance (heredoc entre apostrophes : aucune
# expansion ici). NAS_PROM est passe en argument.
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "ubuntu@$IP" sudo bash -s -- "$NAS_PROM" << 'REMOTE'
set -uo pipefail
NAS_PROM="$1"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fail=0

# check "libelle" delai-en-secondes commande... : reessaie toutes les 10 s jusqu'au delai.
check() {
  local label="$1" limit="$2" waited=0
  shift 2
  until "$@" > /dev/null 2>&1; do
    waited=$((waited + 10))
    if [ "$waited" -ge "$limit" ]; then
      echo "  KO  $label"
      fail=1
      return
    fi
    sleep 10
  done
  echo "  OK  $label"
}

bootstrap_done() { [ -f /var/lib/cyberlab-bootstrap.done ] && tail -3 /var/log/cyberlab-bootstrap.log | grep -q "Bootstrap termine"; }
node_ready() { kubectl wait --for=condition=Ready node --all --timeout=5s; }
app_ok() {
  [ "$(kubectl -n argocd get application "$1" -o jsonpath='{.status.sync.status}/{.status.health.status}')" = "Synced/Healthy" ]
}
ns_ok() {  # 6 deployments (3 backends + 3 tunnels), tous disponibles, secrets presents
  [ "$(kubectl -n "$1" get deploy --no-headers | wc -l)" -eq 6 ] \
    && kubectl -n "$1" wait --for=condition=Available deploy --all --timeout=5s \
    && [ "$(kubectl -n "$1" get secret --no-headers | wc -l)" -ge 1 ]
}
age_key_gone() { [ ! -e /root/.config/sops/age/keys.txt ]; }
tailscale_up() { tailscale status > /dev/null; }
nas_healthy() { [ "$(curl -fsS --max-time 5 "$NAS_PROM/-/healthy")" != "" ]; }
nas_jobs() {  # nombre de jobs aws-* qui envoient des series a jour (up == 1) : 6 attendus
  local n
  n="$(curl -fsS --max-time 10 -G "$NAS_PROM/api/v1/query" \
    --data-urlencode 'query=count(count by (job) (up{cluster="aws-k3s"} == 1))' \
    | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else 0)')"
  [ "$n" -ge 6 ]
}

echo "-- Instance"
check "cloud-init et bootstrap termines (/var/lib/cyberlab-bootstrap.done)" 900 bootstrap_done
check "noeud K3s Ready" 120 node_ready
echo "-- GitOps"
check "Argo CD : application cyberlab-staging Synced/Healthy" 600 app_ok cyberlab-staging
check "Argo CD : application cyberlab-production Synced/Healthy" 600 app_ok cyberlab-production
check "Argo CD : application monitoring Synced/Healthy" 600 app_ok monitoring
echo "-- Applications"
check "cyberlab-staging : 6 deployments disponibles, secrets presents" 300 ns_ok cyberlab-staging
check "cyberlab-production : 6 deployments disponibles, secrets presents" 300 ns_ok cyberlab-production
check "cle age supprimee du disque apres le bootstrap" 10 age_key_gone
echo "-- Supervision"
check "Tailscale connecte" 60 tailscale_up
check "Prometheus du NAS joignable depuis l'instance ($NAS_PROM)" 60 nas_healthy
check "NAS : les 6 jobs aws-* envoient des series a jour" 300 nas_jobs

echo
if [ "$fail" -eq 0 ]; then echo "TOUT EST OK : la reconstruction est complete."; else echo "ECHEC : voir les lignes KO (journal : /var/log/cyberlab-bootstrap.log)."; fi
exit "$fail"
REMOTE
