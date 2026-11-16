#!/usr/bin/env bash
# Gestion des secrets chiffres avec SOPS + age.
#   keygen            genere la cle age (si absente) et la reference dans .sops.yaml
#   init <env>        cree secrets/<env>/*.sops.yaml depuis les modeles, chiffres
#   edit <env> <nom>  ouvre un secret dechiffre dans $EDITOR, rechiffre a l'enregistrement
#   apply <env>       dechiffre et applique les Secrets dans le namespace cyberlab-<env>
# <env> : staging | production.  Prerequis : sops, age, kubectl (pour apply).
# Variable optionnelle KUBE_CONTEXT : contexte kubectl cible (defaut : le contexte courant).
# La cle privee est lue dans $SOPS_AGE_KEY_FILE (defaut : ~/.config/sops/age/keys.txt).
# Elle ne doit JAMAIS etre commitee.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECRETS_DIR="${SECRETS_DIR:-$ROOT/secrets}"
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
PLACEHOLDER="age1REMPLACER_PAR_VOTRE_CLE_PUBLIQUE"
kc() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

die() { echo "Erreur : $*" >&2; exit 1; }
check_env() { case "${1:-}" in staging | production | kind) ;; *) die "environnement attendu : staging ou production" ;; esac; }

case "${1:-}" in
  keygen)
    if [ -f "$SOPS_AGE_KEY_FILE" ]; then
      echo "Cle existante conservee : $SOPS_AGE_KEY_FILE"
    else
      mkdir -p "$(dirname "$SOPS_AGE_KEY_FILE")"
      age-keygen -o "$SOPS_AGE_KEY_FILE" 2> /dev/null
      chmod 600 "$SOPS_AGE_KEY_FILE"
      echo "Cle privee creee : $SOPS_AGE_KEY_FILE"
      echo ">>> SAUVEGARDEZ-LA maintenant (gestionnaire de mots de passe) : sans elle, les secrets du depot sont perdus."
    fi
    PUB="$(age-keygen -y "$SOPS_AGE_KEY_FILE")"
    sed -i.bak -E "s|age: age1[A-Za-z0-9_]+|age: $PUB|" "$ROOT/.sops.yaml" && rm -f "$ROOT/.sops.yaml.bak"
    echo "Cle publique ecrite dans .sops.yaml : $PUB"
    ;;
  init)
    check_env "${2:-}"
    grep -q "$PLACEHOLDER" "$ROOT/.sops.yaml" && die "lancez d'abord : scripts/secrets.sh keygen"
    mkdir -p "$SECRETS_DIR/$2"
    for tpl in "$SECRETS_DIR"/templates/*.yaml; do
      out="$SECRETS_DIR/$2/$(basename "${tpl%.yaml}").sops.yaml"
      [ -e "$out" ] && { echo "existe deja, ignore : $out"; continue; }
      sed "s/cyberlab-ENV/cyberlab-$2/" "$tpl" > "$out"
      (cd "$ROOT" && sops --encrypt --in-place "$out")
      echo "cree : $out"
    done
    echo "Etape suivante : scripts/secrets.sh edit $2 <nom> pour remplacer CHANGEME par les vraies valeurs."
    ;;
  edit)
    check_env "${2:-}"
    [ -n "${3:-}" ] || die "usage : edit <env> <nom>"
    (cd "$ROOT" && sops "$SECRETS_DIR/$2/$3.sops.yaml")
    ;;
  apply)
    check_env "${2:-}"
    ns="cyberlab-$2"
    kc create namespace "$ns" --dry-run=client -o yaml | kc apply -f - > /dev/null
    shopt -s nullglob
    files=("$SECRETS_DIR/$2"/*.sops.yaml)
    [ ${#files[@]} -gt 0 ] || die "aucun secret dans $SECRETS_DIR/$2"
    for f in "${files[@]}"; do
      sops --decrypt "$f" | kc apply -f -
    done
    ;;
  *)
    echo "Usage : $0 {keygen | init <env> | edit <env> <nom> | apply <env>}" >&2
    exit 2
    ;;
esac
