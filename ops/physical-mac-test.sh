#!/usr/bin/env bash
# Physical macOS Tahoe kill-gate. Built-in tools only; never invokes sudo.
#
# Run from a current checkout. The script automatically uses SSH to retrieve
# the one-hour Kerberos password through the coworker's restricted public key:
#   bash ops/physical-mac-test.sh
set -uo pipefail

REALM="${REALM:-WORK.SOPHASTRA.COM}"
FQDN="${FQDN:-work.sophastra.com}"
WS_USER="${WS_USER:-w/ws1}"
SPN="${SPN:-nfs/work.sophastra.com}"
WS_PATH="${WS_PATH:-ws1}"
EXPECTED_MACOS_VERSION="${EXPECTED_MACOS_VERSION:-26.6}"
CREDENTIAL_SSH_HOST="${CREDENTIAL_SSH_HOST:-cocoroco@work.sophastra.com}"
CREDENTIAL_SSH_IDENTITY="${CREDENTIAL_SSH_IDENTITY:-}"
PRINCIPAL="${WS_USER}@${REALM}"
SERVER_PRINCIPAL="${SPN}@${REALM}"
LOG="${BLOOM_NFS_LOG:-$PWD/bloom-nfs-physical-$(date +%Y%m%d-%H%M%S).txt}"

exec > >(tee "$LOG") 2>&1

say() { printf '\n=== %s ===\n' "$*"; }
die() { say "FATAL: $*"; exit 1; }
cap() { printf '+ %s\n' "$*"; "$@" 2>&1; }

say "physical macOS NFSv4.1 + krb5p test (NO SUDO)"
echo "transcript=$LOG"
cap sw_vers
cap uname -a
cap id

MACOS_VERSION="$(sw_vers -productVersion)"
[ "$MACOS_VERSION" = "$EXPECTED_MACOS_VERSION" ] \
  || die "expected macOS $EXPECTED_MACOS_VERSION, got $MACOS_VERSION"
for tool in kinit klist kdestroy mount_nfs umount perl; do
  command -v "$tool" >/dev/null 2>&1 || die "required built-in tool missing: $tool"
done
if id -Gn | tr ' ' '\n' | grep -qx admin; then
  echo "account_class=admin-group-member (test still invokes no sudo)"
else
  echo "account_class=standard-non-admin"
fi

MNT="$HOME/RemoteWorkspace-bloom-test"
[ ! -e "$MNT" ] || die "mountpoint already exists: $MNT"
RUNROOT="$(mktemp -d "${TMPDIR:-/tmp}/bloom-nfs-physical.XXXXXX")" \
  || die "could not create temporary directory"
mkdir -m 700 "$MNT" || die "could not create mountpoint: $MNT"

TO="$RUNROOT/to"
cat > "$TO" <<'EOF'
#!/usr/bin/env bash
perl -e 'alarm shift; exec @ARGV' "$@"
EOF
chmod 700 "$TO"

KRB5CONF="$RUNROOT/krb5.conf"
cat > "$KRB5CONF" <<EOF
[libdefaults]
  default_realm = ${REALM}
  dns_lookup_kdc = false
  rdns = false
  allow_weak_crypto = false

[realms]
  ${REALM} = {
    kdc = ${FQDN}
    admin_server = ${FQDN}
  }
EOF
export KRB5_CONFIG="$KRB5CONF"
export KRB5CCNAME="FILE:$RUNROOT/ccache"

cleanup() {
  set +e
  if mount | grep -Fq " on $MNT "; then "$TO" 15 umount "$MNT"; fi
  kdestroy 2>/dev/null
  rm -f "$RUNROOT/pw" "$RUNROOT/ccache" "$KRB5CONF" "$TO"
  rmdir "$MNT" 2>/dev/null
  rmdir "$RUNROOT" 2>/dev/null
  say "cleanup complete; send this transcript: $LOG"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

say "reachability"
cap bash -c "echo > /dev/tcp/${FQDN}/88" || die "tcp/88 is unreachable"
cap bash -c "echo > /dev/tcp/${FQDN}/2049" || die "tcp/2049 is unreachable"

say "Kerberos authentication"
if [ -t 0 ]; then
  SSH_ARGS=(-T -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
  [ -n "$CREDENTIAL_SSH_IDENTITY" ] && SSH_ARGS+=(-i "$CREDENTIAL_SSH_IDENTITY")
  echo "+ ssh <restricted-credential-endpoint>"
  set +e
  CREDENTIAL_OUTPUT="$(ssh "${SSH_ARGS[@]}" "$CREDENTIAL_SSH_HOST")"
  SSH_RC=$?
  set -e
  [ "$SSH_RC" -eq 0 ] || die "SSH credential retrieval failed (exit $SSH_RC)"
else
  CREDENTIAL_OUTPUT="$(cat)"
fi
WS_PASS=""
while IFS= read -r credential_line; do
  case "$credential_line" in
    BLOOM_NFS_PASSWORD=*) WS_PASS="${credential_line#BLOOM_NFS_PASSWORD=}" ;;
  esac
done <<< "$CREDENTIAL_OUTPUT"
unset CREDENTIAL_OUTPUT credential_line
[ -n "$WS_PASS" ] || die "credential endpoint returned no labeled one-time password"
PWFILE="$RUNROOT/pw"
(umask 077; printf '%s' "$WS_PASS" > "$PWFILE")
unset WS_PASS
echo "+ kinit --password-file=<temporary> $PRINCIPAL"
kinit --password-file="$PWFILE" "$PRINCIPAL" || die "kinit failed"
rm -f "$PWFILE"
cap klist
if command -v kgetcred >/dev/null 2>&1; then
  cap kgetcred "$SERVER_PRINCIPAL" || die "service-ticket acquisition failed"
  cap klist
fi

say "ordinary-user mount: explicit NFSv4.1 + krb5p"
OPTS="tcp,retrycnt=0,vers=4.1,sec=krb5p,principal=${PRINCIPAL},sprincipal=${SERVER_PRINCIPAL}"
echo "+ mount_nfs -o $OPTS ${FQDN}:/${WS_PATH} $MNT"
set +e
"$TO" 60 mount_nfs -o "$OPTS" "${FQDN}:/${WS_PATH}" "$MNT"
MOUNT_RC=$?
set -e
if ! mount | grep -Fq " on $MNT "; then
  say "RESULT: MOUNT FAILED (exit $MOUNT_RC)"
  exit 20
fi

say "mounted; read/write verification"
cap mount
MARKER="physical-mac-$(date +%s)"
printf '%s\n' "$MARKER" > "$MNT/physical-mac-marker.txt"
[ "$(cat "$MNT/physical-mac-marker.txt")" = "$MARKER" ] || die "marker readback mismatch"
mkdir "$MNT/physical-mac-dir"
mv "$MNT/physical-mac-marker.txt" "$MNT/physical-mac-dir/renamed.txt"
rm -f "$MNT/physical-mac-dir/renamed.txt"
rmdir "$MNT/physical-mac-dir"
say "RESULT: MOUNT + READ/WRITE PASSED"
