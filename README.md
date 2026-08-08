# bloom-nfs-research

Research repo for [bloom-directory/pm#38](https://github.com/bloom-directory/pm/issues/38): *can a wallet-authenticated user mount an isolated remote workspace over the internet using **built-in OS tools only — no install, no admin — with `sec=krb5p` confidentiality and hard expiry?* A documented negative result is a valid outcome (see `PLAN.md`).

- **Plan + acceptance criteria:** [`PLAN.md`](./PLAN.md)
- **Ops scripts (server/peer/macOS):** [`ops/`](./ops/) — see [`ops/README.md`](./ops/README.md)

## Status

| Step (`PLAN.md`) | Status |
|---|---|
| 3-4. Linux reference: KDC + NFSv4.1 `krb5p`-only, cross-tenant denial | ✅ **DONE** |
| 5. Broker-independent hard expiry | ⏳ not started |
| 6. SIWE + credential broker | ⏳ not started |
| 7. macOS no-admin kill-gate (criteria #3/#4/#5/#8) | ❌ **negative result — macOS `mount_nfs` cannot mount the Linux server; criterion #4 unreachable** |
| 8. Comparators + recommendation | ⏳ not started |

### Linux proof (Steps 3-4) — complete

`ops/server-bootstrap.sh` (cocoroco) + `ops/peer-bootstrap.sh` / `ops/peer-test.sh` (kyle@apps). `peer-test.sh` exits 0: positive `sec=krb5p` mount + FS suite, `AUTH_SYS`/`krb5`/`krb5i` all rejected, cross-tenant denial in both directions (EACCES), canary absent from the RPC pcap. Evidence on the hosts under `/var/tmp/ws-evidence/` (cocoroco) and `/home/kyle/ws-evidence/` (kyle@apps).

### macOS kill-gate — negative result (macOS mount limitation)

Runs on a GitHub-hosted `macos-14` runner (Darwin 23.6.0, arm64) against cocoroco via `.github/workflows/macos-killgate.yml` + `ops/macos-killgate.sh`. Five runs (`evidence/macos-run-*/killgate.txt`). Established:

- ✅ Runner reaches cocoroco (`tcp/88`, `tcp/2049` ok).
- ✅ **macOS Heimdal `kinit` authenticates against the Linux MIT KDC** — admin *and* a freshly created non-admin user both obtain TGTs.
- ✅ Service ticket for `nfs/work.sophastra.com@WORK.SOPHASTRA.COM` acquired (macOS ships no `kvno`; `kgetcred` works).
- ✅ Non-admin user creation + non-admin `kinit` work (no `/etc` writes; ccache isolated under `$RUNNER_TEMP`).
- ❌ **`mount_nfs` cannot mount — a macOS-side limitation.** A version×path matrix (admin user, runs 4–5) produces two distinct failure modes:
  - `vers=4` → `RPC prog. not avail` (both `/ws1` and `/export/ws1`)
  - `vers=3` → `Permission denied` (both paths)

**This is not a server bug.** The Linux peer mounts the same server with `sec=krb5p` (peer-test green), and the macOS runs confirm every relevant RPC program is registered and responding remotely (`nfs` v3+v4, `mountd` v3, `nfs_acl`, `nlockmgr`, portmapper). Server-side levers tried and exhausted — none changed the macOS error:

| Lever tried | Effect |
|---|---|
| register `mountd` (rpc program 100005) via `vers3=yes` | none |
| `vers3 = yes` (full v3 stack) | v3 reaches the auth layer (`Permission denied`); v4 unchanged |
| `vers4.0 = yes` (offer NFSv4.0 in addition to 4.1) | none |

**Interpretation.** macOS's NFSv4 client fails at the RPC layer *before* authentication; v3 reaches the auth layer but is rejected. Criterion #4 (administrator privilege) is **unreachable** — the mount fails identically for admin and non-admin. The cross-OS *auth* path is proven (kinit + service ticket both work); the cross-OS *mount* path is not.

**Verdict for pm#38.** Direct `mount_nfs` + `sec=krb5p` against a correctly-configured Linux NFSv4.1 server **does not work on macOS with built-in tools**, independent of admin privileges. This is a reproducible negative result of the kind `PLAN.md` (§Definition of done, §"A negative conclusion closes pm#38 successfully") explicitly accepts as closing the issue. The v3 `Permission denied` thread (auth-layer) is recorded as a possible future investigation but was not the v4.1 design target.

> Note: cocoroco is currently in a transient test state (`vers3=yes`, `vers4.0=yes`); the committed `ops/server-bootstrap.sh` writes `vers3=no, vers4.0=no` (v4.1-only design). The export remains `sec=krb5p`-only; re-running `server-bootstrap.sh` restores the design config.

## Running

Linux server+peer proof: see [`ops/README.md`](./ops/README.md). macOS kill-gate: `./ops/run-macos-test.sh` (needs `gh` authed, SSH+sudo on cocoroco; sets the `WS_WS1_PASS` secret and triggers the workflow).
