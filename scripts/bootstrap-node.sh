#!/usr/bin/env bash
# Bootstrap du noeud : lance UNE FOIS, au premier demarrage, par cloud-init (user_data Terraform).
# Resultat : K3s + Argo CD installes, secrets chiffres dechiffres et appliques dans le cluster,
# Applications Argo CD creees : backends, tunnels et supervision se deploient depuis Git.
# Aucune intervention manuelle. Journal : /var/log/cyberlab-bootstrap.log
#
# Variables attendues (ecrites en tete du user_data par Terraform) :
#   REPO_URL, REPO_REF   depot public a cloner et sa reference (branche ou tag)
#   AWS_REGION           region AWS (lecture de la cle age)
#   AGE_PARAM            nom du parametre SSM SecureString qui contient la cle privee age
#   TS_PARAM             nom du parametre SSM SecureString qui contient la cle d'authentification Tailscale
#                        (optionnel : absent, l'instance demarre sans lien vers le NAS)
#   TS_OAUTH_PARAM       (optionnel) parametre SSM "client_id:client_secret" d'un client OAuth Tailscale (scope
#                        devices:core ecriture) : sert a supprimer les anciens noeuds cyberlab-aws avant de rejoindre
#
# Tout ce qui est telecharge est epingle par version ET verifie par empreinte SHA-256 :
# une release modifiee apres coup fait echouer le bootstrap au lieu de s'executer.
set -euo pipefail

: "${REPO_URL:?}" "${REPO_REF:?}" "${AWS_REGION:?}" "${AGE_PARAM:?}" "${TS_PARAM:?}"
TS_OAUTH_PARAM="${TS_OAUTH_PARAM:-}"

K3S_VERSION="v1.33.13+k3s1"
K3S_INSTALL_SHA256="9ca7930c31179d83bc13de20078fd8ad3e1ee00875b31f39a7e524ca4ef7d9de"
ARGOCD_VERSION="v3.6.1"
ARGOCD_SHA256="7be23ca7d9ca3d3074dee8332f1ca92a933b990cee7c9cf22cf3843ee8c2913e"
SOPS_VERSION="v3.13.3"
SOPS_SHA256="e5bec3346a873ae91d871550f3e698c1aad962aff462a080e40f25fde17fef6b"
TAILSCALE_VERSION="1.104.7"
TAILSCALE_SHA256="e56693ff74a64f2591b7e819c280635a100aae1ddfb0ef058fcd052b7cd8d16c"

LOG=/var/log/cyberlab-bootstrap.log
DONE=/var/lib/cyberlab-bootstrap.done
exec > >(tee -a "$LOG") 2>&1
log() { echo "[$(date -u +%H:%M:%S)] $*"; }

if [ -f "$DONE" ]; then
  log "Bootstrap deja effectue, rien a faire."
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Les telechargements et apt peuvent echouer au demarrage du reseau : 5 essais.
retry() {
  local n
  for n in 1 2 3 4 5; do
    "$@" && return 0
    log "echec ($n/5) : $*"
    sleep $((n * 5))
  done
  return 1
}

# Telecharge $1 vers $2 et refuse le fichier si son SHA-256 n'est pas $3.
fetch() {
  retry curl -fsSL --retry 3 -o "$2" "$1"
  echo "$3  $2" | sha256sum -c -
}

log "1/8 Paquets de base"
retry apt-get update -qq
retry apt-get install -y -qq git curl jq ca-certificates

log "2/8 AWS CLI (lecture de la cle age dans SSM)"
command -v aws > /dev/null || retry snap install aws-cli --classic

log "3/8 SOPS $SOPS_VERSION"
fetch "https://github.com/getsops/sops/releases/download/$SOPS_VERSION/sops-$SOPS_VERSION.linux.amd64" "$WORK/sops" "$SOPS_SHA256"
install -m 0755 "$WORK/sops" /usr/local/bin/sops

log "4/8 K3s $K3S_VERSION"
# Sans traefik (pas d'ingress : le trafic arrive par les tunnels cloudflared), sans servicelb
# ni metrics-server : memoire economisee sur une petite instance.
fetch "https://raw.githubusercontent.com/k3s-io/k3s/${K3S_VERSION/+/%2B}/install.sh" "$WORK/k3s-install.sh" "$K3S_INSTALL_SHA256"
INSTALL_K3S_VERSION="$K3S_VERSION" INSTALL_K3S_EXEC="server --disable=traefik --disable=servicelb --disable=metrics-server" sh "$WORK/k3s-install.sh"
for _ in $(seq 1 60); do
  kubectl wait --for=condition=Ready node --all --timeout=10s > /dev/null 2>&1 && break
  sleep 5
done
kubectl wait --for=condition=Ready node --all --timeout=10s

log "5/8 Argo CD $ARGOCD_VERSION"
fetch "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml" "$WORK/argocd.yaml" "$ARGOCD_SHA256"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
# server-side : les CRD d'Argo CD depassent la taille acceptee par un apply classique.
kubectl apply --server-side --force-conflicts -n argocd -f "$WORK/argocd.yaml"
# Dex (SSO) et les notifications ne servent a rien ici : on libere de la memoire.
kubectl -n argocd scale deployment argocd-dex-server argocd-notifications-controller --replicas=0
kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=300s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

log "6/8 Secrets (cle age lue dans SSM, jamais ecrite dans le depot)"
rm -rf /opt/cyberlab-aws
retry git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" /opt/cyberlab-aws
export SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt
mkdir -p "$(dirname "$SOPS_AGE_KEY_FILE")"
umask 077
retry aws --region "$AWS_REGION" ssm get-parameter --name "$AGE_PARAM" --with-decryption \
  --query Parameter.Value --output text > "$SOPS_AGE_KEY_FILE"
for env in staging production; do
  /opt/cyberlab-aws/scripts/secrets.sh check "$env"
  /opt/cyberlab-aws/scripts/secrets.sh apply "$env"
done
# Les Secrets vivent desormais dans le cluster : la cle privee n'a plus de raison de rester sur le disque.
shred -u "$SOPS_AGE_KEY_FILE"

log "7/8 Tailscale $TAILSCALE_VERSION (lien prive vers le NAS pour le remote_write)"
# Cle d'authentification : parametre SSM cree a la main, jamais dans le depot. Sans elle, on continue :
# le cluster fonctionne, seule la supervision ne remonte pas au NAS.
if ts_key="$(aws --region "$AWS_REGION" ssm get-parameter --name "$TS_PARAM" --with-decryption --query Parameter.Value --output text 2> /dev/null)"; then
  fetch "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_amd64.tgz" "$WORK/tailscale.tgz" "$TAILSCALE_SHA256"
  tar -xzf "$WORK/tailscale.tgz" -C "$WORK"
  ts_dir="$WORK/tailscale_${TAILSCALE_VERSION}_amd64"
  install -m 0755 "$ts_dir/tailscaled" /usr/sbin/tailscaled
  install -m 0755 "$ts_dir/tailscale" /usr/bin/tailscale
  install -m 0644 "$ts_dir/systemd/tailscaled.service" /etc/systemd/system/tailscaled.service
  install -m 0644 "$ts_dir/systemd/tailscaled.defaults" /etc/default/tailscaled
  systemctl daemon-reload
  # enable : tailscaled repart seul apres chaque arret/demarrage de l'instance (etat dans /var/lib/tailscale).
  systemctl enable --now tailscaled
  # Pas de DNS Tailscale (les pods gardent le DNS du cluster) ; etiquette pour limiter l'acces par ACL.
  # La cle passe par un fichier (--auth-key=file:...), pas par la ligne de commande, pour ne pas
  # apparaitre dans la liste des processus. Sans cle valable, "tailscale up" attendrait une
  # connexion interactive indefiniment : le delai evite de bloquer tout le bootstrap.
  # Une seule machine dans la console Tailscale : l'instance precedente (detruite) a laisse un noeud hors
  # ligne qui ferait nommer celui-ci cyberlab-aws-1. On le supprime via l'API avant de rejoindre.
  # Facultatif et jamais bloquant : sans client OAuth, ou en cas d'erreur, on continue (doublon cosmetique).
  if [ -n "$TS_OAUTH_PARAM" ] && ts_oauth="$(aws --region "$AWS_REGION" ssm get-parameter --name "$TS_OAUTH_PARAM" --with-decryption --query Parameter.Value --output text 2> /dev/null)"; then
    {
      printf 'data-urlencode = "client_id=%s"\n' "${ts_oauth%%:*}"
      printf 'data-urlencode = "client_secret=%s"\n' "${ts_oauth#*:}"
    } > "$WORK/ts-oauth"
    unset ts_oauth
    if ts_token="$(curl -fsS --max-time 20 -X POST https://api.tailscale.com/api/v2/oauth/token -d grant_type=client_credentials -K "$WORK/ts-oauth" | jq -r .access_token)" && [ -n "$ts_token" ] && [ "$ts_token" != null ]; then
      printf 'Authorization: Bearer %s\n' "$ts_token" > "$WORK/ts-hdr"
      unset ts_token
      if curl -fsS --max-time 20 -H @"$WORK/ts-hdr" https://api.tailscale.com/api/v2/tailnet/-/devices > "$WORK/ts-devices"; then
        # Uniquement les noeuds etiquetes tag:cyberlab-aws et nommes cyberlab-aws[-N] : rien d'autre n'est touche.
        for id in $(jq -r '.devices[] | select(.hostname | test("^cyberlab-aws(-[0-9]+)?$")) | select((.tags // []) | index("tag:cyberlab-aws")) | .id' "$WORK/ts-devices"); do
          log "Tailscale : suppression de l'ancien noeud $id"
          curl -fsS --max-time 20 -X DELETE -H @"$WORK/ts-hdr" "https://api.tailscale.com/api/v2/device/$id" || log "ATTENTION : suppression du noeud $id impossible."
        done
      else
        log "ATTENTION : liste des noeuds Tailscale indisponible, anciens noeuds conserves."
      fi
    else
      log "ATTENTION : jeton OAuth Tailscale refuse, anciens noeuds conserves."
    fi
    shred -u "$WORK/ts-oauth" "$WORK/ts-hdr" 2> /dev/null || true
  fi
  ts_keyfile="$WORK/tskey"
  printf '%s' "$ts_key" > "$ts_keyfile"
  unset ts_key
  if timeout 120 tailscale up --auth-key="file:$ts_keyfile" --hostname=cyberlab-aws --accept-dns=false --advertise-tags=tag:cyberlab-aws; then
    # Sans pipe vers head : avec pipefail, la fermeture anticipee du pipe (SIGPIPE) ferait echouer tout le script.
    tailscale status > "$WORK/ts-status" || true
    head -5 "$WORK/ts-status"
  else
    log "ATTENTION : Tailscale n'a pas pu rejoindre le reseau (cle refusee, expiree ou ACL) ; la supervision ne remontera pas au NAS."
  fi
  shred -u "$ts_keyfile"
else
  log "ATTENTION : parametre $TS_PARAM introuvable, Tailscale non installe (la supervision ne remontera pas au NAS)."
fi

log "8/8 Applications Argo CD (le deploiement est ensuite pilote par Git)"
# repoURL et targetRevision des Applications sont reecrits avec les variables Terraform,
# pour pouvoir tester une branche avant fusion (repo_ref).
for app in /opt/cyberlab-aws/k8s/argocd/applications/*.yaml; do
  sed -E "s|^( *repoURL:).*|\\1 $REPO_URL|; s|^( *targetRevision:).*|\\1 $REPO_REF|" "$app" | kubectl apply -f -
done
# La production n'a pas de synchronisation automatique : aucun deploiement n'est declenche ici,
# meme le premier. Elle reste OutOfSync (Missing) jusqu'au clic sur « Sync » dans Argo CD.
# Attente indicative (10 min max) : un echec ici (image, reseau) ne doit pas faire echouer le
# bootstrap, K3s et Argo CD sont installes ; l'etat se lit dans `kubectl -n argocd get applications`.
# cyberlab-production est exclue : elle n'est deployee qu'apres validation humaine.
for app in cyberlab-staging monitoring; do
  kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy "application/$app" --timeout=600s \
    || log "ATTENTION : $app n'est pas Healthy (voir : kubectl -n argocd get applications)"
done

touch "$DONE"
log "Bootstrap termine."
