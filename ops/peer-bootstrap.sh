#!/usr/bin/env bash
# Idempotent Linux peer setup (kyle@apps) for the pm#38 server proof.
# Run with interactive sudo. Creates two unprivileged peer users (so rpc-gssd
# selects credentials by uid) and installs the peer machine keytab (so rpc-gssd
# has machine credentials for NFSv4 clientid operations).
#
# Ordering:
#  - snapshot every managed /etc path BEFORE apt install (packages ship some of
#    these files) using markers under /root, so /etc stays pristine until the
#    real writes;
#  - install packages, then preflight the peer keytab (must contain a machine
#    principal matching this host); abort BEFORE any /etc write if it fails;
#  - write configs, install + validate /etc/krb5.keytab, then destroy the source
#    keytab so it does not linger user-readable.
set -Eeuo pipefail

REALM="${REALM:-WORK.SOPHASTRA.COM}"
FQDN="${FQDN:-work.sophastra.com}"
PEER_USERS=(ws1peer ws2peer)
UID_BASE=10001                              # ws1peer=10001, ws2peer=10002
SNAP=/root/ws-peer-snap                     # markers live here, not in /etc

log() { printf '\n=== %s ===\n' "$*" >&2; }
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
CALLER="${SUDO_USER:-$USER}"
PEER_KEYTAB_SRC="/home/${CALLER}/peer.keytab"

snap_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9.' '_'; }
# Record prior state ONCE, marker under /root (no /etc pollution).
record_etc() {
  local f="$1" k; k="$(snap_key "$f")"
  [ -e "$SNAP/$k.done" ] && return 0
  mkdir -p "$SNAP"
  if [ -e "$f" ] || [ -L "$f" ]; then cp -a "$f" "$SNAP/$k.prews"; else : > "$SNAP/$k.absent"; fi
  touch "$SNAP/$k.done"
}

log "snapshot managed /etc paths BEFORE package install"
for f in /etc/krb5.conf /etc/idmapd.conf /etc/krb5.keytab; do record_etc "$f"; done

log "install nfs client + kerberos client + tcpdump (needed for klist validation)"
export DEBIAN_FRONTEND=noninteractive
echo "krb5-config krb5-config/default_realm string ${REALM}" | debconf-set-selections
apt-get -qq update
apt-get -qq install -y nfs-common krb5-user tcpdump >/dev/null

log "preflight: validate peer machine keytab matches this host (before any /etc write)"
PEER_HN_FQDN="$(hostname -f)"
PEER_HN_SHORT="$(hostname -s)"
if [ ! -f "$PEER_KEYTAB_SRC" ]; then
  echo "ABORT: $PEER_KEYTAB_SRC missing. No /etc changes made." >&2
  echo "       (only packages installed + a /root snapshot; purge/peer-teardown to undo)" >&2
  exit 1
fi
if ! klist -k "$PEER_KEYTAB_SRC" 2>/dev/null \
  | grep -qE "(host|nfs|root)/(${PEER_HN_FQDN}|${PEER_HN_SHORT})@${REALM}"; then
  echo "ABORT: $PEER_KEYTAB_SRC has no machine principal matching hostname" >&2
  echo "       '${PEER_HN_FQDN}' / '${PEER_HN_SHORT}' in realm ${REALM}." >&2
  echo "       Re-run server-bootstrap with PEER_FQDN=<this host's FQDN>." >&2
  exit 1
fi
echo "ok: keytab has a machine principal for ${PEER_HN_FQDN}"
# From here on the source keytab is confirmed to belong to this host and is
# fully consumed either way (copied in on success, useless on failure) — make
# sure it never lingers, including on an install/validate failure below.
trap 'rm -f "$PEER_KEYTAB_SRC"' EXIT

log "write /etc/krb5.conf (per-uid FILE ccaches so rpc-gssd finds them)"
cat > /etc/krb5.conf <<EOF
[libdefaults]
  default_realm = ${REALM}
  dns_lookup_kdc = true
  rdns = false
  allow_weak_crypto = false
  default_ccache_name = FILE:/tmp/krb5cc_%{uid}

[realms]
  ${REALM} = {
    kdc = ${FQDN}
    admin_server = ${FQDN}
  }

[domain_realm]
  .work.sophastra.com = ${REALM}
  work.sophastra.com = ${REALM}
EOF

log "write /etc/idmapd.conf (matching domain; valid plugin names; cosmetic local mapping)"
cat > /etc/idmapd.conf <<EOF
[General]
  Verbosity = 2
  Pipefs-Directory = /run/rpc_pipefs
  Domain = work.sophastra.com

[Translation]
  Method = static,nsswitch
  GSS-Methods = static

[Static]
  ws1@work.sophastra.com = ws1peer
  ws2@work.sophastra.com = ws2peer
EOF

log "install + validate peer machine keytab to /etc/krb5.keytab, then destroy source"
install -m 600 "$PEER_KEYTAB_SRC" /etc/krb5.keytab
chown root:root /etc/krb5.keytab
if ! klist -k /etc/krb5.keytab 2>/dev/null \
  | grep -qE "(host|nfs|root)/(${PEER_HN_FQDN}|${PEER_HN_SHORT})@${REALM}"; then
  echo "ABORT: installed /etc/krb5.keytab missing the matching machine principal" >&2
  exit 1
fi
echo "installed /etc/krb5.keytab ($(klist -k /etc/krb5.keytab 2>/dev/null | grep -c :) entries); source destroyed on exit"
# source removal now handled by the EXIT trap above (covers this success path
# and any failure path after the preflight match check)

log "enable client rpc-gssd"
systemctl enable --now rpc-gssd >/dev/null 2>&1
systemctl restart rpc-gssd 2>/dev/null || true

log "create unprivileged peer users + ALL mountpoints (incl. wsneg used by peer-test)"
uid=$UID_BASE
for u in "${PEER_USERS[@]}"; do
  id "$u" >/dev/null 2>&1 || useradd -u "$uid" -m -d "/home/$u" -s /bin/bash "$u"
  uid=$((uid+1))
done
install -d -o root -g root -m 0755 /mnt/ws1 /mnt/ws2 /mnt/ws1cap /mnt/wsneg
install -d -o "$CALLER" -g "$CALLER" -m 0755 "/home/${CALLER}/ws-evidence"

log "peer info for the operator"
echo "PEER_FQDN=${PEER_HN_FQDN}" > "/home/${CALLER}/peer-info.env"
chown "$CALLER:$CALLER" "/home/${CALLER}/peer-info.env" "/home/${CALLER}/ws-evidence" 2>/dev/null || true

log "DONE"
echo "peer ready. ensure /home/${CALLER}/ws-peer.env is present (chmod 600),"
echo "then: sudo bash ops/peer-test.sh"
