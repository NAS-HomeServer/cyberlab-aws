#!/usr/bin/env bash
# Verifie la signature Cosign (sans cle, via OIDC GitHub) de chaque image backend
# referencee par digest dans les overlays staging et production.
# Identite attendue : le workflow ci.yml sur main du depot du backend.
# (?i) : le certificat garde la casse du compte GitHub, GHCR force les minuscules.
# Usage : ci/verify-signatures.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COSIGN_IMAGE="gcr.io/projectsigstore/cosign@sha256:9e5c2f2edc34351160407ca3416c61855bdf9403c3c5936e0f0be7fc261611b8"

# Paires "nom@digest" des images ghcr.io lues dans les kustomization.yaml des overlays.
IMAGES="$(awk '
  /- name: ghcr\.io\// { name = $3 }
  /digest: sha256:/    { if (name != "") { print name "@" $2; name = "" } }
' "$ROOT"/k8s/cyberlab/overlays/{staging,production}/kustomization.yaml | sort -u)"
[ -n "$IMAGES" ] || { echo "Aucune image ghcr.io trouvee dans les overlays"; exit 1; }

for IMG in $IMAGES; do
  REPO_PATH="${IMG%%@*}"
  REPO_PATH="${REPO_PATH#ghcr.io/}"
  echo "Verification : $IMG"
  docker run --rm "$COSIGN_IMAGE" verify \
    --certificate-identity-regexp "(?i)^https://github.com/${REPO_PATH}/\.github/workflows/ci\.yml@refs/heads/main\$" \
    --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
    "$IMG" > /dev/null
done
echo "Toutes les signatures sont valides."
