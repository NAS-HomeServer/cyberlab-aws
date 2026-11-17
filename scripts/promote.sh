#!/usr/bin/env bash
# Promotion staging -> production : copie les digests d'images valides en staging vers la
# production. Ne fait AUCUN appel reseau ni commit : on relit le diff, on ouvre une PR, et
# c'est la fusion de cette PR qui declenche le deploiement (Argo CD).
# Usage : scripts/promote.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib-digests.sh
. "$ROOT/scripts/lib-digests.sh"
STAGING="$ROOT/k8s/cyberlab/overlays/staging/kustomization.yaml"
PROD="$ROOT/k8s/cyberlab/overlays/production/kustomization.yaml"

changed=0
while read -r image digest; do
  current="$(get_digests "$PROD" | awk -v i="$image" '$1 == i { print $2 }')"
  if [ "$current" = "$digest" ]; then
    echo "inchange : $image"
  else
    set_digest "$PROD" "$image" "$digest"
    echo "promu    : $image"
    echo "           ${current:-<aucun>} -> $digest"
    changed=1
  fi
done < <(get_digests "$STAGING")

if [ "$changed" = 0 ]; then
  echo "Production deja alignee sur staging."
else
  echo
  echo "Verifier : git diff k8s/cyberlab/overlays/production"
  echo "Puis : branche, commit, PR vers main. Retour arriere : git revert de la fusion."
fi
