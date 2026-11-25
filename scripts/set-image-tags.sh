#!/usr/bin/env bash
#
# Preenche as tags das imagens com o que esta publicado no registry.
#
#     bash scripts/set-image-tags.sh --dry-run
#     bash scripts/set-image-tags.sh
#
# Precisa de bash, curl, sed, awk e grep. Nada mais.
#
# As imagens nao estao escritas aqui: ele le os nomes do bloco images: do
# kustomization.yaml e da linha image: de cada arquivo *-job.yaml, entao
# acrescentar um servico nao exige mexer neste script.
#
# Para cada imagem, resolve a tag assim: pega o digest a que latest aponta e
# procura entre as outras tags qual tem o mesmo digest. Essa e a tag do build
# mais recente, e por ser o SHA do commit ela diz de onde o build veio -- o que
# um digest cru nao diria. Se nenhuma casar, avisa e nao mexe naquela imagem.

set -euo pipefail

dry=0
case "${1:-}" in
  --dry-run) dry=1 ;;
  "") ;;
  *) echo "uso: $0 [--dry-run]" >&2; exit 2 ;;
esac

for programa in curl sed awk grep; do
  command -v "$programa" > /dev/null || { echo "$programa nao encontrado" >&2; exit 1; }
done

raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
k8s="$raiz/kubernetes"
kz="$k8s/kustomization.yaml"
[ -f "$kz" ] || { echo "nao achei $kz" >&2; exit 1; }

accept='application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'

token_de() {
  curl -fsS --max-time 30 "https://ghcr.io/token?scope=repository:$1:pull" \
    | sed -n 's/.*"token":"\([^"]*\)".*/\1/p'
}

digest_de() {
  curl -sSI --max-time 30 \
    -H "Authorization: Bearer $3" -H "Accept: $accept" \
    "https://ghcr.io/v2/$1/manifests/$2" 2> /dev/null \
    | tr -d '\r' | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: //p'
}

tags_de() {
  curl -fsS --max-time 30 -H "Authorization: Bearer $2" \
    "https://ghcr.io/v2/$1/tags/list" \
    | sed 's/.*"tags":\[//; s/\].*//; s/"//g; s/,/ /g'
}

imagens_kz() {
  awk '
    /^[[:space:]]*-[[:space:]]*name:[[:space:]]*[^[:space:]]+[[:space:]]*$/ {
      nome = $NF
      if ((getline prox) > 0 && prox ~ /^[[:space:]]*(newTag|digest):/) print nome
    }' "$kz"
}

imagens_jobs() {
  find "$k8s" -name '*-job.yaml' -type f -exec \
    grep -h '^[[:space:]]*image:' {} + 2> /dev/null \
    | sed 's/^[[:space:]]*image:[[:space:]]*//; s/:[^:/]*$//'
}

todas=$( { imagens_kz; imagens_jobs; } | awk 'NF && !visto[$0]++' )
[ -n "$todas" ] || { echo "nao achei imagem nenhuma nos manifestos" >&2; exit 1; }

total=$(printf '%s\n' "$todas" | wc -l | tr -d ' ')
echo "$total imagens nos manifestos"
echo

antes=$(mktemp -d)
trap 'rm -rf "$antes"' EXIT
cp "$kz" "$antes/kustomization.yaml"
while IFS= read -r arquivo; do
  cp "$arquivo" "$antes/$(basename "$(dirname "$arquivo")")-$(basename "$arquivo")"
done < <(find "$k8s" -name '*-job.yaml' -type f)

resolvidas=0
falhas=()

while IFS= read -r imagem; do
  curto="${imagem##*/}"
  if [ "${imagem#ghcr.io/}" = "$imagem" ]; then
    falhas+=("$curto: nao esta no ghcr.io")
    printf '  %-34s -- nao esta no ghcr.io\n' "$curto"
    continue
  fi
  repo="${imagem#ghcr.io/}"

  if ! token=$(token_de "$repo" 2> /dev/null) || [ -z "$token" ]; then
    falhas+=("$curto: nao consegui token (privada? sem rede?)")
    printf '  %-34s -- sem token\n' "$curto"
    continue
  fi

  alvo=$(digest_de "$repo" latest "$token")
  if [ -z "$alvo" ]; then
    falhas+=("$curto: nao tem tag latest")
    printf '  %-34s -- sem tag latest\n' "$curto"
    continue
  fi

  achada=""
  candidatas=$(tags_de "$repo" "$token" 2> /dev/null || true)
  for tag in $candidatas; do
    [ "$tag" = latest ] && continue
    if [ "$(digest_de "$repo" "$tag" "$token")" = "$alvo" ]; then
      achada="$tag"
      break
    fi
  done

  if [ -z "$achada" ]; then
    falhas+=("$curto: nenhuma tag casa o digest de latest")
    printf '  %-34s -- nenhuma tag casa o digest de latest\n' "$curto"
    continue
  fi

  printf '  %-34s %s\n' "$curto" "$achada"
  resolvidas=$((resolvidas + 1))

  if [ "$dry" -eq 0 ]; then
    sed -i "/${curto}\$/{n;s|\(newTag:\) .*|\1 $achada|}" "$kz"
    while IFS= read -r arquivo; do
      sed -i "s|\(image:[[:space:]]*${imagem}\):[^[:space:]]*|\1:$achada|" "$arquivo"
    done < <(find "$k8s" -name '*-job.yaml' -type f)
  fi
done <<< "$todas"

echo
if [ "$dry" -eq 1 ]; then
  echo "dry-run: $resolvidas de $total imagens resolvidas, nada foi escrito"
else
  mudados=0
  cmp -s "$kz" "$antes/kustomization.yaml" || mudados=$((mudados + 1))
  while IFS= read -r arquivo; do
    guardado="$antes/$(basename "$(dirname "$arquivo")")-$(basename "$arquivo")"
    cmp -s "$arquivo" "$guardado" || mudados=$((mudados + 1))
  done < <(find "$k8s" -name '*-job.yaml' -type f)
  echo "$resolvidas de $total imagens resolvidas, $mudados arquivo(s) alterado(s)"
fi

if [ "${#falhas[@]}" -gt 0 ]; then
  echo
  echo "NAO RESOLVIDAS (${#falhas[@]}):"
  for falha in "${falhas[@]}"; do
    echo "  x $falha"
  done
  echo
  echo "Imagem sem latest ou privada precisa do CD rodado ou da visibilidade trocada."
  exit 1
fi
