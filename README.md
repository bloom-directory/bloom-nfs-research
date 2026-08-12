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
| 7. macOS no-admin kill-gate (criteria #3/#4/#5/#8) | ✅ **physical arm64 Tahoe 26.5.2 passes without sudo; corrected hosted-runner rerun pending** |
| 8. Comparators + recommendation | ⏳ not started |

### Linux proof (Steps 3-4) — complete

`ops/server-bootstrap.sh` (cocoroco) + `ops/peer-bootstrap.sh` / `ops/peer-test.sh` (kyle@apps). `peer-test.sh` exits 0: positive `sec=krb5p` mount + FS suite, `AUTH_SYS`/`krb5`/`krb5i` all rejected, cross-tenant denial in both directions (EACCES), canary absent from the RPC pcap. The rebuilt server state used for the Tahoe reruns is under `evidence/server-run-20260809/`; the original peer evidence remains on `kyle@apps` under `/home/kyle/ws-evidence/`.

### macOS kill-gate — physical-device pass; hosted rerun pending

`.github/workflows/macos-killgate.yml` + `ops/macos-killgate.sh` now require macOS Tahoe and optionally gate an exact product version. Evidence covers both current architectures and the older Sonoma baseline:

| Runner | OS / kernel | Architecture | Result |
|---|---|---|---|
| Physical Mac | 26.5.2 / Darwin 25.5.0 | arm64 | **no-sudo NFSv4.1 `krb5p` mount + read/write passed** |
| `macos-14` (five original runs) | 14.8.7 / Darwin 23.6.0 | arm64 | Invalid harness: private `FILE:` cache + explicit principals |
| `macos-26` ([run 31338559348](https://github.com/bloom-directory/bloom-nfs-research/actions/runs/31338559348)) | 26.5.2 / Darwin 25.5.0 | arm64 | Invalid harness: private `FILE:` cache + explicit principals |
| `macos-26-intel` ([run 31339167654](https://github.com/bloom-directory/bloom-nfs-research/actions/runs/31339167654)) | 26.6 / Darwin 25.6.0 | x86_64 | Invalid harness: private `FILE:` cache + explicit principals |

Established:

- ✅ Runner reaches cocoroco (`tcp/88`, `tcp/2049` ok).
- ✅ **macOS Heimdal `kinit` authenticates against the Linux MIT KDC** — admin *and* a freshly created non-admin user both obtain TGTs.
- ✅ Service ticket for `nfs/work.sophastra.com@WORK.SOPHASTRA.COM` acquired (macOS ships no `kvno`; `kgetcred` works).
- ✅ A physical arm64 Mac mounts as an ordinary user with built-in tools only and no sudo, then passes create/read/rename/delete.
- ✅ macOS requires its native API credential cache so `gssd` can discover tickets; a private `FILE:` cache fails with the misleading `RPC prog. not avail` error.
- ✅ `mount_nfs` must select the cached client and server principals automatically; explicit `principal=`/`sprincipal=` fails locally on this path.
- ⏳ A corrected hosted-runner standard-account rerun is pending.

The earlier hosted failures were client-harness false negatives, not Debian
NFS failures. Server-side captures showed successful NFSv4 NULL and rpcbind
probes but no NFS `COMPOUND` or RPCSEC_GSS request from the broken client path.
With the native cache and automatic principal selection, the same physical Mac
mounted and completed filesystem I/O repeatedly.

| Lever tried | Effect |
|---|---|
| register `mountd` (rpc program 100005) via `vers3=yes` | none |
| `vers3 = yes` (full v3 stack) | v3 reaches the auth layer (`Permission denied`); v4 unchanged |
| `vers4.0 = yes` (offer NFSv4.0 in addition to 4.1) | none |

**Current verdict for pm#38.** Direct built-in `mount_nfs` + `sec=krb5p` is
viable on the tested physical arm64 macOS 26.5.2 device without invoking sudo.
The account is an admin-group member, so the corrected CI phase still creates
a standard account to prove account class independently of privilege use.

## Running

Linux server+peer proof: see [`ops/README.md`](./ops/README.md). macOS kill-gate: `./ops/run-macos-test.sh` (ARM Tahoe by default), or `MACOS_RUNNER=macos-26-intel EXPECTED_MACOS_VERSION=26.6 ./ops/run-macos-test.sh` for an exact-version Intel run.
