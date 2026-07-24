#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
RELEASE_TAG="${RELEASE_TAG:-Latest}"
REPOSITORY="${GITHUB_REPOSITORY:-zarpon/Turbo-Decky-}"
CANONICAL_IMAGE="$DIST_DIR/TurboDecky-x86_64.AppImage"
CANONICAL_SHA="$CANONICAL_IMAGE.sha256"

source_image="$(find "$DIST_DIR" -maxdepth 1 -type f \
  -name 'TurboDecky-*-x86_64.AppImage' \
  ! -name 'TurboDecky-x86_64.AppImage' -print -quit)"
[[ -n "$source_image" && -x "$source_image" ]] || {
  printf 'AppImage versionado não encontrado em %s\n' "$DIST_DIR" >&2
  exit 1
}

install -m 0755 "$source_image" "$CANONICAL_IMAGE"
(
  cd "$DIST_DIR"
  sha256sum "$(basename "$CANONICAL_IMAGE")" > "$(basename "$CANONICAL_SHA")"
  sha256sum -c "$(basename "$CANONICAL_SHA")"
)

APPIMAGE_EXTRACT_AND_RUN=1 "$CANONICAL_IMAGE" --version | grep -Eq '^[0-9]+\.[0-9]+'

if [[ "${DRY_RUN:-0}" == 1 ]]; then
  printf 'Release dry-run validado: %s e %s\n' "$CANONICAL_IMAGE" "$CANONICAL_SHA"
  exit 0
fi

command -v gh >/dev/null 2>&1 || {
  printf 'GitHub CLI não encontrado.\n' >&2
  exit 1
}
[[ -n "${GH_TOKEN:-}" ]] || {
  printf 'GH_TOKEN não definido.\n' >&2
  exit 1
}

if gh release view "$RELEASE_TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
  gh release upload "$RELEASE_TAG" \
    "$CANONICAL_IMAGE" "$CANONICAL_SHA" \
    --repo "$REPOSITORY" --clobber
else
  notes_file="$(mktemp)"
  trap 'rm -f -- "$notes_file"' EXIT
  cat > "$notes_file" <<'EOF_NOTES'
## Turbo Decky AppImage

Pacote portátil x86_64 para SteamOS e distribuições Arch Linux compatíveis.

1. Baixe `TurboDecky-x86_64.AppImage`.
2. Marque o arquivo como executável.
3. Abra com dois cliques ou execute pelo terminal.
4. Autorize pelo Polkit apenas quando uma ação administrativa for selecionada.

O arquivo `.sha256` permite verificar a integridade do download.
EOF_NOTES

  gh release create "$RELEASE_TAG" \
    "$CANONICAL_IMAGE" "$CANONICAL_SHA" \
    --repo "$REPOSITORY" \
    --target "${GITHUB_SHA:-main}" \
    --title "Turbo Decky — AppImage" \
    --notes-file "$notes_file" \
    --latest
fi

printf 'AppImage publicado na Release %s.\n' "$RELEASE_TAG"
