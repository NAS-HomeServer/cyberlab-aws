#!/usr/bin/env bash
# Promotion staging -> production : copie les digests d'images valides en staging vers la
# production. Ne fait AUCUN appel reseau ni commit : on relit le diff, on ouvre une PR, et
# c'est la fusion de cette PR qui declenche le deploiement (Argo CD).
# Usage : scripts/promote.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGING="$ROOT/k8s/cyberlab/overlays/staging/kustomization.yaml"
PROD="$ROOT/k8s/cyberlab/overlays/production/kustomization.yaml"

# get_digests <kustomization.yaml> : affiche "<image> <digest>" par ligne.
get_digests() {
  awk '
    /^[[:space:]]*- name:[[:space:]]/ { name = $3; next }
    /^[[:space:]]*digest:[[:space:]]*sha256:/ && name != "" { print name, $2; name = "" }
  ' "$1"
}

# set_digest <kustomization.yaml> <image> <digest> : remplace le digest de cette image.
set_digest() {
  local file="$1" image="$2" digest="$3" tmp
  tmp="$(mktemp)"
  awk -v img="$image" -v dig="$digest" '
    /^[[:space:]]*- name:[[:space:]]/ { cur = $3 }
    /^[[:space:]]*digest:[[:space:]]*sha256:/ && cur == img { sub(/sha256:[0-9a-f]+/, dig); done = 1 }
    { print }
    END { if (!done) exit 3 }
  ' "$file" > "$tmp" || {
    rm -f "$tmp"
    echo "image introuvable dans $file : $image" >&2
    return 1
  }
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

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
