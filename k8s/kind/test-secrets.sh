#!/usr/bin/env bash
# Teste la chaine SOPS + age de bout en bout dans un depot temporaire, avec une cle
# JETABLE (jamais la vraie) : keygen, init, edit, controle de chiffrement, apply sur kind,
# puis refus de dechiffrer avec une autre cle.
# Prerequis : age, sops, kubectl et le cluster cree par k8s/kind/test.sh.
# Usage : k8s/kind/test-secrets.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CTX="kind-cyberlab-test"
TMP="$(mktemp -d)"
trap 'kubectl --context "$CTX" delete namespace cyberlab-staging --ignore-not-found > /dev/null; rm -rf "$TMP"' EXIT

# Copie minimale du depot : le script, les modeles, la configuration SOPS.
mkdir -p "$TMP/scripts" "$TMP/secrets" "$TMP/ci"
cp "$ROOT/scripts/secrets.sh" "$TMP/scripts/"
cp "$ROOT/ci/check-secrets-encrypted.sh" "$TMP/ci/"
cp -r "$ROOT/secrets/templates" "$TMP/secrets/"
cp "$ROOT/.sops.yaml" "$TMP/.sops.yaml"
export SOPS_AGE_KEY_FILE="$TMP/key.txt"
S="$TMP/scripts/secrets.sh"
export KUBE_CONTEXT="$CTX"

echo "== keygen";  "$S" keygen
echo "== init staging";  "$S" init staging > /dev/null
echo "== edit : remplace CHANGEME par une valeur de test"
for f in "$TMP"/secrets/staging/*.sops.yaml; do
  name="$(basename "${f%.sops.yaml}")"
  EDITOR="sed -i.bak s/CHANGEME/valeur-de-test-$name/" "$S" edit staging "$name"
  rm -f "$f.bak"
done
echo "== set : une valeur par saisie masquee"
printf 'valeur-set-masquee\n' | "$S" set staging cloudflared-sherlock TUNNEL_TOKEN > /dev/null
[ "$(sops --decrypt "$TMP/secrets/staging/cloudflared-sherlock.sops.yaml" | awk '/TUNNEL_TOKEN/{print $2}')" = "valeur-set-masquee" ] || { echo "ECHEC : set"; exit 1; }
echo "set : OK"
echo "== controle : aucune valeur en clair dans les fichiers"
! grep -rq 'valeur-de-test' "$TMP/secrets/staging" || { echo "ECHEC : valeur en clair"; exit 1; }
"$TMP/ci/check-secrets-encrypted.sh"
echo "== apply sur kind"
"$S" apply staging > /dev/null
got="$(kubectl --context "$CTX" -n cyberlab-staging get secret cloudflared-dns -o jsonpath='{.data.TUNNEL_TOKEN}' | base64 -d)"
[ "$got" = "valeur-de-test-cloudflared-dns" ] || { echo "ECHEC : valeur dechiffree inattendue : $got"; exit 1; }
echo "valeur retrouvee dans le cluster : OK"
echo "== une autre cle ne dechiffre pas"
age-keygen -o "$TMP/autre.txt" 2> /dev/null
if SOPS_AGE_KEY_FILE="$TMP/autre.txt" sops --decrypt "$TMP/secrets/staging/cloudflared-dns.sops.yaml" > /dev/null 2>&1; then
  echo "ECHEC : dechiffre avec une mauvaise cle"; exit 1
fi
echo "refus avec une autre cle : OK"
echo "TEST SECRETS OK"
