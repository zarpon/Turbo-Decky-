#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/00-core.sh
source "$SCRIPT_DIR/lib/00-core.sh"
# shellcheck source=lib/10-profiles.sh
source "$SCRIPT_DIR/lib/10-profiles.sh"
# shellcheck source=lib/20-actions.sh
source "$SCRIPT_DIR/lib/20-actions.sh"
# shellcheck source=lib/30-hardening.sh
source "$SCRIPT_DIR/lib/30-hardening.sh"
# shellcheck source=lib/40-source-sync.sh
source "$SCRIPT_DIR/lib/40-source-sync.sh"
# shellcheck source=lib/50-memory-mode-safety.sh
source "$SCRIPT_DIR/lib/50-memory-mode-safety.sh"

if [[ "${TURBODECKY_LIBRARY:-0}" != 1 ]]; then
  main "$@"
fi
