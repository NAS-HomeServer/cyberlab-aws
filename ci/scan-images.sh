#!/usr/bin/env bash
# Scanne avec Trivy toutes les images des manifestes rendus (production + monitoring).
# Informatif : ecrit un tableau Markdown dans le fichier donne (ou stdout) et ne
# fait jamais echouer le script. Voir docs/notes-projet.md pour la decision.
# Usage : ci/scan-images.sh <dossier des rendus> [fichier-de-sortie.md]
set -euo pipefail
RENDER_DIR="${1:?dossier des rendus attendu}"
OUT="${2:-/dev/stdout}"
TRIVY_IMAGE="ghcr.io/aquasecurity/trivy:0.76.1@sha256:790fd66d1697395d8693d1acaa1ea702406a20f109b6fc7bac8db623eca6c06c"

IMAGES="$(grep -hoE 'image: [^ ]+@sha256:[a-f0-9]{64}' "$RENDER_DIR"/cyberlab-production.yaml "$RENDER_DIR"/monitoring-aws.yaml | awk '{print $2}' | sort -u)"
mkdir -p "${TRIVY_CACHE:-$HOME/.cache/trivy}"
{
  echo "| Image | HIGH | CRITICAL |"
  echo "|---|---|---|"
} > "$OUT"
for IMG in $IMAGES; do
  JSON="$(docker run --rm -v "${TRIVY_CACHE:-$HOME/.cache/trivy}":/root/.cache/ "$TRIVY_IMAGE" image \
    --platform linux/amd64 --severity HIGH,CRITICAL --ignore-unfixed --quiet --format json "$IMG" 2>/dev/null || echo '{}')"
  COUNTS="$(printf '%s' "$JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
v = [x for r in d.get("Results", []) for x in (r.get("Vulnerabilities") or [])]
print(sum(1 for x in v if x["Severity"] == "HIGH"), sum(1 for x in v if x["Severity"] == "CRITICAL"))' 2>/dev/null || echo '? ?')"
  echo "| \`${IMG%%@*}\` | ${COUNTS% *} | ${COUNTS#* } |" >> "$OUT"
done
