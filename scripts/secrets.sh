#!/usr/bin/env bash
# Gestion des secrets chiffres avec SOPS + age.
#   keygen            genere la cle age (si absente) et la reference dans .sops.yaml
#   init <env>        cree secrets/<env>/*.sops.yaml depuis les modeles, chiffres
#   set <env> <nom> <CLE> [--clipboard]
#                     renseigne UNE valeur sans editeur : saisie masquee, ou presse-papiers
#                     (macOS) avec --clipboard, qui est vide apres usage
#   edit <env> <nom>  ouvre un secret dechiffre dans $EDITOR, rechiffre a l'enregistrement
#   check <env>       compte les CHANGEME restants par fichier (0 partout = pret)
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
    echo "Etape suivante : scripts/secrets.sh set $2 <nom> <CLE> pour chaque valeur (ou edit pour tout un fichier)."
    ;;
  set)
    check_env "${2:-}"
    if [ -z "${3:-}" ] || [ -z "${4:-}" ]; then die "usage : set <env> <nom> <CLE> [--clipboard]"; fi
    file="$SECRETS_DIR/$2/$3.sops.yaml"
    [ -f "$file" ] || die "introuvable : $file (lancez d'abord : init $2)"
    if [ "${5:-}" = "--clipboard" ]; then
      value="$(pbpaste)"
      printf '' | pbcopy
      echo "Valeur lue dans le presse-papiers (qui vient d'etre vide)."
    else
      read -rsp "Valeur de $4 (invisible) : " value
      echo
    fi
    [ -n "$value" ] || die "valeur vide, rien n'a ete modifie"
    # La valeur passe par l'entree standard (jamais dans la liste des processus) en JSON.
    printf '%s' "$value" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' \
      | (cd "$ROOT" && sops set --value-stdin "$file" "[\"stringData\"][\"$4\"]")
    echo "OK : $4 mis a jour dans $file"
    ;;
  edit)
    check_env "${2:-}"
    [ -n "${3:-}" ] || die "usage : edit <env> <nom>"
    (cd "$ROOT" && sops "$SECRETS_DIR/$2/$3.sops.yaml")
    ;;
  check)
    check_env "${2:-}"
    shopt -s nullglob
    files=("$SECRETS_DIR/$2"/*.sops.yaml)
    if [ ${#files[@]} -eq 0 ]; then die "aucun secret dans $SECRETS_DIR/$2"; fi
    total=0
    for f in "${files[@]}"; do
      n="$(sops --decrypt "$f" | grep -c CHANGEME || true)"
      printf '%s : %s\n' "$(basename "$f")" "$n"
      total=$((total + n))
    done
    if [ "$total" -ne 0 ]; then echo "$total valeur(s) a renseigner."; exit 1; fi
    echo "Pret : aucun CHANGEME."
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
    echo "Usage : $0 {keygen | init <env> | set <env> <nom> <CLE> [--clipboard] | edit <env> <nom> | check <env> | apply <env>}" >&2
    exit 2
    ;;
esac
