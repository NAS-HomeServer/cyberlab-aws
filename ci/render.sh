#!/usr/bin/env bash
# Rend chaque overlay Kustomize en un fichier YAML (celui que le cluster recevra).
# Les validateurs (kubeconform, trivy) travaillent sur ces fichiers, pas sur les sources.
# Usage : ci/render.sh <dossier de sortie>
set -euo pipefail
OUT="${1:?dossier de sortie attendu}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$OUT"
for overlay in "$ROOT"/k8s/cyberlab/overlays/* "$ROOT"/k8s/monitoring/overlays/*; do
  name="$(basename "$(dirname "$(dirname "$overlay")")")-$(basename "$overlay")"
  kubectl kustomize "$overlay" > "$OUT/$name.yaml"
  echo "rendu : $name"
done
