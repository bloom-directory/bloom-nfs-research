#!/usr/bin/env bash
# Install one coworker SSH public key as a restricted credential-only endpoint.
# Run on cocoroco as root after server-bootstrap.sh, with the public key on stdin:
#   printf '%s\n' 'ssh-ed25519 AAAA...' | bash server-authorize-physical-mac.sh
set -Eeuo pipefail

TARGET_USER="${TARGET_USER:-cocoroco}"
PEER_ENV="${PEER_ENV:-/root/ws-secrets/peer.env}"
MARKER="bloom-nfs-physical-test"

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
IFS= read -r PUBLIC_KEY || { echo "missing SSH public key on stdin" >&2; exit 1; }
[ -n "$PUBLIC_KEY" ] || { echo "empty SSH public key" >&2; exit 1; }
case "$PUBLIC_KEY" in
  ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-ssh-ed25519@openssh.com\ *|sk-ecdsa-sha2-*\ *) ;;
  *) echo "unsupported or malformed SSH public key" >&2; exit 1 ;;
esac

PASS="$(sed -n 's/^WS_ws1_PASS=//p' "$PEER_ENV")"
[ -n "$PASS" ] || { echo "missing WS_ws1_PASS in $PEER_ENV" >&2; exit 1; }

ENTRY="$(getent passwd "$TARGET_USER")"
[ -n "$ENTRY" ] || { echo "unknown target user: $TARGET_USER" >&2; exit 1; }
IFS=: read -r _ _ TARGET_UID TARGET_GID _ TARGET_HOME _ <<< "$ENTRY"
SSH_DIR="$TARGET_HOME/.ssh"
AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"
CREDENTIAL_FILE="$TARGET_HOME/.bloom-nfs-physical-credential"

install -d -m 700 -o "$TARGET_UID" -g "$TARGET_GID" "$SSH_DIR"
touch "$AUTHORIZED_KEYS"
chown "$TARGET_UID:$TARGET_GID" "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"

CRED_TMP="$(mktemp)"
AUTH_TMP="$(mktemp)"
cleanup() { rm -f "$CRED_TMP" "$AUTH_TMP"; }
trap cleanup EXIT
(umask 077; printf 'BLOOM_NFS_PASSWORD=%s\n' "$PASS" > "$CRED_TMP")
unset PASS
install -m 400 -o "$TARGET_UID" -g "$TARGET_GID" "$CRED_TMP" "$CREDENTIAL_FILE"

grep -v "[[:space:]]${MARKER}$" "$AUTHORIZED_KEYS" > "$AUTH_TMP" || true
printf 'restrict,command="/bin/cat %s" %s %s\n' \
  "$CREDENTIAL_FILE" "$PUBLIC_KEY" "$MARKER" >> "$AUTH_TMP"
install -m 600 -o "$TARGET_UID" -g "$TARGET_GID" "$AUTH_TMP" "$AUTHORIZED_KEYS"

echo "restricted physical-Mac credential key installed for $TARGET_USER"
echo "endpoint: ${TARGET_USER}@work.sophastra.com (no shell, PTY, or forwarding)"
