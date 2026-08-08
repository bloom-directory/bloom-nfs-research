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
| 7. macOS no-admin kill-gate (criteria #3/#4/#5/#8) | 🟡 **in progress — auth proven, mount blocked** |
| 8. Comparators + recommendation | ⏳ not started |

### Linux proof (Steps 3-4) — complete

`ops/server-bootstrap.sh` (cocoroco) + `ops/peer-bootstrap.sh` / `ops/peer-test.sh` (kyle@apps). `peer-test.sh` exits 0: positive `sec=krb5p` mount + FS suite, `AUTH_SYS`/`krb5`/`krb5i` all rejected, cross-tenant denial in both directions (EACCES), canary absent from the RPC pcap. Evidence on the hosts under `/var/tmp/ws-evidence/` (cocoroco) and `/home/kyle/ws-evidence/` (kyle@apps).

### macOS kill-gate — open

Runs on a GitHub-hosted `macos-14` runner against cocoroco via `.github/workflows/macos-killgate.yml` + `ops/macos-killgate.sh`. Three runs to date (`evidence/macos-run-*/killgate.txt`). Established:

- ✅ Runner reaches cocoroco (`tcp/88`, `tcp/2049` ok).
- ✅ **macOS Heimdal `kinit` authenticates against the Linux MIT KDC** — admin *and* a freshly created non-admin user both obtain TGTs.
- ✅ Service ticket for `nfs/work.sophastra.com@WORK.SOPHASTRA.COM` acquired (macOS ships no `kvno`; `kgetcred` works).
- ✅ Non-admin user creation + non-admin `kinit` work (no `/etc` writes; ccache isolated under `$RUNNER_TEMP`).
- ❌ `mount_nfs -o vers=4,sec=krb5p,...` fails with **`RPC prog. not avail`** — identical for admin and non-admin, so criterion #4 (administrator privilege) is **not** the blocker; the mount fails before that can be tested.

**Not the cause (already ruled out):** `vers=4.1` is invalid macOS syntax (fixed to `vers=4`); server `mountd` (rpc program 100005) was unregistered under the v4.1-only config, but enabling `vers3=yes` + restarting `nfs-mountd` registered it and the macOS error is unchanged.

**Next step (definitive, not a guess):** capture the RPC traffic on cocoroco during a macOS mount attempt to identify which program/version macOS is querying and what the server actually rejects. Not yet done. The failure is either a fixable macOS `mount_nfs` quirk or a fundamental limitation of Apple's NFSv4 client against an NFSv4.1-only Linux server — either is a valid pm#38 outcome once documented.

> Note: cocoroco is currently in a transient `vers3=yes` test state (the committed `ops/server-bootstrap.sh` still writes `vers3=no`). The export remains `sec=krb5p`-only; re-running `server-bootstrap.sh` restores the v4.1-only config.

## Running

Linux server+peer proof: see [`ops/README.md`](./ops/README.md). macOS kill-gate: `./ops/run-macos-test.sh` (needs `gh` authed, SSH+sudo on cocoroco; sets the `WS_WS1_PASS` secret and triggers the workflow).
