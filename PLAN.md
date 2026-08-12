# Plan: satisfy bloom-directory/pm#38

Zero-Install Remote Filesystems via Internet-Facing NFS.

> Determine whether a wallet-authenticated user can obtain temporary credentials
> and mount an isolated remote workspace on macOS Tahoe using only built-in
> operating-system tools, without administrator privileges or persistent system
> changes, while retaining confidentiality, hard expiry, and acceptable recovery
> after network transitions.

A negative result is a valid outcome. The objective is to establish whether the
experience works, not to force NFS into production.

## Resolved inputs

- **Realm / DNS zone.** `work.sophastra.com` delegated. Realm
  `WORK.SOPHASTRA.COM`; DNS discovery is testable (publish `_kerberos._tcp`/
  `_udp` SRV + realm TXT under this zone). Initial workspace FQDN
  `work.sophastra.com` points at cocoroco's public IP; per-workspace FQDNs are
  `<workspace>.work.sophastra.com`.
- **Second Linux peer.** `kyle@apps` (SSH) — the stand-in client that proves
  the Linux track and plays the Mac's role until the macOS kill gate runs.
- **macOS device.** A physical arm64 macOS 26.5.2 device passed the built-in,
  no-sudo NFSv4.1 `krb5p` mount and filesystem suite. GitHub-hosted Tahoe
  runners (`macos-26` Apple Silicon, `macos-26-intel` Intel) remain the
  reproducible standard-account gate; a physical laptop is still required for
  real sleep and Wi-Fi/hotspot roaming.

## Current live state

- **cocoroco.** The disposable KDC/NFS reference is active for the corrected
  macOS reruns and must be torn down when testing completes.
- **Linux peer.** The original Linux proof remains valid, but `kyle@apps`
  refused SSH connections during the Tahoe rerun and could not be repeated.

## Status labels

- `SERVER-PASS` — proven on Linux server/peers; does not yet prove macOS
  end-to-end behavior.
- `CI-MAC` — executable on a GitHub-hosted macOS runner without owning hardware.
- `DEVICE-MAC` — requires a physical macOS laptop (only criterion #7).
- `BLOCKED-PREREQ` — waiting on the cocoroco / `kyle@apps` reconfirm.

## Why bloom-workspaces does not already close this issue

`bloom-directory/bloom-workspaces` carries one comment on pm#38 claiming a
"working implementation." That repo explicitly rejected the direct public
NFS+Kerberos path (`docs/nfs-research.md:3`) and ships AUTH_SYS over an
SSH-certificate WebSocket tunnel, requiring an admin mount on macOS
(`src/nfs/client-plan.ts:57`). Against pm#38's own success criteria it fails:

- #3 no software install — needs a Node proxy helper;
- #4 no administrator — `mount` requires privilege;
- #5 transport confidentiality — AUTH_SYS in a tunnel, not `krb5p`;
- #7 reconnect after sleep/roam — `docs/threat-model.md:57` concedes hard
  mounts stall;
- #8 no persistent system changes — unverified.

So pm#38 remains genuinely open. This effort produces the focused evidence the
existing repo deliberately deferred.

## pm#38 acceptance ledger

| # | Criterion (pm#38) | Exact test | Evidence required | Status |
|---|---|---|---|---|
| 1 | Authenticate through a browser | SIWE sign; session issued (runner browser or real device) | signed message, session token hash, server log | CI-MAC |
| 2 | Receive short-lived filesystem access | lease + principal minted with TTL cap | `kadmin` principal record, lease timestamp | BLOCKED-PREREQ |
| 3 | Mount on macOS without installing software | built-in `kinit` + `mount_nfs` only | `sw_vers`, transcript, no Homebrew/pkg deps | CI-MAC |
| 4 | Mount without administrator privileges | non-admin user inside the runner mounts; sudo never invoked | transcript, `mount` output, exit code | CI-MAC |
| 5 | Read/write with transport confidentiality | `sec=krb5p`; AUTH_SYS/krb5/krb5i rejected; payload encrypted | tcpdump, rejected-flavor logs, macOS interop | SERVER-PASS after Step B; macOS interop CI-MAC |
| 6 | Lose access at session expiry | three outcomes measured (below) | security/cache/availability transcripts | SERVER-PASS after Step 5; macOS hang CI-MAC |
| 7 | Reconnect after sleep / network transition | sleep, wake, Wi-Fi/hotspot switch | before/after `ls`, timing, recovery or hang | DEVICE-MAC |
| 8 | No persistent system modification | no `/etc`, profiles, launch agents writes; isolated ccache cleaned | before/after snapshots, `klist`/`mount`/process checks | CI-MAC |

Initial pass/fail thresholds (from pm#38 and the recommendation):

- No downloaded executable or package on macOS.
- No sudo or administrator approval.
- No edits under `/etc`, profiles, launch agents, or system settings.
- A `$TMPDIR` file is permitted only if deleted during cleanup.
- Entire payload protected with `krb5p`.
- Expired access stops within 60 seconds (security outcome; see expiry split).
- Filesystem calls on a dead server fail or recover within 60 seconds
  (availability outcome — may require `deadtimeout`/soft; document the risk).
- A valid lease survives sleep or network transition without data loss.
- Cleanup leaves no mount, ticket, credential, or background process.

pm#38 deliverables checklist:

- [ ] Documented macOS setup and command sequence
- [ ] Confirmed sudo and non-sudo behaviour
- [ ] Threat model for direct Internet-facing NFS
- [ ] Comparison: direct `krb5p`; NFS over Tailscale/WireGuard; NFS over SSH; WebDAV/HTTPS
- [ ] Wallet-to-temporary-credential architecture
- [ ] Prototype deployment scripts
- [ ] Recommendation: production / onboarding / demo / internal-prototype / reject

## Architecture under test

```
Browser --(SIWE)--> control plane --(narrow Unix socket)--> broker
broker --> KDC (port 88)
broker --> per-workspace NFSv4.1 server (port 2049, krb5p only)
broker --> ephemeral DNS + endpoint
host-enforced per-workspace expiry timer (independent of broker)
macOS built-in kinit --> KDC 88
macOS built-in mount_nfs (krb5p) --> NFS server 2049
```

Server-side invariants (corrected):

- Dedicated MIT Kerberos KDC, one realm `WORK.SOPHASTRA.COM` under a delegated zone.
- Linux kernel NFSD, NFSv4.1 only; v2/v3, mountd, rpcbind not exposed publicly.
- AES enctypes reconciled explicitly between MIT KDC and Apple Heimdal
  (AES256-CTS-HMAC-SHA1-96 / AES128-...); clock synchronized to <5 min skew
  (chrony/ntp) before any auth test.
- One opaque user principal `w/<random>@WORK.SOPHASTRA.COM` per workspace, short TTL,
  non-forwardable, non-renewable, pre-auth required.
- One `nfs/<WORKSPACE-FQDN>@WORK.SOPHASTRA.COM` service principal + keytab per server,
  never sent to the client.
- **No `all_squash`.** Authorization is per-workspace principal-to-UID via
  `idmapd.conf` static mapping (`GSS-Methods = static`), distinct Unix users,
  and mode-0700 workspace roots. Kerberos authenticates; it does not authorize
  (RFC 4120 §10). Distinct hostnames/service principals alone are insufficient
  because an authenticated user can request tickets for other services. Stronger
  alternative recorded for the threat model: a separate realm/KDC per workspace
  trust boundary.
- Export accepts only `sec=krb5p`; `insecure` set so the client need not use a
  reserved source port.
- **Expiry is host-enforced, not broker-enforced.** A per-workspace independent
  timer (systemd timer / VM shutdown / lease-gated firewall rule) continues
  while the broker is down. Broker restart performs idempotent reconciliation
  and cleanup, but is not the hard deadline.

Destruction order (security revocation, independent of client cooperation):

1. remove public endpoint/ports (firewall);
2. stop `nfs-server` / VM;
3. delete user principal;
4. delete service principal + keytab;
5. destroy disposable data;
6. remove DNS.

## Execution sequence

This follows the ordering that is confidence-rated. macOS-bound steps remain
last.

### Step 1 — Publish DNS discovery records

Realm and zone are resolved (`WORK.SOPHASTRA.COM` / `work.sophastra.com`, peer
`kyle@apps`). Publish the Kerberos discovery records under the delegated zone:
`_kerberos._tcp` and `_kerberos._udp` SRV pointing at cocoroco's port 88, the
realm TXT record, and an A record for `work.sophastra.com` at cocoroco's public
IP. Also prepare the `$TMPDIR/krb5.conf` fallback so the macOS runner can test
both DNS discovery and explicit config paths.

Exit gate: `_kerberos._tcp.WORK.SOPHASTRA.COM` SRV resolves externally; a
`dig`/`host` transcript is captured.

### Step 2 — Restore/confirm cocoroco and kyle@apps reachability

Re-run the read-only preflight against cocoroco (hostname, OS, running services,
`/etc/exports`, ports 88/2049, `id`) and confirm SSH to `kyle@apps`. SSH from
this environment timed out once; confirm both before any install.

### Step 3 — Single-workspace Kerberos/NFSD reference, no all_squash

Build on cocoroco: MIT KDC for `WORK.SOPHASTRA.COM`; `nfs/<WORKSPACE-FQDN>` service
principal + keytab; one user principal `w/ws1@WORK.SOPHASTRA.COM`; NFSv4.1-only export
with `sec=krb5p`, `insecure`, principal-to-UID static mapping, distinct Unix
user `ws1` with mode-0700 root; AES enctypes pinned; clock synced.

Exit gate: from the second Linux peer, `mount -t nfs4 -o
sec=krb5p,vers=4.1 <WORKSPACE-FQDN>:/ /mnt` succeeds with `w/ws1`'s ticket;
AUTH_SYS/`krb5`/`krb5i` all fail with captured errors. Captures: `exportfs -v`,
`nfsconf` versions, `idmapd.conf`, `klist`, peer transcript, encrypted-RPC
tcpdump.

### Step 4 — Add a second workspace/principal; prove cross-tenant denial

Add `w/ws2@WORK.SOPHASTRA.COM` mapped to Unix user `ws2` with a separate mode-0700 root.
Confirm `w/ws1` cannot read ws2's root and vice versa, both holding valid
tickets for the realm. This is the real authorization test that `all_squash`
would have defeated.

Exit gate: cross-tenant read/write denied at the filesystem layer; same-realm
ticket-for-other-service does not grant cross-workspace access.

### Step 5 — Broker-independent expiry; measure the three outcomes separately

Hard NFS mounts can hang indefinitely when the server disappears (Apple
mount_nfs(8)). Stopping NFSD is security revocation, not proof that calls fail
within 60 seconds. Measure three distinct outcomes:

- **security** — no new server-side read/write succeeds after expiry (destroy
  order + host-enforced timer; run with the broker down to prove independence);
- **cache** — previously cached client data may remain readable; record that
  cached reads cannot be "revoked" by the server;
- **availability** — compare default hard mount, `deadtimeout`, and bounded
  soft behavior, documenting the data-integrity risk of soft mounts.

Crash matrix: broker restart, KDC restart, NFS host restart, destroy requested
N times, destroy after partial provisioning failure, **lease expiring while the
broker is unavailable** (the host timer must still fire).

Exit gate: security outcome within 60 s under normal and component-failure
expiry, independent of the broker; cache and availability behavior documented,
not hidden.

### Step 6 — SIWE and credential issuance

Reuse narrowly from `bloom-workspaces`: SIWE challenge/verify, origin/audience/
expiry/replay checks, session cookie + CSRF, basic audit. Do not copy the
terminal, files, jobs, or runtime abstraction. The web process holds no KDC
database, admin key, service keytab, VM credentials, or long-lived password.

Broker surface (Rust later; shell/TS spike first): `workspace.create`,
`workspace.status`, `workspace.connection` (one-time bundle),
`workspace.destroy`, `workspace.sweep_expired`.

Credential ceremony for the spike: broker mints `w/<random>@WORK.SOPHASTRA.COM` with a
high-entropy random password, TTL capped to the lease; browser displays
principal + password once with `Cache-Control: no-store`, plus the exact
built-in commands. The reusable secret visible to browser JS is recorded as a
known product limitation; alternatives (temporary keytab, PKINIT, one-time
plugin) are listed, not built.

Exit gate: a real SIWE sign yields working built-in `kinit`/`mount` commands
from the second Linux peer, and one wallet cannot fetch another workspace's
bundle. No secret appears in logs, URLs, metrics, or analytics.

### Step 7 — macOS kill gate on GitHub-hosted runners (primary); physical device only for #7

No Mac is owned. The kill gate runs on GitHub-hosted Tahoe runners
(`macos-26` Apple Silicon, `macos-26-intel` Intel) as a CI job against cocoroco. The
same job is reusable later on a physical laptop for criterion #7. Package as:

1. SIWE sign (headless browser step in CI, or interactive on a real device);
2. generated connection bundle (principal, password, exact commands, FQDN);
3. shell runner with cleanup traps, no interactive prompts needed in CI;
4. admin compatibility control first (the runner's default account is admin);
5. if a variant mounts, create a non-admin user and repeat it as that user.

Two CI-specific unknowns (themselves answered by the first run): whether
`mount_nfs -o sec=krb5p` is permitted inside a runner (kernel/SIP/MDM
restrictions) and whether the runner's network allows outbound 88/2049 to
cocoroco. A negative on either is recorded evidence, not a silent skip.

Corrected runner (ordinary user, no sudo):

```
# macOS gssd discovers tickets through the native API cache
unset KRB5CCNAME
[ -n "$WS_KRB5_CONF" ] && export KRB5_CONFIG="$WS_KRB5_CONF"
trap 'umount "$HOME/RemoteWorkspace" 2>/dev/null; \
      kdestroy 2>/dev/null; \
      rmdir "$HOME/RemoteWorkspace" 2>/dev/null' EXIT

sw_vers; uname -m; which kinit mount_nfs

kinit w/<id>@WORK.SOPHASTRA.COM
kvno nfs/<WORKSPACE-FQDN>@WORK.SOPHASTRA.COM     # pre-fetch the service ticket

mkdir -p "$HOME/RemoteWorkspace"

# Let gssd select the cached client and host-based NFS service principals.
mount_nfs -o vers=4.1,sec=krb5p \
  <WORKSPACE-FQDN>:/ "$HOME/RemoteWorkspace"

# filesystem suite: create, read, write, rename, delete, mkdir, symlink,
# lock, large file, concurrent writers, unicode names, git init/checkout,
# thousands of small files, interrupted write

# evidence (replaces any fs_usage-based check): before/after snapshots
mount | grep RemoteWorkspace
klist
ls -la /etc/krb5.conf ~/Library/LaunchAgents 2>/dev/null
pgrep -fl mount_nfs

# cleanup runs via the EXIT trap; explicit:
umount "$HOME/RemoteWorkspace"; kdestroy; rmdir "$HOME/RemoteWorkspace"
```

Apple Heimdal honors `KRB5_CONFIG` for ordinary processes and enables DNS KDC
lookup by default; the NFS/GSS credential-cache handoff requires macOS's native
API cache, so the runner pre-fetches `nfs/<WORKSPACE-FQDN>@WORK.SOPHASTRA.COM`
there before mounting. Apple XNU authorizes non-root mounts on a caller-owned
mountpoint and records that caller as mount owner (`bsd/vfs/vfs_syscalls.c`);
physical arm64 Tahoe policy is positive; the corrected hosted standard-account
rerun remains pending.

Decision after the transcript:

- non-admin mount works with `krb5p` -> primary path;
- requires sudo -> record criterion #4 FAILED; characterise the admin path and
  tunnel alternatives only;
- macOS lacks functional `krb5p` interop with Linux NFSD -> stop direct-NFS
  development and publish the negative result.

### Step 8 — Comparators and the recommendation

Comparators (server side on cocoroco, client side wherever a peer exists):

- built-in OpenSSH on a dedicated test host, ports 22 and 443, local high-port
  forward to guest NFS — measure whether it stays non-admin;
- HTTPS/WebDAV file transfer as the non-mount baseline;
- Tailscale/WireGuard recorded as install-required alternatives, not built.

Final pm#38 update maps every original criterion to recorded evidence, with no
substitution of browser functionality for mount functionality. Allowed
conclusions:

1. Production filesystem interface — only if non-admin, zero-install, secure,
   recoverable, reliable on ordinary networks.
2. Optional power-user interface — secure but too fragile for onboarding.
3. Demo/internal prototype — works only on controlled networks or with admin.
4. Rejected — non-admin mount, recovery, credential delivery, or port
   reachability fails materially.

A negative conclusion closes pm#38 successfully if it ships reproducible
evidence.

## Threat-model and adversarial coverage

Actors: unauthenticated Internet attacker; malicious wallet; cross-tenant;
holder of an expired password or ticket; compromised browser session;
compromised workspace user; compromised guest root; compromised NFS host;
compromised KDC; mistaken operator; DNS attacker; active network attacker.

Adversarial tests: replay captured RPC; reuse password after lease end; reuse
ticket after principal deletion; valid ticket against another hostname; force
DNS canonicalization/PTR mismatch; downgrade to AUTH_SYS/`krb5`/`krb5i`;
cross-export traversal and filehandle reuse; exhaust KDC principal creation;
exhaust VM/endpoint capacity; kill server during blocking I/O; expire lease
during sleep; verify logs never contain passwords, caches, or keytabs.

## Highest-risk assumptions, in attack order

1. Ordinary users can mount NFS on current Tahoe. (Step 7)
2. DNS-only Kerberos discovery works without machine configuration. (Step 1, testable via work.sophastra.com)
3. macOS `krb5p` interoperates with Linux NFSD. (Step 7)
4. Custom NFS ports work with Kerberos and no reserved source port.
5. Lease expiry does not leave Finder, agents, or shells hung indefinitely. (Step 5 availability outcome)
6. Existing mounts recover after sleep and network changes. (Step 7)
7. Port 88/2049 reachability is adequate outside controlled networks.
8. The credential ceremony is understandable and leaves no reusable secret.
9. NFS caching semantics are acceptable for agents and developer tooling.

Steps 1-6 attack assumptions 2, 4, 5, 7, 9 on Linux now. Assumptions 1, 3 and
the non-sleep parts of 6 are `CI-MAC` (Step 7 runner). Only the laptop-roaming
portion of assumption 6 needs a physical device.

## Reuse policy

From `bloom-workspaces`: SIWE verify logic and tests; session/CSRF/security
utilities; NFSD build knowledge; threat-model structure; QEMU provisioning only
after viability is proven. Do not reuse the browser terminal/files/jobs, the
SSH/WebSocket proxy, the multi-runtime capability system, or the existing NFS
client plan (`src/nfs/client-plan.ts`), which encodes the wrong Node/admin
assumptions.

From `../bloom`: no dependency for the core experiment. The remote workspace is
an ordinary filesystem, not Bloom's wallet VFS. `bloom-mount` is not used as the
public server; it does not provide RPCSEC_GSS.

## Definition of done

pm#38 is addressed when this repository contains:

- a reproducible KDC and NFSv4.1 deployment on cocoroco with principal-to-UID
  authorization (no `all_squash`);
- proven cross-tenant denial between two workspaces;
- host-enforced, broker-independent expiry with the three outcomes measured;
- a wallet-to-temporary-credential flow;
- the exact macOS built-in command sequence (corrected runner);
- confirmed sudo and non-sudo results (Step 7 transcript);
- direct `krb5p` and built-in SSH-tunnel tests;
- real sleep and roaming evidence (device-bound, criterion #7); expiry and hostile-network evidence via Linux peers + CI runner;
- packet-level confidentiality analysis;
- a transport comparison;
- a production / onboarding / demo / reject recommendation;
- a final pm#38 comment linking every claim to recorded evidence.

## Immediate next action

Rerun the corrected kill-gate on both hosted Tahoe architectures, then exercise
hard expiry and physical-device sleep/roaming before proceeding to the Step 8
comparison and recommendation.
