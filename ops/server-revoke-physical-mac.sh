#!/usr/bin/env bash
# Remove the restricted physical-Mac credential key and one-time credential.
set -Eeuo pipefail

TARGET_USER="${TARGET_USER:-cocoroco}"
MARKER="bloom-nfs-physical-test"
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

ENTRY="$(getent passwd "$TARGET_USER")"
[ -n "$ENTRY" ] || { echo "unknown target user: $TARGET_USER" >&2; exit 1; }
IFS=: read -r _ _ TARGET_UID TARGET_GID _ TARGET_HOME _ <<< "$ENTRY"
AUTHORIZED_KEYS="$TARGET_HOME/.ssh/authorized_keys"
CREDENTIAL_FILE="$TARGET_HOME/.bloom-nfs-physical-credential"

if [ -f "$AUTHORIZED_KEYS" ]; then
  AUTH_TMP="$(mktemp)"
  trap 'rm -f "$AUTH_TMP"' EXIT
  grep -v "[[:space:]]${MARKER}$" "$AUTHORIZED_KEYS" > "$AUTH_TMP" || true
  install -m 600 -o "$TARGET_UID" -g "$TARGET_GID" "$AUTH_TMP" "$AUTHORIZED_KEYS"
fi
rm -f "$CREDENTIAL_FILE"
echo "restricted physical-Mac credential key removed"
