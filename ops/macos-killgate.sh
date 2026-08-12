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
# artifact uploads regardless. Invalid test setup, such as a missing password,
# fails the job after recording the reason.
#
# Built-in tools only: kinit / kvno / klist / kdestroy / mount_nfs (Heimdal +
# Apple XNU nfs client). No Homebrew, no /etc writes, no persistent system
# changes (criterion #8) — Kerberos config is isolated under $RUNNER_TEMP and
# pointed at via KRB5_CONFIG; each user uses macOS's native API credential cache
# so the separately launched gssd can discover its tickets.
set -uo pipefail

# --- env (REALM/FQDN/WS_USER/SPN/WS_PATH are public via DNS; only WS_PASS is secret) ---
: "${REALM:=WORK.SOPHASTRA.COM}"
: "${FQDN:=work.sophastra.com}"
: "${WS_USER:=w/ws1}"
: "${SPN:=nfs/work.sophastra.com}"
: "${WS_PATH:=ws1}"
: "${WS_PASS:=}"
: "${RUNNER_TEMP:=/tmp}"
: "${EXPECTED_MACOS_MAJOR:=26}"
: "${EXPECTED_MACOS_VERSION:=}"

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

# Fail closed if CI is accidentally pinned to an older macOS generation. This
# exact mismatch previously let a Sonoma result stand in for the Tahoe target.
MACOS_VERSION="$(sw_vers -productVersion)"
MACOS_MAJOR="${MACOS_VERSION%%.*}"
if [ "$MACOS_MAJOR" != "$EXPECTED_MACOS_MAJOR" ]; then
  say "FATAL: expected macOS major ${EXPECTED_MACOS_MAJOR}, got ${MACOS_VERSION}; kill-gate is invalid"
  exit 1
fi
if [ -n "$EXPECTED_MACOS_VERSION" ] && [ "$MACOS_VERSION" != "$EXPECTED_MACOS_VERSION" ]; then
  say "FATAL: expected macOS ${EXPECTED_MACOS_VERSION}, got ${MACOS_VERSION}; kill-gate is invalid"
  exit 1
fi
say "version gate passed — macOS ${MACOS_VERSION} satisfies Tahoe major ${EXPECTED_MACOS_MAJOR}"

if [ -z "$WS_PASS" ]; then
  say "FATAL: WS_PASS empty — set the WS_WS1_PASS repo secret (w/ws1 password from cocoroco peer.env). Nothing else will run."
  exit 1
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

# Apple documents an omitted NFSv4 minor as v4.0, so test explicit v4.1 first.
# Sonoma 14.8.7 rejected vers=4.1 as illegal, but that does not establish what
# current Tahoe accepts. Keep explicit v4.0 and v3 controls for diagnosis.
V41K="vers=4.1,sec=krb5p"
V40K="vers=4,sec=krb5p"
V3K="vers=3,sec=krb5p"
WOPTS=""; WPATH=""   # first winning variant — consumed by Phase B

# --- Phase A: admin mount matrix (criterion #5 interop) ---
say "PHASE A — admin mount matrix (isolate macOS requirement)"
unset KRB5CCNAME
PWFILE="$RUNNER_TEMP/pw-admin"; printf '%s' "$WS_PASS" > "$PWFILE"; chmod 600 "$PWFILE"
cap kinit --password-file="$PWFILE" "${WS_USER}@${REALM}"
cap klist
cap "$KVSC" "${SPN}@${REALM}"
cap klist

# try_mount <label> <opts> <path> <mnt> — logs result; sets WOPTS/WPATH on first success
try_mount() {
  local label="$1" opts="$2" path="$3" mnt="$4"
  say "TRY $label : opts={$opts} path={$path}"
  "$TOSC" 60 mount_nfs -o "$opts" "${FQDN}:${path}" "$mnt" 2>&1 | tee -a "$LOG" >&2
  if mount | grep -q "$(basename "$mnt")"; then
    say "  -> $label MOUNTED (success)"
    [ -z "$WOPTS" ] && { WOPTS="$opts"; WPATH="$path"; }
    return 0
  fi
  say "  -> $label failed"
  return 1
}
for v in m1 m2 m3 m4 m5 m6; do mkdir -p "$RUNNER_TEMP/$v"; done
try_mount "v4.1+krb5p /${WS_PATH}"         "$V41K" "/${WS_PATH}"        "$RUNNER_TEMP/m1"
try_mount "v4.1+krb5p /export/${WS_PATH}"  "$V41K" "/export/${WS_PATH}" "$RUNNER_TEMP/m2"
try_mount "v4.0+krb5p /${WS_PATH}"         "$V40K" "/${WS_PATH}"        "$RUNNER_TEMP/m3"
try_mount "v4.0+krb5p /export/${WS_PATH}"  "$V40K" "/export/${WS_PATH}" "$RUNNER_TEMP/m4"
try_mount "v3+krb5p /${WS_PATH}"           "$V3K"  "/${WS_PATH}"        "$RUNNER_TEMP/m5"
try_mount "v3+krb5p /export/${WS_PATH}"    "$V3K"  "/export/${WS_PATH}" "$RUNNER_TEMP/m6"
say "PHASE A RESULT: winner = ${WOPTS:+opts={$WOPTS} path={$WPATH}}${WOPTS:-<none of the 6 variants mounted>}"
for v in m1 m2 m3 m4 m5 m6; do "$TOSC" 15 umount "$RUNNER_TEMP/$v" 2>/dev/null || true; done
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
  WSB_PWFILE="/tmp/ws_pw_wstest"
  printf '%s' "$WS_PASS" > "$WSB_PWFILE"; chmod 644 "$WSB_PWFILE"
  WSB_MNT="/Users/wstest/RemoteWorkspace"
  sudo -u wstest mkdir -p "$WSB_MNT"
  cap sudo -u wstest env -u KRB5CCNAME "KRB5_CONFIG=$WSB_KRB5CONF" \
    kinit --password-file="$WSB_PWFILE" "${WS_USER}@${REALM}"
  cap sudo -u wstest env -u KRB5CCNAME "KRB5_CONFIG=$WSB_KRB5CONF" klist
  cap sudo -u wstest env -u KRB5CCNAME "KRB5_CONFIG=$WSB_KRB5CONF" \
    "$KVSC" "${SPN}@${REALM}"
  if [ -z "$WOPTS" ]; then
    say "PHASE B SKIPPED — no admin variant mounted in Phase A (same RPC blocker); criterion #4 untestable until Phase A is resolved"
  else
    cap sudo -u wstest env -u KRB5CCNAME "KRB5_CONFIG=$WSB_KRB5CONF" \
      "$TOSC" 60 mount_nfs -o "$WOPTS" "${FQDN}:${WPATH}" "$WSB_MNT"
    if mount | grep -q "RemoteWorkspace"; then
      say "PHASE B RESULT: NON-ADMIN MOUNT SUCCEEDED — criterion #4 PASSES (variant: opts={$WOPTS} path={$WPATH})"
      cap sudo -u wstest bash -c "echo hello-from-mac-nonadmin-\$(date +%s) > '$WSB_MNT/marker-nonadmin.txt' && cat '$WSB_MNT/marker-nonadmin.txt'"
      cap "$TOSC" 30 sudo umount "$WSB_MNT"
    else
      say "PHASE B RESULT: NON-ADMIN MOUNT FAILED — admin worked, non-admin did not (criterion #4 negative; see error above)"
    fi
  fi
  sudo -u wstest env -u KRB5CCNAME kdestroy 2>/dev/null || true
  sudo rm -f "$WSB_PWFILE"
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
