#!/usr/bin/env bash
# Garde-fou : tout fichier de secrets/<env>/ doit etre chiffre par SOPS (bloc "sops:"
# present, valeurs sous forme ENC[...]). Evite de committer un secret en clair par erreur.
# Les modeles (secrets/templates/) contiennent volontairement des valeurs factices.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
status=0
shopt -s nullglob
for f in "$ROOT"/secrets/staging/* "$ROOT"/secrets/production/*; do
  case "$(basename "$f")" in .gitkeep) continue ;; esac
  case "$f" in *.sops.yaml) ;; *) echo "ECHEC : $f n'est pas un fichier *.sops.yaml"; status=1; continue ;; esac
  if ! grep -q '^sops:' "$f"; then echo "ECHEC : $f n'est pas chiffre (pas de bloc sops:)"; status=1; continue; fi
  # Toute valeur sous stringData/data doit etre chiffree.
  if awk '/^(stringData|data):/{in_s=1; next} /^[^ ]/{in_s=0} in_s && NF && $2 !~ /^ENC\[/ {bad=1} END{exit !bad}' "$f"; then
    echo "ECHEC : $f contient une valeur non chiffree"; status=1
  fi
done
[ "$status" -eq 0 ] && echo "Secrets : tous chiffres."
exit "$status"
