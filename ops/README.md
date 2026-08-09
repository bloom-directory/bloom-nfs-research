# pm#38 server proof — ops scripts

Reviewed one-shot, idempotent scripts that stand up the NFSv4.1 + `krb5p`
reference on `cocoroco` and prove it from the Linux peer `kyle@apps`. They are
run by the operator with **interactive sudo**; there is no `NOPASSWD` grant and
no unattended privileged execution on either shared host.

| script | host | runs as | purpose |
|---|---|---|---|
| `server-bootstrap.sh` | cocoroco | sudo | KDC + NFSv4.1 `krb5p`-only export, per-workspace principal→UID mapping, AES-SHA1 |
| `server-teardown.sh` | cocoroco | sudo | restore cocoroco (manifest-driven) |
| `peer-bootstrap.sh` | kyle@apps | sudo | NFS/Kerberos client, rpc-gssd, peer users ws1peer/ws2peer |
| `peer-test.sh` | kyle@apps | sudo | positive suite + flavor rejections + cross-tenant denial + RPC pcap |
| `peer-teardown.sh` | kyle@apps | sudo | restore kyle@apps |

## Safety on cocoroco

cocoroco hosts other services (80/443/3000, udp 443/51820). The server scripts:

- never touch the firewall (none is active; filtering is the cloud SG) and never
  enable `/etc/nftables.conf` (it contains `flush ruleset`);
- mask **kadmind** (only `kadmin.local` is used) so port 749 never opens;
- back up every `/etc` file they touch to `/root/ws-secrets/backup/*.orig` and
  record all managed paths in a manifest; `server-teardown.sh` restores or
  removes each one deterministically, destroys the realm DB, and removes the
  keytab, workspace data, Unix users, and secrets;
- touch only the listed `/etc` paths, `/etc/krb5.keytab`, `/export/*`,
  `/var/lib/krb5kdc`, and `/root/ws-secrets`.

## Identity model (why two peer users + a machine keytab)

Linux `mount -t nfs4` needs `CAP_SYS_ADMIN`, so the peer mounts as root, but
`rpc.gssd` selects Kerberos credentials **by uid**. To prove identity-based
access, each principal is acquired by a distinct unprivileged peer user:
`ws1peer` (uid 10001) → `w/ws1`, `ws2peer` (uid 10002) → `w/ws2`. Root holds
`w/ws1` only to satisfy the mount. Separately, `rpc.gssd` needs **machine
credentials** in `/etc/krb5.keytab` for NFSv4 clientid operations; the server
script mints a peer keytab (`host/`/`nfs/`/`root/` of the peer's FQDN) for this.
Cross-tenant denial is therefore enforced **server-side** (ws2-mapped uid cannot
read ws1's 0700 root), not by local path tricks.

## Workflow

1. **Peer FQDN** (operator): `ssh kyle@apps hostname -f` and note the value
   (e.g. `apps.example.com`). Needed so rpc.gssd's machine principals match.
2. **Server** (cocoroco):
   `sudo PEER_FQDN=<peer-fqdn> bash ops/server-bootstrap.sh`
   Emits `/root/ws-secrets/peer.env` **and** `/root/ws-secrets/peer.keytab`
   (root-only), plus evidence to `/var/tmp/ws-evidence/`.
3. **Cloud firewall** (operator): open **tcp+udp 88** and **tcp 2049** to
   cocoroco. Scope to `kyle@apps`'s IP first.
4. **Transfer** (operator): copy BOTH files from cocoroco to the peer —
   `sudo cat /root/ws-secrets/peer.env` → `/home/kyle/ws-peer.env`, and
   `sudo cat /root/ws-secrets/peer.keytab` → `/home/kyle/peer.keytab`; `chmod 600`.
5. **Peer setup** (kyle@apps): `sudo bash ops/peer-bootstrap.sh`
   Installs `/etc/krb5.keytab`, enables rpc-gssd, creates peer users + mountpoints.
6. **Peer test** (kyle@apps): `sudo bash ops/peer-test.sh`
   Evidence to `/home/kyle/ws-evidence/`: `03-positive.txt`, `04-negatives.txt`,
   `05-crosstenant.txt`, `06-capture.txt`, `06-rpc.pcap`.
   Exits **nonzero** on any violated expectation (a weaker flavor accepted, a
   non-EACCES error mistaken for authorization denial, or a plaintext canary
   found in the capture).
7. **Unprivileged verification** (agent, no sudo): read both evidence dirs over
   SSH; confirm Step 3/4 exit gates; check the pcap for encrypted RPC.
8. **Teardown** when done: `sudo PEER_FQDN=<peer-fqdn> bash ops/server-teardown.sh`
   on cocoroco and `sudo bash ops/peer-teardown.sh` on kyle@apps.

## Scope vs PLAN.md (single SPN vs per-workspace FQDNs)

PLAN.md:118-123 specifies the *target*: one FQDN + `nfs/<workspace-hostname>`
service principal **per workspace**, mounted at `:/`. This single-host proof
intentionally uses **one** SPN (`nfs/work.sophastra.com`) with two export
sub-paths (`/ws1`, `/ws2`) and relies on **filesystem-level authorization**
(idmapd principal→UID static mapping + 0700 roots) for isolation — the
authorization mechanism PLAN.md:125-131 prescribes. This is sufficient to prove
the core security claim (krb5p + flavor rejection + cross-tenant denial) on one
machine. Per-workspace FQDNs/SPNs (and the stronger separate-realm trust
boundary) are a Phase-4 per-VM concern and are reconciled there before macOS CI.

## What this proves and what it does not

- Proves: `sec=krb5p` mount works from a built-in Linux client; AUTH_SYS and
  `krb5`/`krb5i` are rejected; cross-tenant access is denied server-side with
  EACCES; principal→UID authorization works without `all_squash`; RPC payloads
  are encrypted (plaintext canary absent from the capture).
- Does **not** prove: the macOS no-admin path (criterion #4 — macOS CI job),
  hard-expiry timing (Step 5, separate), or sleep/roaming (criterion #7,
  device-only).

## rpcbind containment

NFSv4-only does not need rpcbind on the wire. During a test, the **cloud security
group must deny port 111** and expose only tcp/udp 88 plus tcp 2049. Do not assume
that a provider firewall is attached: verify public reachability before and after
each run. Debian's NFS packages may enable rpcbind/rpc-statd as a package side
effect, so the bootstrap snapshots their prior unit states and teardown restores
those states. If the experiment introduced them, teardown stops/disables them and
closes port 111; if they were already in use, teardown leaves them as it found them.

## Notes for review

- Server keytab and config use AES-SHA1 enctypes only, to avoid Heimdal/Linux
  AES-SHA2 interop surprises before the macOS run.
- NFSv4.1-only is set with explicit per-version booleans (`vers4.0=no`,
  `vers4.1=yes`, `vers4.2=no`); there is no ambiguous `vers=y`.
- idmapd.conf uses valid plugin names: `nsswitch` and `static` (not `nss`).
- `kdb5_util create` receives the master password via stdin (never `-P`/argv);
  the master password is not persisted (the stash file handles restarts).
- `peer.env`/`peer.keytab` hold throwaway secrets for a disposable realm with
  disposable data; kept root-only / mode 0600 and never printed by the scripts.
- Backups are first-run-only with absent-sentinel markers, so a re-run bootstrap
  never backs up its own generated files and teardown restores deterministically.
