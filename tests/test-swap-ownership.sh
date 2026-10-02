#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT="$(realpath "${1:-./InstallTD.sh}")"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
ROOT="$TMP/root"
BIN="$TMP/bin"
mkdir -p "$ROOT/etc" "$ROOT/home/.swap" "$ROOT/var/lib/turbodecky/state/transaction" "$BIN"
printf '# user fstab\n' > "$ROOT/etc/fstab"
printf 'original user swap\n' > "$ROOT/home/swapfile"
cat > "$BIN/df" <<'MOCK'
#!/usr/bin/env bash
printf 'Avail\n%s\n' "${MOCK_FREE:-1099511627776}"
MOCK
cat > "$BIN/findmnt" <<'MOCK'
#!/usr/bin/env bash
printf 'ext4\n'
MOCK
cat > "$BIN/fallocate" <<'MOCK'
#!/usr/bin/env bash
truncate -s "$2" "$3"
MOCK
cat > "$BIN/swapon" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == --show=NAME ]]; then
  [[ ! -f "$MOCK_ACTIVE" ]] || cat "$MOCK_ACTIVE"
else
  [[ "${MOCK_SWAPON_FAIL:-0}" != 1 ]] || exit 1
  printf '%s\n' "${@: -1}" > "$MOCK_ACTIVE"
fi
MOCK
cat > "$BIN/swapoff" <<'MOCK'
#!/usr/bin/env bash
rm -f -- "$MOCK_ACTIVE"
MOCK
chmod +x "$BIN"/*
export TURBODECKY_ROOTFS="$ROOT" TURBODECKY_LIBRARY=1 TURBODECKY_UI=terminal
source "$SCRIPT"
export MOCK_ACTIVE="$TMP/active" PATH="$BIN:$PATH"
ROOTFS="" DRY_RUN=0 OPERATION_DIR="$STATE_DIR/transaction"
ensure_swapfile
swapfile_size_is_8g "$SWAPFILE"
swapfile_has_swap_signature "$SWAPFILE"
swapfile_is_active "$SWAPFILE"
grep -Fqx 'original user swap' "$ROOT/home/swapfile"
remove_created_swapfile
[[ -e "$SWAPFILE" ]]
finalize_swapfile_removal
[[ ! -e "$SWAPFILE" ]]
grep -Fqx 'original user swap' "$ROOT/home/swapfile"
# Insufficient space fails before allocation or modifications of fstab/user swap.
cp "$FSTAB_FILE" "$TMP/fstab-before"
if (export MOCK_FREE=100; preflight_swapfile) > "$TMP/free.out" 2>&1; then exit 1; fi
cmp "$FSTAB_FILE" "$TMP/fstab-before"
[[ ! -e "$SWAPFILE" ]]
# A file at our path without the creation marker is always preserved.
printf 'external file\n' > "$SWAPFILE"
if (preflight_swapfile) > "$TMP/owner.out" 2>&1; then exit 1; fi
grep -Fqx 'external file' "$SWAPFILE"
printf 'Turbo Decky backing swap ownership validation passed\n'
