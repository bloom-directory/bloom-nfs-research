#!/usr/bin/env bash
# Privileged one-shot peer test for the pm#38 server proof (Steps 3-4).
# Run on kyle@apps with interactive sudo AFTER transferring peer.env + peer.keytab
# from cocoroco. Proves the SERVER. NOT the macOS no-admin test (criterion #4).
#
# Identity model: each Kerberos principal is acquired by a distinct unprivileged
# peer user (ws1peer/w/ws1, ws2peer/w/ws2) so rpc-gssd selects credentials by
# uid. Root holds w/ws1 only to satisfy mount()'s CAP_SYS_ADMIN. A peer machine
# keytab (/etc/krb5.keytab) supplies rpc-gssd's machine credentials.
#
# Strict pass/fail:
#  - expected rejections must specifically yield EACCES ("Permission denied");
#    a timeout (124), missing creds, or I/O error is a FAILURE, not authz success;
#  - a downgrade mount must be a real rejection, not a timeout;
#  - the confidentiality check only passes if the canary was actually written
#    AND is absent from the capture.
# Exits nonzero on any violated expectation.
set -Eeuo pipefail

CALLER="${SUDO_USER:-${USER}}"
PEER_ENV="/home/${CALLER}/ws-peer.env"
EVID="/home/${CALLER}/ws-evidence"
[ -f "$PEER_ENV" ]      || { echo "missing $PEER_ENV" >&2; exit 1; }
[ -f /etc/krb5.keytab ] || { echo "missing /etc/krb5.keytab (run peer-bootstrap with peer.keytab)" >&2; exit 1; }
# shellcheck disable=SC1090
. "$PEER_ENV"
mkdir -p "$EVID"; chown "$CALLER:$CALLER" "$EVID"
: > "$EVID/03-positive.txt"
: > "$EVID/04-negatives.txt"
: > "$EVID/05-crosstenant.txt"
: > "$EVID/06-capture.txt"
HARDFAIL=0
CMDRC=0
LASTOUT=""

log()  { printf '\n=== %s ===\n' "$*"; }
fail() { echo "   *** EXPECTATION VIOLATION: $1" | tee -a "$EVID/$2"; HARDFAIL=1; }
as_user() { sudo -u "$1" "${@:2}"; }
# Run as a user, set GLOBAL CMDRC and LASTOUT (stderr). Never call under $(...) —
# that would lose CMDRC to a subshell.
runsee() { local u="$1"; shift; set +e; LASTOUT=$(as_user "$u" "$@" 2>&1 >/dev/null); CMDRC=$?; set -e; }
rec() { printf '%s\n' "$LASTOUT" >> "$EVID/$1"; }

cleanup() {
  set +e
  for m in /mnt/ws1 /mnt/ws2 /mnt/ws1cap /mnt/wsneg; do umount "$m" 2>/dev/null; umount -f "$m" 2>/dev/null; done
  kdestroy 2>/dev/null
  as_user ws1peer kdestroy 2>/dev/null
  as_user ws2peer kdestroy 2>/dev/null
  rm -f /tmp/krb5cc_0 /tmp/krb5cc_10001 /tmp/krb5cc_10002 /tmp/ws1-suite.sh 2>/dev/null
  chown "$CALLER:$CALLER" "$EVID"/* 2>/dev/null || true
}
trap cleanup EXIT

log "acquire credentials (per-uid)"
KINIT_HINT="kinit failed; if server-bootstrap.sh was re-run, re-transfer peer.env (password may have changed)"
echo "${WS_ws1_PASS}" | kinit "${WS_ws1_USER}@${REALM}" \
  || fail "root kinit for ${WS_ws1_USER} failed: $KINIT_HINT" 03-positive.txt   # root uid 0 -> mount()
echo "${WS_ws1_PASS}" | as_user ws1peer kinit "${WS_ws1_USER}@${REALM}" \
  || fail "ws1peer kinit failed: $KINIT_HINT" 03-positive.txt                  # uid 10001
echo "${WS_ws2_PASS}" | as_user ws2peer kinit "${WS_ws2_USER}@${REALM}" \
  || fail "ws2peer kinit failed: $KINIT_HINT" 05-crosstenant.txt               # uid 10002
as_user ws1peer klist >/dev/null || fail "ws1peer has no TGT" 03-positive.txt
as_user ws2peer klist >/dev/null || fail "ws2peer has no TGT" 05-crosstenant.txt

log "POSITIVE: root mounts /ws1; ws1peer runs the FS suite"
mount -t nfs4 -o sec=krb5p,vers=4.1,actimeo=0 "${FQDN}:/ws1" /mnt/ws1 \
  || fail "mount /ws1 sec=krb5p failed" 03-positive.txt
{ echo "## mount"; mount | grep /mnt/ws1; echo "## ws1peer ccache"; as_user ws1peer klist; } >> "$EVID/03-positive.txt"
M="hello-ws1-$(date +%s)"
cat > /tmp/ws1-suite.sh <<EOF
#!/usr/bin/env bash
set -e
cd /mnt/ws1
echo "${M}" > marker.txt
[ "\$(cat marker.txt)" = "${M}" ] || exit 11
mkdir -p sub && echo x > sub/a && mv sub/a sub/b && ln -s b sub/link
head -c 1048576 /dev/urandom > big.bin && rm -f big.bin
rm -rf sub
EOF
if as_user ws1peer bash /tmp/ws1-suite.sh >>"$EVID/03-positive.txt" 2>&1; then
  echo "   PASS (ws1peer write/readback/rename/symlink/largefile)" | tee -a "$EVID/03-positive.txt"
else
  fail "ws1peer FS suite failed (marker.txt left for cross-tenant)" 03-positive.txt
fi

log "NEGATIVES: weaker flavors must be denied with an access/security-flavor rejection"
NOAUTH='resolve|name or service not known|connection refused|no route|unreachable|network is down|network is unreachable|mount point|does not exist|not a directory|bad option|unknown option|incorrect mount option|invalid argument'
# "operation not permitted" (EPERM) on a forced sec=<flavor> mount to a krb5p-only
# export is the client refusing to auto-upgrade after NFS4ERR_WRONGSEC/SECINFO — a
# legitimate rejection, not a transport/option error.
DENIED='access denied|denied by server|authentication|permission denied|operation not permitted|credentials|protocol not supported|required'
for f in sys krb5 krb5i; do
  echo "+ sec=$f must be denied (not accepted, not timed out, not a DNS/transport/mountpoint/option error)" | tee -a "$EVID/04-negatives.txt"
  set +e
  err=$(timeout 30 mount -t nfs4 -o "sec=${f},vers=4.1,soft,timeo=20,retrans=1,actimeo=0" "${FQDN}:/ws1" /mnt/wsneg 2>&1)
  rc=$?
  set -e
  printf '%s\n' "$err" >> "$EVID/04-negatives.txt"
  if [ "$rc" -eq 0 ]; then
    umount /mnt/wsneg 2>/dev/null || true
    fail "sec=$f was ACCEPTED by the export" 04-negatives.txt
  elif [ "$rc" -eq 124 ]; then
    fail "sec=$f timed out (ambiguous; not a clean rejection)" 04-negatives.txt
  elif printf '%s' "$err" | grep -qiE "$NOAUTH"; then
    fail "sec=$f failed for a non-authz reason: $(printf '%s' "$err" | tr '\n' ' ')" 04-negatives.txt
  elif printf '%s' "$err" | grep -qiE "$DENIED"; then
    echo "   PASS (sec=$f denied, exit $rc)" | tee -a "$EVID/04-negatives.txt"
  else
    fail "sec=$f failed with unexpected error: $(printf '%s' "$err" | tr '\n' ' ')" 04-negatives.txt
  fi
done

log "CROSS-TENANT: wrong principal must get EACCES (not timeout/IO/missing-creds)"
runsee ws1peer cat /mnt/ws1/marker.txt; rec 05-crosstenant.txt
if [ "$CMDRC" -eq 0 ]; then
  echo "   PASS control (ws1peer reads own /ws1 marker)" | tee -a "$EVID/05-crosstenant.txt"
else
  fail "ws1peer could not read own marker; test invalid" 05-crosstenant.txt
fi
runsee ws2peer cat /mnt/ws1/marker.txt; rec 05-crosstenant.txt
if [ "$CMDRC" -ne 0 ] && printf '%s' "$LASTOUT" | grep -qi "permission denied"; then
  echo "   PASS (ws2peer denied EACCES on /ws1, exit $CMDRC)" | tee -a "$EVID/05-crosstenant.txt"
else
  fail "ws2peer on /ws1 got rc=$CMDRC; expected EACCES" 05-crosstenant.txt
fi

mount -t nfs4 -o sec=krb5p,vers=4.1,actimeo=0 "${FQDN}:/ws2" /mnt/ws2 \
  || fail "mount /ws2 sec=krb5p failed" 05-crosstenant.txt
runsee ws2peer sh -c 'echo ws2secret > /mnt/ws2/ws2-marker.txt'; rec 05-crosstenant.txt
if [ "$CMDRC" -eq 0 ]; then
  echo "   PASS control (ws2peer writes own /ws2)" | tee -a "$EVID/05-crosstenant.txt"
else
  fail "ws2peer could not write own /ws2" 05-crosstenant.txt
fi
runsee ws2peer cat /mnt/ws2/ws2-marker.txt; rec 05-crosstenant.txt
if [ "$CMDRC" -ne 0 ]; then
  fail "ws2peer could not read own marker; test invalid" 05-crosstenant.txt
fi
runsee ws1peer cat /mnt/ws2/ws2-marker.txt; rec 05-crosstenant.txt
if [ "$CMDRC" -ne 0 ] && printf '%s' "$LASTOUT" | grep -qi "permission denied"; then
  echo "   PASS (ws1peer denied EACCES on /ws2, exit $CMDRC)" | tee -a "$EVID/05-crosstenant.txt"
else
  fail "ws1peer on /ws2 got rc=$CMDRC; expected EACCES" 05-crosstenant.txt
fi

log "CAPTURE: fresh mount + canary write; assert encrypted on the wire"
CANARY="wscanary$(head -c 8 /dev/urandom | od -An -tu1 | tr -d ' \n')"
PCAP="$EVID/06-rpc.pcap"
tcpdump -i any -w "$PCAP" -U "host ${FQDN}" >/dev/null 2>&1 &
TCPD=$!
sleep 1
if ! kill -0 "$TCPD" 2>/dev/null; then
  fail "tcpdump failed to start" 06-capture.txt
else
  echo "   tcpdump running (pid $TCPD)" | tee -a "$EVID/06-capture.txt"
fi
mount -t nfs4 -o sec=krb5p,vers=4.1,actimeo=0 "${FQDN}:/ws1" /mnt/ws1cap 2>>"$EVID/06-capture.txt" \
  || fail "fresh capture mount failed" 06-capture.txt
# The canary write MUST succeed: only then does its plaintext traverse the wire
# inside the WRITE RPC, and only then is its absence from the capture meaningful.
CANARY_OK=0
if as_user ws1peer sh -c "echo ${CANARY} > /mnt/ws1cap/canary.txt && cat /mnt/ws1cap/canary.txt" >>"$EVID/06-capture.txt" 2>&1; then
  CANARY_OK=1
  echo "   canary written+read back" | tee -a "$EVID/06-capture.txt"
else
  fail "canary write/read failed; confidentiality test invalid" 06-capture.txt
fi
sleep 2
kill "$TCPD" 2>/dev/null || true; wait "$TCPD" 2>/dev/null || true
umount /mnt/ws1cap 2>/dev/null || true
[ -s "$PCAP" ] || fail "pcap empty" 06-capture.txt
N2049=$(tcpdump -r "$PCAP" -nn 'tcp port 2049' 2>/dev/null | wc -l)
echo "   tcp/2049 packets captured: $N2049" | tee -a "$EVID/06-capture.txt"
[ "$N2049" -gt 0 ] || fail "no tcp/2049 packets in capture" 06-capture.txt
echo "   canary value: $CANARY" | tee -a "$EVID/06-capture.txt"
if [ "$CANARY_OK" -eq 1 ]; then
  if grep -a -q "$CANARY" "$PCAP"; then
    fail "CANARY PLAINTEXT FOUND IN PCAP -> payload NOT encrypted" 06-capture.txt
  else
    echo "   PASS (canary absent from capture -> krb5p confidentiality)" | tee -a "$EVID/06-capture.txt"
  fi
fi

chown "$CALLER:$CALLER" "$EVID"/* 2>/dev/null || true
log "DONE (HARDFAIL=$HARDFAIL)"
echo "evidence: $EVID/{03,04,05}.txt 06-rpc.pcap"
[ "$HARDFAIL" -eq 0 ]
