#!/usr/bin/env bash
# Fonctions partagees : lire et ecrire les digests d'images dans un kustomization.yaml
# (bloc "images:" de overlays/staging et overlays/production). A sourcer, pas a executer.

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
