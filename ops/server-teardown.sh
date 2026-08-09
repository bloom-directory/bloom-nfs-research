#!/usr/bin/env bash
# Restore cocoroco to its pre-test state. Idempotent. Run with interactive sudo.
# Restores every /etc file the bootstrap backed up, removes files the bootstrap
# created (when no prior backup existed), destroys the realm database, removes
# the keytab, workspace data, Unix users, and secrets. Does NOT touch cocoroco's
# own services on 80/443/3000/udp443/udp51820. Leaves packages installed (apt
# purge by hand if desired).
set -Eeuo pipefail

REALM="${REALM:-WORK.SOPHASTRA.COM}"
FQDN="${FQDN:-work.sophastra.com}"
WS_USERS=(ws1 ws2)
EXPORT_ROOT="${EXPORT_ROOT:-/export}"
SECRETS_DIR=/root/ws-secrets
BAKROOT="$SECRETS_DIR/backup"
MANIFEST="$SECRETS_DIR/managed-files"
UNIT_STATE="$SECRETS_DIR/rpc-unit-state"

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }

echo "stopping NFS + GSS + KDC services"
systemctl disable --now nfs-server rpc-svcgssd rpc-gssd 2>/dev/null || true
systemctl disable --now nfs-idmapd rpc-idmapd 2>/dev/null || true
systemctl disable --now krb5-kdc 2>/dev/null || true
systemctl disable --now rpc-statd.service rpc-statd-notify.service 2>/dev/null || true
systemctl disable --now rpcbind.socket rpcbind.service 2>/dev/null || true

echo "clearing exports"
if [ -f /etc/exports ]; then : > /etc/exports; exportfs -ua 2>/dev/null || true; fi

echo "deleting test principals (best-effort; KDC DB may already be gone)"
for u in "${WS_USERS[@]}"; do kadmin.local -q "delprinc -force w/${u}@${REALM}" 2>/dev/null || true; done
kadmin.local -q "delprinc -force nfs/${FQDN}@${REALM}" 2>/dev/null || true
if [ -n "${PEER_FQDN:-}" ]; then
  for svc in nfs host root; do kadmin.local -q "delprinc -force ${svc}/${PEER_FQDN}@${REALM}" 2>/dev/null || true; done
  PEER_SHORT="${PEER_FQDN%%.*}"
  [ "$PEER_SHORT" != "$PEER_FQDN" ] && for svc in nfs host; do kadmin.local -q "delprinc -force ${svc}/${PEER_SHORT}@${REALM}" 2>/dev/null || true; done
fi

echo "destroying realm database + stash"
kdb5_util -r "$REALM" destroy -f 2>/dev/null || true
rm -f "/etc/krb5kdc/.k5.${REALM}" "/var/lib/krb5kdc/.k5.${REALM}" /var/lib/krb5kdc/principal* /var/lib/krb5kdc/*.ok 2>/dev/null || true

echo "restoring managed files from manifest (restore backup, else remove absent-marked)"
if [ -f "$MANIFEST" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -e "$BAKROOT$f.orig" ]; then
      mkdir -p "$(dirname "$f")"; cp -a "$BAKROOT$f.orig" "$f"
    elif [ -e "$BAKROOT$f.absent" ]; then
      rm -f "$f"
    fi
  done < "$MANIFEST"
fi

echo "removing workspace data + Unix users"
for u in "${WS_USERS[@]}"; do
  rm -rf "${EXPORT_ROOT:?}/${u}"
  userdel "$u" 2>/dev/null || true
done
rmdir "$EXPORT_ROOT" 2>/dev/null || true

echo "restoring pre-test rpcbind/rpc-statd unit states"
if [ -f "$UNIT_STATE" ]; then
  while IFS='|' read -r unit was_active was_enabled; do
    [ -n "$unit" ] || continue
    [ "$was_enabled" = enabled ] && systemctl enable "$unit" 2>/dev/null || true
    [ "$was_active" = active ] && systemctl start "$unit" 2>/dev/null || true
  done < "$UNIT_STATE"
fi

echo "removing secrets, backups, manifest, evidence"
rm -rf "$SECRETS_DIR" /var/tmp/ws-evidence 2>/dev/null || true

echo "unmasking kadmind (bootstrap had masked it) -> restores prior default"
systemctl unmask krb5-admin-server 2>/dev/null || true

echo
echo "teardown complete. packages left installed for explicit removal:"
echo "  apt-get purge -y krb5-kdc krb5-admin-server nfs-kernel-server nfs-common libnfsidmap1"
echo "cocoroco's own services were not touched."
