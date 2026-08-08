#!/usr/bin/env bash
# Restore kyle@apps to its pre-test state. Idempotent. Run with interactive sudo.
# Restores /etc/krb5.conf and /etc/idmapd.conf from the .orig copies the
# bootstrap made, removes the peer users + mountpoints + evidence, and destroys
# any lingering Kerberos caches. Leaves packages installed (apt purge by hand).
set -Eeuo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
CALLER="${SUDO_USER:-$USER}"

echo "unmounting any test mounts"
for m in /mnt/ws1 /mnt/ws2 /mnt/ws1cap /mnt/wsneg; do umount "$m" 2>/dev/null || umount -f "$m" 2>/dev/null || true; done

echo "stopping client rpc-gssd"
systemctl disable --now rpc-gssd 2>/dev/null || true

echo "destroying peer Kerberos caches"
for u in ws1peer ws2peer root; do sudo -u "$u" kdestroy 2>/dev/null || true; done
rm -f /tmp/krb5cc_0 /tmp/krb5cc_10001 /tmp/krb5cc_10002 2>/dev/null || true

echo "restoring /etc configs from /root snapshot markers (prews / absent)"
SNAP=/root/ws-peer-snap
snap_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9.' '_'; }
restore_etc() {
  local f="$1" k; k="$(snap_key "$f")"
  if [ -e "$SNAP/$k.prews" ]; then
    cp -a "$SNAP/$k.prews" "$f"
  elif [ -e "$SNAP/$k.absent" ]; then
    rm -f "$f"
  fi
}
restore_etc /etc/krb5.conf
restore_etc /etc/idmapd.conf
restore_etc /etc/krb5.keytab
rm -rf "$SNAP"

echo "removing peer users, mountpoints, peer.env, peer.keytab (machine secret), peer-info, evidence"
userdel -r ws1peer 2>/dev/null || true
userdel -r ws2peer 2>/dev/null || true
rmdir /mnt/ws1 /mnt/ws2 /mnt/ws1cap /mnt/wsneg 2>/dev/null || true
rm -f "/home/${CALLER}/ws-peer.env" "/home/${CALLER}/peer-info.env"
rm -f "/home/${CALLER}/peer.keytab"      # reusable machine credential -> must be destroyed
rm -rf "/home/${CALLER}/ws-evidence"

echo
echo "peer teardown complete. packages left installed for explicit removal:"
echo "  apt-get purge -y nfs-common krb5-user tcpdump"
