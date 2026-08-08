#!/usr/bin/env bash
# Idempotent NFSv4.1 + krb5p reference server for pm#38 (Steps 3-4).
# Run on cocoroco with interactive sudo. Re-runnable. Restorable via
# server-teardown.sh. Never starts kadmind (only kadmin.local). Host firewall is
# inactive; public rpcbind/NFS exposure is prevented by the cloud security group
# (only tcp/udp 88 and tcp 2049 are opened); cocoroco's own services untouched.
#
# Env: PEER_FQDN = the peer's `hostname -f` (kyle@apps). When set, a machine
# keytab for the peer is produced at /root/ws-secrets/peer.keytab so rpc-gssd has
# valid machine credentials for NFSv4 clientid operations.
set -Eeuo pipefail

REALM="${REALM:-WORK.SOPHASTRA.COM}"
FQDN="${FQDN:-work.sophastra.com}"           # NFS + KDC hostname -> cocoroco public IP
WS_USERS=(ws1 ws2)
UID_BASE=10001                               # ws1=10001, ws2=10002
MAXLIFE=1hour
EXPORT_ROOT="${EXPORT_ROOT:-/export}"
EVIDENCE_DIR="${EVIDENCE_DIR:-/var/tmp/ws-evidence}"
SECRETS_DIR=/root/ws-secrets
BAKROOT="$SECRETS_DIR/backup"
MANIFEST="$SECRETS_DIR/managed-files"
PEER_ENV="$SECRETS_DIR/peer.env"
AES="aes256-cts-hmac-sha1-96:normal,aes128-cts-hmac-sha1-96:normal"

log() { printf '\n=== %s ===\n' "$*" >&2; }
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
mkdir -p "$SECRETS_DIR" "$BAKROOT" "$EVIDENCE_DIR" "$EXPORT_ROOT"
chmod 700 "$SECRETS_DIR"; chmod 755 "$EVIDENCE_DIR"
# Initialize the manifest ONCE. Never truncate on rerun: manage() relies on it
# persisting so it never backs up its own generated files.
if [ ! -f "$MANIFEST" ]; then : > "$MANIFEST"; chmod 600 "$MANIFEST"; fi

# Record a managed path on FIRST run only: back up if it existed, else mark
# absent. Idempotent across re-runs; teardown restores-or-removes deterministically.
manage() {
  local f="$1"
  grep -qxF "$f" "$MANIFEST" 2>/dev/null && return 0
  mkdir -p "$BAKROOT$(dirname "$f")"
  if [ -e "$f" ] || [ -L "$f" ]; then cp -a "$f" "$BAKROOT$f.orig"; else : > "$BAKROOT$f.absent"; fi
  echo "$f" >> "$MANIFEST"
}

# kadmin.local: getprinc exits 0 even when the principal is absent; match output instead.
princ_exists() { kadmin.local -q "getprinc $1" 2>&1 | grep -q "^Principal: $1"; }

log "snapshot all managed /etc paths BEFORE package install (krb5-config ships /etc/krb5.conf)"
for f in /etc/krb5.conf /etc/krb5kdc/kdc.conf /etc/krb5kdc/kadm5.acl \
         /etc/krb5.keytab /etc/idmapd.conf /etc/exports /etc/nfs.conf; do
  manage "$f"
done

log "mask kadmind BEFORE install so the package unit cannot auto-start (port 749)"
systemctl mask krb5-admin-server 2>/dev/null || true

log "time synchronization"
timedatectl status --no-pager | tee "$EVIDENCE_DIR/01-time.txt" >/dev/null

log "install packages; preseed realm to silence krb5-config"
export DEBIAN_FRONTEND=noninteractive
echo "krb5-config krb5-config/default_realm string ${REALM}" | debconf-set-selections
apt-get -qq update
apt-get -qq install -y krb5-kdc krb5-admin-server nfs-kernel-server nfs-common \
  libnfsidmap1 openssl >/dev/null
systemctl disable --now krb5-admin-server 2>/dev/null || true

log "write /etc/krb5.conf"
manage /etc/krb5.conf
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

log "write /etc/krb5kdc/kdc.conf (AES-SHA1 only, no kadmind port)"
manage /etc/krb5kdc/kdc.conf; manage /etc/krb5kdc/kadm5.acl
mkdir -p /etc/krb5kdc
cat > /etc/krb5kdc/kdc.conf <<EOF
[kdcdefaults]
  kdc_ports = 88
  kdc_tcp_ports = 88

[realms]
  ${REALM} = {
    acl_file = /etc/krb5kdc/kadm5.acl
    admin_keytab = /etc/krb5kdc/kadm5.keytab
    key_stash_file = /etc/krb5kdc/.k5.${REALM}
    master_key_type = aes256-cts-hmac-sha1-96
    supported_enctypes = ${AES}
  }
EOF
echo "*/admin@${REALM} *" > /etc/krb5kdc/kadm5.acl

log "create realm (skipped if DB exists). Master password via stdin, never argv"
STASH="/etc/krb5kdc/.k5.${REALM}"
DB="/var/lib/krb5kdc/principal"
if [ -e "$DB" ]; then
  if [ ! -f "$STASH" ]; then
    echo "FATAL: $DB exists but $STASH is absent — master key unrecoverable (master pw was never persisted)." >&2
    echo "Recover with: sudo bash ops/server-teardown.sh  (or: kdb5_util -r $REALM destroy -f && rm -f /var/lib/krb5kdc/principal*)" >&2
    exit 1
  fi
  echo "DB + stash present, skipping create"
else
  MASTER_PW="$(openssl rand -base64 32)"
  printf '%s\n%s\n' "$MASTER_PW" "$MASTER_PW" | kdb5_util -r "$REALM" create -s
  # create -s has been observed to exit 0 without writing the stash; fall back to
  # `stash` while MASTER_PW is still in memory, else bail before unsetting so we
  # never brick the DB with an unrecoverable master key.
  if [ ! -f "$STASH" ]; then
    printf '%s\n' "$MASTER_PW" | kdb5_util -r "$REALM" stash
  fi
  if [ ! -f "$STASH" ]; then
    echo "FATAL: kdb5_util create/stash failed to write $STASH." >&2
    echo "Master password (capture now — only time it is shown): $MASTER_PW" >&2
    exit 1
  fi
  unset MASTER_PW
fi
systemctl enable --now krb5-kdc

log "create nfs service principal + keytab (AES-SHA1)"
if ! princ_exists "nfs/${FQDN}@${REALM}"; then
  kadmin.local -q "addprinc -randkey -e ${AES} nfs/${FQDN}@${REALM}"
fi
manage /etc/krb5.keytab
if ! klist -k /etc/krb5.keytab 2>/dev/null | grep -q "nfs/${FQDN}@${REALM}"; then
  kadmin.local -q "ktadd -k /etc/krb5.keytab -norandkey nfs/${FQDN}@${REALM}"
fi
chmod 600 /etc/krb5.keytab

log "create workspace user principals + Unix users + mode-0700 roots (passwords via stdin)"
: > "$PEER_ENV"; chmod 600 "$PEER_ENV"
printf 'REALM=%s\nFQDN=%s\nSPN=nfs/%s@%s\n\n' "$REALM" "$FQDN" "$FQDN" "$REALM" >> "$PEER_ENV"
uid=$UID_BASE
for u in "${WS_USERS[@]}"; do
  # Password is persisted root-only under SECRETS_DIR (like manage()'s /etc
  # backups) so a re-run reuses it instead of rotating it. Without this, every
  # idempotent re-run of this script silently invalidated whatever peer.env
  # was already transferred to the peer.
  PWFILE="$SECRETS_DIR/${u}.pw"
  PRINC_EXISTS=0
  princ_exists "w/${u}@${REALM}" && PRINC_EXISTS=1
  if [ -f "$PWFILE" ] && [ "$PRINC_EXISTS" -eq 1 ]; then
    pw="$(cat "$PWFILE")"   # principal + password already established; do not rotate
  else
    pw="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-24)"
    : > "$PWFILE"; chmod 600 "$PWFILE"; printf '%s' "$pw" > "$PWFILE"
    if [ "$PRINC_EXISTS" -eq 1 ]; then
      kadmin.local >/dev/null 2>&1 <<EOF
cpw -pw ${pw} w/${u}@${REALM}
EOF
    else
      kadmin.local >/dev/null 2>&1 <<EOF
addprinc -pw ${pw} w/${u}@${REALM}
EOF
    fi
  fi
  kadmin.local >/dev/null 2>&1 <<EOF
modprinc -maxlife ${MAXLIFE} -maxrenewlife 0 +requires_preauth -allow_forwardable -allow_renewable w/${u}@${REALM}
EOF
  id "$u" >/dev/null 2>&1 || useradd -u "$uid" -M -d "${EXPORT_ROOT}/${u}" -s /usr/sbin/nologin "$u"
  install -d -o "$u" -g "$u" -m 0700 "${EXPORT_ROOT}/${u}"
  printf 'WS_%s_USER=%s\nWS_%s_UID=%s\nWS_%s_PASS=%s\nWS_%s_PATH=/%s\n\n' \
    "$u" "w/$u" "$u" "$uid" "$u" "$pw" "$u" "$u" >> "$PEER_ENV"
  unset pw
  uid=$((uid+1))
done

log "write /etc/idmapd.conf (principal->UID static mapping; valid plugin names)"
manage /etc/idmapd.conf
cat > /etc/idmapd.conf <<EOF
[General]
  Verbosity = 2
  Pipefs-Directory = /run/rpc_pipefs
  Domain = work.sophastra.com
  Cache-Expiration = 2

[Translation]
  Method = nsswitch
  GSS-Methods = static

[Static]
EOF
for u in "${WS_USERS[@]}"; do echo "  w/${u}@${REALM} = ${u}" >> /etc/idmapd.conf; done

log "write /etc/exports (NFSv4 pseudoroot + per-workspace; krb5p only; insecure)"
manage /etc/exports
{
  echo "${EXPORT_ROOT}    *(sec=krb5p,rw,insecure,fsid=0,root_squash)"
  for u in "${WS_USERS[@]}"; do echo "${EXPORT_ROOT}/${u}  *(sec=krb5p,rw,insecure,root_squash)"; done
} > /etc/exports

log "write /etc/nfs.conf (NFSv4.1 ONLY: disable v2/v3/v4.0/v4.2)"
manage /etc/nfs.conf
cat > /etc/nfs.conf <<EOF
[nfsd]
  vers2 = no
  vers3 = no
  vers4 = yes
  vers4.0 = no
  vers4.1 = yes
  vers4.2 = no
  udp = no
  tcp = yes
EOF

log "optionally build peer machine keytab (for rpc-gssd machine credentials)"
if [ -n "${PEER_FQDN:-}" ]; then
  PEER_KEYTAB="$SECRETS_DIR/peer.keytab"
  # ktadd cannot append to a zero-byte/invalid keytab ("Unsupported key table
  # format version"); keep an existing file only if it's non-empty AND klist can
  # read it, else wipe so ktadd writes a properly-headered one on first add.
  # (Zero-size is checked explicitly, not just klist's exit code: klist has been
  # observed to report 0 entries on an empty file without a nonzero exit.)
  if [ -f "$PEER_KEYTAB" ] && { [ ! -s "$PEER_KEYTAB" ] || ! klist -k "$PEER_KEYTAB" >/dev/null 2>&1; }; then
    rm -f "$PEER_KEYTAB"
  fi
  make_peerspn() { # svc hostname : extract CURRENT key (-norandkey) so an installed peer keytab stays valid
    local p="$1/$2@${REALM}"
    princ_exists "$p" || kadmin.local -q "addprinc -randkey -e ${AES} $p"
    klist -k "$PEER_KEYTAB" 2>/dev/null | grep -q "$p" || kadmin.local -q "ktadd -k $PEER_KEYTAB -norandkey $p"
  }
  for svc in nfs host root; do make_peerspn "$svc" "$PEER_FQDN"; done
  PEER_SHORT="${PEER_FQDN%%.*}"
  [ "$PEER_SHORT" != "$PEER_FQDN" ] && for svc in nfs host; do make_peerspn "$svc" "$PEER_SHORT"; done
  chmod 600 "$PEER_KEYTAB"
  printf 'PEER_FQDN=%s\n' "$PEER_FQDN" >> "$PEER_ENV"
  echo "peer keytab: $PEER_KEYTAB (transfer to kyle@apps:/home/<user>/peer.keytab)"
else
  echo "PEER_FQDN unset: skipping peer machine keytab (set it if rpc-gssd needs machine creds)"
fi

log "enable server-side GSS + idmap; (re)start nfs-server; export"
systemctl enable --now rpc-svcgssd >/dev/null 2>&1
systemctl restart rpc-svcgssd 2>/dev/null || true
systemctl restart nfs-idmapd 2>/dev/null || systemctl restart rpc-idmapd 2>/dev/null || true
systemctl enable --now nfs-server
exportfs -ra

log "collect evidence"
{
  echo "## exportfs -v"; exportfs -v
  echo "## nfsd version booleans (nfsconf --get nfsd <tag>)"
  for k in vers2 vers3 vers4 vers4.0 vers4.1 vers4.2; do printf "%s=" "$k"; nfsconf --get nfsd "$k" 2>/dev/null || echo "?"; done
  echo "## keytab"; klist -k /etc/krb5.keytab
  echo "## ws principals"; for u in "${WS_USERS[@]}"; do kadmin.local -q "getprinc w/${u}@${REALM}" | grep -E 'Principal|Max life|Attributes|Required'; done
  echo "## services"; systemctl is-active krb5-kdc nfs-server rpc-svcgssd
  echo "## rpc-gssd (client; should be inactive on server)"; systemctl is-active rpc-gssd || true
  echo "## kadmind (should be masked/inactive)"; systemctl is-active krb5-admin-server || true
} > "$EVIDENCE_DIR/02-server-state.txt" 2>&1
ss -tulnp > "$EVIDENCE_DIR/03-listeners.txt" 2>&1
chmod 644 "$EVIDENCE_DIR"/*.txt

log "listener gates (expected: tcp+udp/88, tcp/2049; forbidden: 749)"
GATE=0
ss -tulnp | grep -q 'tcp.*:88 '   || { echo "GATE FAIL: tcp/88 not listening"; GATE=1; }
ss -tulnp | grep -q 'udp.*:88 '   || { echo "GATE FAIL: udp/88 not listening"; GATE=1; }
ss -tulnp | grep -q 'tcp.*:2049 ' || { echo "GATE FAIL: tcp/2049 not listening"; GATE=1; }
ss -tulnp | grep -qE ':749 '      && { echo "GATE FAIL: kadmind 749 is listening"; GATE=1; }
# rpcbind 111 is permitted locally (contained by the cloud SG); recorded, not gated.
if [ "$GATE" -ne 0 ]; then
  echo "LISTENER GATE FAILED — see $EVIDENCE_DIR/03-listeners.txt"
  echo "restore with: sudo bash ops/server-teardown.sh"
  exit 1
fi

log "DONE"
echo "realm:       $REALM"
echo "fqdn:        $FQDN"
echo "peer bundle: $PEER_ENV  (root-only)"
[ -n "${PEER_FQDN:-}" ] && echo "peer keytab: $SECRETS_DIR/peer.keytab"
echo "evidence:    $EVIDENCE_DIR/02-server-state.txt + 03-listeners.txt"
echo "restore:     sudo bash ops/server-teardown.sh"
echo "next: open tcp/udp 88 + tcp 2049 in cocoroco's cloud SG (scope to kyle@apps)"
