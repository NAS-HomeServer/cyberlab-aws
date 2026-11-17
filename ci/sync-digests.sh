#!/usr/bin/env bash
# Aligne les digests d'images de STAGING sur ceux de cyberlab-infra (docker-compose.yml de la
# production NAS), qui sont mis a jour par les PR "bump/*" des depots de backends.
# Lecture seule sur cyberlab-infra. La production, elle, n'est jamais modifiee ici : elle
# recoit les digests par promotion (scripts/promote.sh).
# Usage : ci/sync-digests.sh [fichier-compose]   (defaut : telecharge celui de cyberlab-infra, branche main)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib-digests.sh
. "$ROOT/scripts/lib-digests.sh"
STAGING="$ROOT/k8s/cyberlab/overlays/staging/kustomization.yaml"
COMPOSE_URL="https://raw.githubusercontent.com/NAS-HomeServer/cyberlab-infra/main/cyberlab/docker-compose.yml"

compose="${1:-}"
if [ -z "$compose" ]; then
  compose="$(mktemp)"
  trap 'rm -f "$compose"' EXIT
  curl -fsSL --retry 3 -o "$compose" "$COMPOSE_URL"
fi

changed=0
while read -r image current; do
  new="$(grep -oE "image: ${image}@sha256:[0-9a-f]{64}" "$compose" | head -1 | grep -oE 'sha256:[0-9a-f]{64}' || true)"
  if [ -z "$new" ]; then
    echo "Erreur : $image absent du compose (renommage ?)" >&2
    exit 1
  fi
  if [ "$new" != "$current" ]; then
    set_digest "$STAGING" "$image" "$new"
    echo "$image : $current -> $new"
    changed=1
  fi
done < <(get_digests "$STAGING")

[ "$changed" = 1 ] || echo "Staging deja aligne sur cyberlab-infra."
