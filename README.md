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
| 7. macOS no-admin kill-gate (criteria #3/#4/#5/#8) | ❌ **negative on hosted Sonoma + current Tahoe — admin control cannot mount; criterion #4 remains untested** |
| 8. Comparators + recommendation | ⏳ not started |

### Linux proof (Steps 3-4) — complete

`ops/server-bootstrap.sh` (cocoroco) + `ops/peer-bootstrap.sh` / `ops/peer-test.sh` (kyle@apps). `peer-test.sh` exits 0: positive `sec=krb5p` mount + FS suite, `AUTH_SYS`/`krb5`/`krb5i` all rejected, cross-tenant denial in both directions (EACCES), canary absent from the RPC pcap. The rebuilt server state used for the Tahoe reruns is under `evidence/server-run-20260809/`; the original peer evidence remains on `kyle@apps` under `/home/kyle/ws-evidence/`.

### macOS kill-gate — negative result on GitHub-hosted runners

`.github/workflows/macos-killgate.yml` + `ops/macos-killgate.sh` now require macOS Tahoe and optionally gate an exact product version. Evidence covers both current architectures and the older Sonoma baseline:

| Runner | OS / kernel | Architecture | Result |
|---|---|---|---|
| `macos-14` (five original runs) | 14.8.7 / Darwin 23.6.0 | arm64 | NFSv4 `RPC prog. not avail` |
| `macos-26` ([run 31338559348](https://github.com/bloom-directory/bloom-nfs-research/actions/runs/31338559348)) | 26.5.2 / Darwin 25.5.0 | arm64 | NFSv4 `RPC prog. not avail` |
| `macos-26-intel` ([run 31338643220](https://github.com/bloom-directory/bloom-nfs-research/actions/runs/31338643220)) | **26.6 / Darwin 25.6.0** | x86_64 | NFSv4 `RPC prog. not avail` |

Established:

- ✅ Runner reaches cocoroco (`tcp/88`, `tcp/2049` ok).
- ✅ **macOS Heimdal `kinit` authenticates against the Linux MIT KDC** — admin *and* a freshly created non-admin user both obtain TGTs.
- ✅ Service ticket for `nfs/work.sophastra.com@WORK.SOPHASTRA.COM` acquired (macOS ships no `kvno`; `kgetcred` works).
- ✅ Non-admin user creation + non-admin `kinit` work (no `/etc` writes; ccache isolated under `$RUNNER_TEMP`).
- ❌ The admin compatibility control cannot mount with `vers=4,sec=krb5p`; both `/ws1` and `/export/ws1` return `RPC prog. not avail` on Sonoma 14.8.7, Tahoe 26.5.2, and the exact-current Tahoe 26.6.
- ⛔ The non-admin mount is deliberately skipped when no admin variant works. Criterion #4 is therefore **unreachable/untested**, not an observed non-admin failure.

The Linux peer previously mounted the same design with `sec=krb5p` (peer-test green). For the Tahoe reruns, the rebuilt server passed KDC authentication, service-ticket acquisition, NFSv4 RPC registration, v4.1-only configuration, `krb5p`-only exports, and listener gates (`evidence/server-run-20260809/`). This narrows the failure to macOS/Linux NFS interoperability or the GitHub-hosted Mac environment; it does not distinguish those two causes. Earlier server-side compatibility levers did not change the macOS NFSv4 error:

| Lever tried | Effect |
|---|---|
| register `mountd` (rpc program 100005) via `vers3=yes` | none |
| `vers3 = yes` (full v3 stack) | v3 reaches the auth layer (`Permission denied`); v4 unchanged |
| `vers4.0 = yes` (offer NFSv4.0 in addition to 4.1) | none |

**Interpretation.** On GitHub-hosted Macs, the NFSv4 client fails at the RPC layer *before* NFS authentication. The cross-OS Kerberos path is proven (`kinit` + service ticket); the cross-OS mount path is not. A physical Tahoe 26.6 Mac remains the test needed to rule out runner-specific kernel/SIP/virtualization policy.

**Verdict for pm#38.** Direct `mount_nfs` + `sec=krb5p` is not viable in the tested zero-install CI path, including the exact-current macOS Tahoe 26.6 release. This is strong reproducible negative evidence, but it is not evidence that administrator privilege is irrelevant and is not yet a physical-device result.

> Cleanup: the disposable realm, KDC/NFS services, exports, workspace data, server secrets, and Actions credential were removed after the Tahoe runs. Re-run `ops/server-bootstrap.sh` before another test.

## Running

Linux server+peer proof: see [`ops/README.md`](./ops/README.md). macOS kill-gate: `./ops/run-macos-test.sh` (ARM Tahoe by default), or `MACOS_RUNNER=macos-26-intel EXPECTED_MACOS_VERSION=26.6 ./ops/run-macos-test.sh` for an exact-version Intel run.
