#!/usr/bin/env bash
# Test GitOps sur kind, sans aucun appel a AWS : Argo CD (meme version et meme empreinte que le
# bootstrap) deploie l'overlay "kind" DEPUIS GITHUB, puis on verifie :
#   1. l'Application passe Synced et les backends sont disponibles ;
#   2. selfHeal : une modification faite a la main est annulee par Argo CD ;
#   3. une ressource supprimee a la main est recreee.
# La revision suivie doit exister sur GitHub (Argo CD la clone) : branche poussee ou tag.
# Usage : k8s/kind/test-argocd.sh [revision]   (defaut : branche courante)
#         k8s/kind/test-argocd.sh --cleanup
set -euo pipefail
CLUSTER=cyberlab-argocd
CTX="kind-$CLUSTER"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
K="kubectl --context $CTX"

if [ "${1:-}" = "--cleanup" ]; then kind delete cluster --name "$CLUSTER"; exit 0; fi

REVISION="${1:-$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)}"
REPO_URL="${REPO_URL:-$(git -C "$REPO_ROOT" remote get-url origin)}"
git ls-remote --exit-code "$REPO_URL" "$REVISION" > /dev/null \
  || { echo "ECHEC : la revision '$REVISION' n'existe pas sur $REPO_URL (pousser la branche d'abord)"; exit 1; }

# Memes version et empreinte que le bootstrap de l'instance : une seule source de verite.
pin() { grep -E "^$1=" "$REPO_ROOT/scripts/bootstrap-node.sh" | head -1 | cut -d'"' -f2; }
ARGOCD_VERSION="$(pin ARGOCD_VERSION)"
ARGOCD_SHA256="$(pin ARGOCD_SHA256)"

kind get clusters | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --config "$ROOT/kind/kind-config.yaml"

echo "== Argo CD $ARGOCD_VERSION"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl -fsSL --retry 3 -o "$tmp" "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml"
echo "$ARGOCD_SHA256  $tmp" | shasum -a 256 -c -
$K create namespace argocd --dry-run=client -o yaml | $K apply -f -
$K apply --server-side --force-conflicts -n argocd -f "$tmp"
$K -n argocd scale deployment argocd-dex-server argocd-notifications-controller --replicas=0
$K -n argocd rollout status deployment/argocd-server deployment/argocd-repo-server --timeout=300s
$K -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

echo "== Application (overlay kind, revision $REVISION)"
sed -E "s|^( *repoURL:).*|\1 $REPO_URL|; s|^( *targetRevision:).*|\1 $REVISION|; s|^( *path:).*|\1 k8s/cyberlab/overlays/kind|; s|^( *namespace: )cyberlab-staging|\1cyberlab-kind|; s|^( *name: )cyberlab-staging|\1cyberlab-kind|" \
  "$ROOT/argocd/applications/cyberlab-staging.yaml" | $K apply -f -

# Pas "Healthy" : sur kind les tunnels ont un faux token, ils ne peuvent jamais etre Ready
# (comme dans test.sh, on n'exige que les backends).
echo "== Attente Synced puis backends disponibles (max 6 min)"
for _ in $(seq 1 72); do
  sync="$($K -n argocd get application cyberlab-kind -o jsonpath='{.status.sync.status}' 2> /dev/null || true)"
  [ "$sync" = "Synced" ] && break
  sleep 5
done
echo "sync=$sync"
if [ "$sync" != "Synced" ]; then
  echo "ECHEC : l'Application n'est pas Synced"
  exit 1
fi
$K -n cyberlab-kind wait --for=condition=Available deploy/sherlock deploy/dns-analyzer deploy/audit-orchestrator --timeout=300s
echo "OK deploiement par Argo CD"

echo "== selfHeal : on passe sherlock a 2 replicas a la main, Argo CD doit revenir a 1"
$K -n cyberlab-kind scale deploy/sherlock --replicas=2
ok=0
for _ in $(seq 1 30); do
  r="$($K -n cyberlab-kind get deploy sherlock -o jsonpath='{.spec.replicas}')"
  [ "$r" = "1" ] && { ok=1; break; }
  sleep 3
done
[ "$ok" = 1 ] || { echo "ECHEC : selfHeal n'a pas annule la modification (replicas=$r)"; exit 1; }
echo "OK selfHeal"

echo "== Suppression a la main de audit-orchestrator : Argo CD doit le recreer"
$K -n cyberlab-kind delete deploy audit-orchestrator
ok=0
for _ in $(seq 1 30); do
  $K -n cyberlab-kind get deploy audit-orchestrator > /dev/null 2>&1 && { ok=1; break; }
  sleep 3
done
[ "$ok" = 1 ] || { echo "ECHEC : deployment non recree"; exit 1; }
$K -n cyberlab-kind wait --for=condition=Available deploy/audit-orchestrator --timeout=120s
echo "OK recreation"
echo "TOUT EST OK"
