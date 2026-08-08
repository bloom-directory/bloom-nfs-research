#!/usr/bin/env bash
# macOS kill-gate for pm#38 Step 7. Runs INSIDE a GitHub-hosted macOS runner
# against the Linux NFSv4.1 + krb5p server on cocoroco (work.sophastra.com).
#
# Two phases, both recorded to a transcript that is always uploaded:
#   A. ADMIN mount (as the runner user) — does macOS mount_nfs + sec=krb5p
#      interoperate with Linux NFSD at all? (criterion #5, the foundational
#      unknown — if this fails, no-admin is moot)
#   B. NON-ADMIN mount (as a freshly created non-admin user) — does it work
#      without administrator privileges? (criterion #4, the real pm#38 claim)
#
# Negative results are VALID evidence. The script never aborts on a mount
# failure; it records the error and continues, exiting 0 so the transcript
# artifact uploads regardless. The only thing it cannot tolerate silently is
# a missing password (it will still produce a transcript explaining that).
#
# Built-in tools only: kinit / kvno / klist / kdestroy / mount_nfs (Heimdal +
# Apple XNU nfs client). No Homebrew, no /etc writes, no persistent system
# changes (criterion #8) — Kerberos config is isolated under $RUNNER_TEMP and
# pointed at via KRB5_CONFIG; the ccache is a per-uid FILE under $RUNNER_TEMP.
set -uo pipefail

# --- env (REALM/FQDN/WS_USER/SPN/WS_PATH are public via DNS; only WS_PASS is secret) ---
: "${REALM:=WORK.SOPHASTRA.COM}"
: "${FQDN:=work.sophastra.com}"
: "${WS_USER:=w/ws1}"
: "${SPN:=nfs/work.sophastra.com}"
: "${WS_PATH:=ws1}"
: "${WS_PASS:=}"
: "${RUNNER_TEMP:=/tmp}"

LOG="$RUNNER_TEMP/killgate.txt"
: > "$LOG"
say() { printf '\n=== %s ===\n' "$*" | tee -a "$LOG" >&2; }
cap() { printf '+ %s\n' "$*" | tee -a "$LOG" >&2; "$@" 2>&1 | tee -a "$LOG" >&2; }
# macOS has no `timeout` and no `kvno`. Create executable helpers in $RUNNER_TEMP
# so they work both in the main shell AND under `sudo -u ... env ...` (bash
# functions are invisible there — that bit us in run 1: the non-admin mount
# never actually executed). alarm() timers persist across exec, so the wrapper
# kills the child after Ns.
TOSC="$RUNNER_TEMP/to"
cat > "$TOSC" <<'EOF'
#!/usr/bin/env bash
perl -e 'alarm shift; exec @ARGV' "$@"
EOF
chmod +x "$TOSC"
KVSC="$RUNNER_TEMP/kvno-prefetch"
cat > "$KVSC" <<'EOF'
#!/usr/bin/env bash
P="${1:?usage: kvno-prefetch <principal>}"
if command -v kvno >/dev/null 2>&1; then kvno "$P"
elif command -v kgetcred >/dev/null 2>&1; then kgetcred "$P"
else echo "(no kvno/kgetcred on this OS — mount_nfs/GSS will acquire the service ticket)"; fi
EOF
chmod +x "$KVSC"

say "macOS kill-gate — built-in kinit/mount_nfs, no install, principal=${WS_USER}@${REALM}"
cap sw_vers
cap uname -a
cap bash --version
cap sh -c 'command -v kinit kvno klist kdestroy mount_nfs 2>&1; true'

if [ -z "$WS_PASS" ]; then
  say "FATAL: WS_PASS empty — set the WS_WS1_PASS repo secret (w/ws1 password from cocoroco peer.env). Nothing else will run."
  exit 0
fi

# Isolated krb5.conf (no /etc write; criterion #8).
KRB5CONF="$RUNNER_TEMP/krb5.conf"
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

# Criterion #8: snapshot system state BEFORE.
say "before-snapshot (criterion #8 — must match after)"
cap ls -la /etc/krb5.conf
cap ls -la /etc/idmapd.conf
cap ls -la "$HOME/Library/LaunchAgents" 2>&1 || true

# Reachability preflight (separates network failure from auth failure).
say "reachability preflight"
cap bash -c "echo > /dev/tcp/${FQDN}/88"   && echo "tcp/88 OK"   | tee -a "$LOG" >&2 || echo "tcp/88 FAIL"   | tee -a "$LOG" >&2
cap bash -c "echo > /dev/tcp/${FQDN}/2049" && echo "tcp/2049 OK" | tee -a "$LOG" >&2 || echo "tcp/2049 FAIL" | tee -a "$LOG" >&2

# macOS mount_nfs takes the MAJOR version only (vers=4); the 4.1 minor is
# negotiated via EXCHANGE_ID. vers=4.1 (Linux syntax) is rejected with
# "illegal NFS version value" — seen in run 1.
MOUNT_OPTS="vers=4,sec=krb5p,principal=${WS_USER}@${REALM},sprincipal=${SPN}@${REALM}"

# --- Phase A: admin mount (runner user) ---
say "PHASE A — admin mount (criterion #5 interop)"
CCACHE="FILE:$RUNNER_TEMP/ccache-admin"; export KRB5CCNAME="$CCACHE"
PWFILE="$RUNNER_TEMP/pw-admin"; printf '%s' "$WS_PASS" > "$PWFILE"; chmod 600 "$PWFILE"
cap kinit --password-file="$PWFILE" "${WS_USER}@${REALM}"
cap klist
cap "$KVSC" "${SPN}@${REALM}"
cap klist
MNT_A="$RUNNER_TEMP/mnt-admin"; mkdir -p "$MNT_A"
cap "$TOSC" 60 mount_nfs -o "$MOUNT_OPTS" "${FQDN}:/${WS_PATH}" "$MNT_A"
if mount | grep -q "$(basename "$MNT_A")"; then
  say "PHASE A RESULT: MOUNT SUCCEEDED — macOS+krb5p interop with Linux NFSD works"
  cap ls -la "$MNT_A"
  cap bash -c "echo hello-from-mac-admin-\$(date +%s) > '$MNT_A/marker-admin.txt' && cat '$MNT_A/marker-admin.txt'"
  cap "$TOSC" 30 umount "$MNT_A"
else
  say "PHASE A RESULT: MOUNT FAILED — interop negative (see captured error above)"
fi
cap kdestroy 2>/dev/null || true
rm -f "$PWFILE"

# --- Phase B: non-admin mount (criterion #4) ---
say "PHASE B — non-admin mount (criterion #4: NO administrator)"
say "create non-admin user 'wstest' (PrimaryGroupID 20 = staff, NOT 80 = admin)"
sudo dscl . -delete /Users/wstest 2>/dev/null || true
NEWUID="$(dscl . -list /Users UniqueID | awk '{print $2}' | sort -n | tail -1)"
NEWUID=$((NEWUID + 1))
sudo dscl . -create /Users/wstest UniqueID "$NEWUID"
sudo dscl . -create /Users/wstest UserShell /bin/bash
sudo dscl . -create /Users/wstest PrimaryGroupID 20
sudo dscl . -create /Users/wstest NFSHomeDirectory /Users/wstest
sudo mkdir -p /Users/wstest && sudo chown wstest:staff /Users/wstest
cap id wstest
cap dscl . -read /Users/wstest NFSHomeDirectory PrimaryGroupID

if id wstest >/dev/null 2>&1; then
  WSB_KRB5CONF="$RUNNER_TEMP/krb5.conf"
  WSB_CCACHE="FILE:/tmp/krb5cc_wstest"
  WSB_PWFILE="/tmp/ws_pw_wstest"
  printf '%s' "$WS_PASS" > "$WSB_PWFILE"; chmod 644 "$WSB_PWFILE"
  WSB_MNT="/Users/wstest/RemoteWorkspace"
  sudo -u wstest mkdir -p "$WSB_MNT"
  cap sudo -u wstest env "KRB5CCNAME=$WSB_CCACHE" "KRB5_CONFIG=$WSB_KRB5CONF" \
    kinit --password-file="$WSB_PWFILE" "${WS_USER}@${REALM}"
  cap sudo -u wstest env "KRB5CCNAME=$WSB_CCACHE" "KRB5_CONFIG=$WSB_KRB5CONF" klist
  cap sudo -u wstest env "KRB5CCNAME=$WSB_CCACHE" "KRB5_CONFIG=$WSB_KRB5CONF" \
    "$KVSC" "${SPN}@${REALM}"
  cap sudo -u wstest env "KRB5CCNAME=$WSB_CCACHE" "KRB5_CONFIG=$WSB_KRB5CONF" \
    "$TOSC" 60 mount_nfs -o "$MOUNT_OPTS" "${FQDN}:/${WS_PATH}" "$WSB_MNT"
  if mount | grep -q "RemoteWorkspace"; then
    say "PHASE B RESULT: NON-ADMIN MOUNT SUCCEEDED — criterion #4 PASSES"
    cap sudo -u wstest bash -c "echo hello-from-mac-nonadmin-\$(date +%s) > '$WSB_MNT/marker-nonadmin.txt' && cat '$WSB_MNT/marker-nonadmin.txt'"
    cap "$TOSC" 30 sudo umount "$WSB_MNT"
  else
    say "PHASE B RESULT: NON-ADMIN MOUNT FAILED — criterion #4 NEGATIVE (valid evidence; see captured error above)"
  fi
  sudo -u wstest env "KRB5CCNAME=$WSB_CCACHE" kdestroy 2>/dev/null || true
  sudo rm -f "$WSB_PWFILE" "$WSB_CCACHE"
else
  say "PHASE B SKIPPED — could not create wstest user (criterion #4 not tested)"
fi

# Criterion #8: after-snapshot (must match before).
say "after-snapshot (criterion #8 — must match before)"
cap ls -la /etc/krb5.conf
cap ls -la /etc/idmapd.conf
cap ls -la "$HOME/Library/LaunchAgents" 2>&1 || true

say "cleanup"
sudo dscl . -delete /Users/wstest 2>/dev/null || true
sudo rm -rf /Users/wstest 2>/dev/null || true

say "TRANSCRIPT COMPLETE — upload killgate.txt artifact for evidence"
exit 0
