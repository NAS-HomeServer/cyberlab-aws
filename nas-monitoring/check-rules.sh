#!/usr/bin/env bash
# Valide les regles d'alerte du NAS : syntaxe (promtool check rules) puis tests unitaires
# (promtool test rules). Aucun acces reseau, aucun appel a AWS.
# Usage : nas-monitoring/check-rules.sh
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
PROM_IMAGE="prom/prometheus:v3.15.0@sha256:efd719c99d83b060d9daefdcf00360461adf279f45ef5391f8d111892118753e"
docker run --rm --entrypoint promtool -v "$DIR":/r:ro "$PROM_IMAGE" check rules /r/cyberlab-aws.rules.yml
docker run --rm --entrypoint promtool -v "$DIR":/r:ro "$PROM_IMAGE" test rules /r/cyberlab-aws.test.yml
