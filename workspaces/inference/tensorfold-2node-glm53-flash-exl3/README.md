# `tensorfold-2node-glm53-flash-exl3` — GLM-5.3-Flash on the pair, on TensorFold

**Nodes: 2** · **Memory: rank 0 ~88 GiB at the 1M window** · **Port: 8902** · **Engine: TensorFold v0.6.0** · **Status: `unverified` — not booted here**

Serves GLM-5.3-Flash (EXL3 4 bpw, `Mia-AiLab/GLM-5.3-Flash-EXL3-4bpw-TensorFold`
@ `078455ff`) across odysseus + poseidon with
[MiaAI-Lab's TensorFold GLM kit](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold)
(Apache-2.0) at a pinned commit — **TP=2 on two Sparks is this kit's reference
topology**: the exact machine this cluster is. The image is pulled
**by digest** (`ghcr.io/miaai-lab/glm-5.3-flash-exl3-2x-dgx-sparks-tensorfold@sha256:14b5072e…99ccf`,
verified against the registry on 2026-10-20), with the kit's 107 engine
patches already inside it: no local build.

## Why this exists next to the vLLM one

The vLLM kit's own repository now opens with "everyone should use that
[TensorFold] recipe", and the claims back it — the kit's sparkDash numbers at
defaults (1M window, PARALLEL=4, fp8 KV, DENSE=q4, DFlash2+copy drafts) against
this workspace's *measured* vLLM numbers:

| | TensorFold kit claims (1 stream) | [`vllm-2node-glm53-flash-exl3`](../vllm-2node-glm53-flash-exl3/README.md) measured here |
|---|---|---|
| decode, prose | 60.4 tok/s | ~27 tok/s at 0.33 acceptance |
| decode, structured | **114.7 tok/s** | ~62 tok/s at 0.92 |
| decode, aggregate | 108.8 prose / 227.9 struct (×4); 130.8 / 167.0 (×8) | 67.4 headline |
| cold prefill | ~1,950–2,000 tok/s at 8k–66k; 1,838 @131k | 990–1,024 tok/s at 8k/16k |
| window | 1,048,576 (fp8 KV; needle at 982k found, TTFT 967 s) | 131,072 (fp8_ds_mla) |
| prompt reuse | identical 64k prompt 34 s → <0.07 s | prefix caching measured live |
| TTFT, 1 stream | 149–195 ms | 0.54 s |

Roughly **2x on every axis** — with the honesty caveats this repo keeps
insisting on: their decode figures are corpus-dependent (see
`bench/decode-content-mix`: prose vs structured differ ~2x on the SAME server),
the defaults are the **lossy** point (below), and none of this is a number from
this box. These workspaces' content is not directly comparable until the ladder
is re-run against 8902.

## The quality posture, stated by the kit and worth repeating

DENSE=q4 + KV=fp8 "prioritize throughput… expected to have lower numerical
fidelity and may produce more quality regressions… particularly on sensitive
tasks or long-context workloads… an expected trade-off, not evidence of an
implementation defect" (kit README:93-99). Their defaults score GSM8K 98.8% /
HumanEval 95.7% (their numbers, their harness). Concretely: `DENSE=q4` loses
end-of-turn on short French coding prompts (kit issue #18); `KV=bf16` is the
exact cache but shrinks the window to 196,608; `DENSE=fp8` keeps the stop at
~10% decode cost. Drafted replies equal serial replies — the speculators never
change the answer, only the speed.

**The drafter is the licence question.** `DRAFTER=dflash2`
(`incoai/GLM-5.3-Flash-DFlash2`) is **CC BY-NC-ND 4.0 — non-commercial use
only** (+5-10% decode over MTP). `DRAFTER=mtp` uses the checkpoint's own head
and dodges the licence, but forces `PARALLEL=1` (one request at a time). Which
of those is legal for what you run this for is an operator decision, not one
this file can make; the default is upstream's (dflash2) and the switch is one
`.env` line.

## Requirements

- The cabled pair (both RoCE rails — this cluster's link matches the kit's
  "address both twins… two rails" requirement exactly, and its rendezvous
  auto-detects them), ssh between them, docker on both.
- **Head disk ~210 GB**: checkpoint ~176 GB + image ~25 GB. The worker stores
  NO weights by default: `WORKER_WEIGHTS=nfs` makes rank 1 read the head's HF
  cache over the cable (poseidon's 125 GB free cannot hold the tree, and the
  kit's `copy` default asks it to — that is the one place this workspace
  overrides the kit, and it is the disk arithmetic, not taste).
- **The NFS export is Ansible's half** (same seam as every other workspace):

  ```bash
  make optional TAGS=nfs LIMIT=odysseus EXTRA='-e nfs_export_path=$HOME/.cache/huggingface'
  ```

  `up.sh` checks `/etc/exports` and refuses with this exact command if it is
  missing; nothing in this workspace creates a mount.
- ~108+ GiB MemAvailable on the head at start, which means the 2-node vLLM
  server (any of them) must be down first. The kit's own budget refuses
  otherwise, and `ws check` refuses here.

## Running it

```bash
ws up   tensorfold-2node-glm53-flash-exl3
ws up   tensorfold-2node-glm53-flash-exl3 restart   # after a .env change; restarts the memory guards too
ws logs tensorfold-2node-glm53-flash-exl3 -f        # rank 0; rank 1: ssh <peer> docker logs -f glm53-flash-tf
ws down tensorfold-2node-glm53-flash-exl3           # both ranks and their guards, logs archived by the kit
```

First run: the kit's `prepare.sh` pulls the image by digest on both Sparks,
downloads the checkpoint + DFlash2 at their pinned revisions, makes the RoPE
tables and validates the MANIFEST, then starts both ranks and smoke-tests.
`DRY_RUN=1` prints both ranks' `docker run` lines before anything changes.

Then, pointed at 8902: `vllm-quality-gate` (the kit ships `tools/` checks
too, incl. `toolcheck.py` and `end_of_turn.py`), `vllm-prefill-ladder
--chunk-tokens 2048`, and `pi-harness`/`deepseek-harness` as clients —
with one caveat below.

## Memory guard

The kit has a stall watchdog and a start-time reserve but no runtime guard;
its README says exhaustion tends to freeze the machine. This repo-owned
`memory_guard.py` samples real `/proc/meminfo` every 0.2 s on each node:

| | floor | action |
|---|---|---|
| soft | under 2.5 GiB for 4 s | request a kill of that rank's exact container ID |
| hard | under 1 GiB | request a kill immediately |

`ws up` arms both startup supervisors **before** calling `start.sh`, without
changing its arguments or exported environment. It refuses to call `start.sh`
if either handshake fails. The handshake requires a successful, bounded Docker
inspection and an explicit `supervisor started` log record, not merely a live
Python PID. While preparation/loading/retries run, each supervisor discovers
the named container and re-arms for each replacement ID. The startup wait is
bounded to six hours; an already active guard continues beyond that limit.
When `start.sh` returns, `ws up` ends startup discovery and checks both ranks'
current IDs against the guard status. A failing `start.sh` keeps its exit code;
a guard failure makes an otherwise successful start fail explicitly.

On interruption, `ws up` signals `start.sh`, ends startup discovery, reports the
guard state, and exits 130/143. Existing guarded containers are not silently
left without a monitor. `ws down` stops the guards after the ranks. A steady
state guard exits when its container stops or is replaced. Per-launch ready,
status and startup files live under the cache, but never lock out a restart.

**Use `ws up <name> restart`, not the kit's `./start.sh restart`.** A manual
kit restart bypasses startup supervision: old guards exit with the old IDs and
new containers are unguarded until `ws up` runs again. `FOREGROUND=1` is now
monitored while `start.sh` remains attached, not only after it returns.

Each node appends UTC timestamps to
`~/.cache/tensorfold-glm53/logs/memguard.log`:

- `dip:` and the recovery record include the lowest MemAvailable.
- `recovered: no kill` means no kill was confirmed; an earlier unconfirmed
  attempt is stated explicitly and its state is cleared for the next dip.
- `killing container` records a decision before asking Docker.
- `killed container` is emitted **only** after Docker reports success.
- `kill unconfirmed` and `docker unavailable` are not successful protection.
  Calls time out after two seconds and retry with backoff, at most five seconds;
  repeated failures are logged once per episode. Disappearance after a failed
  kill is never retroactively called a confirmed kill.

**Protection limits:** container discovery needs a Docker inspection, so there
is an unguarded interval after creation/replacement (polling every 0.2 s when
healthy, plus inspection time). The memory sample itself does not need Docker,
but killing does. A hung/unavailable daemon can prevent a kill completely;
short timeouts bound the guard's wait, not Docker's response or GPU reclamation.
Only the local rank is killed, not its peer. No host-memory locking, root process
or cgroup changes are made. A full disk can lose log evidence but does not stop
the kill decision. No unconditional protection against machine freezes is claimed.

`make memory-guard` exercises real Docker and live memory on devbox. Its kit
start/load/replacement fixture is **not real GLM**. Nothing has run on a real
GB10 or a real GLM boot; `provenance: unverified` remains appropriate.

## What does NOT carry over from vLLM

- **No `logprobs`.** `tensorfold-native` does not expose per-token logprobs,
  and `spec-decode-accept` reads them. Acceptance on this engine is proven
  differently: the kit's own `tools/exact.py` (drafted == serial, by token
  hash) and `tools/toolcheck.py`. Record this before anyone debugs a bench
  workspace that suddenly has nothing to read.
- **`/v1/messages` exists** (the kit's Anthropic bridge, patch 0084) — the
  vLLM servers here do not have one. `pi-harness` and the agent workspaces can
  point at either; this is the first server here that speaks both dialects.
- No `--kv-dtype` flag surface: `KV=fp8|bf16` is kit env, applied at load.
- Sampling defaults 1.0 / 0.95 / 20 (a request's values win), thinking ON,
  `MAX_TOKENS=32768` — same reasoning as this repo's own gate: thinking is
  billed first, a small budget truncates the answer, not the thinking.

## Configuration

The kit's `scripts/config.sh` is the reference; `.env` here is exported into
it (env wins over the kit's own defaults and its own `.env`). The knobs that
matter for this cluster:

| | default | notes |
|---|---|---|
| `PORT` | `8902` (here; kit default 8888) | 8893 = the vLLM GLM server's port |
| `WORKER_WEIGHTS` | `nfs` (here; kit default `copy`) | `copy` needs ~166 GiB free on poseidon - it does not have it |
| `PARALLEL` | `4` | 1–8 with DFlash2; the KV pool shrinks with it (~2.9M tokens at 4, ~1.5M at 8) |
| `CONTEXT` | `1048576` | with KV=fp8. `start.sh` falls back to the largest the memory affords |
| `KV` | `fp8` | lossy, ~2x the tokens; `bf16` exact → window drops to 196,608 |
| `DENSE` | `q4` | lossy 4-bit dense weights (the stop-string caveat above); `fp8` is the middle point |
| `DRAFTER` | `dflash2` | CC BY-NC-ND; `mtp` avoids it and forces PARALLEL=1 |
| `COMM` | `roce` | one-shot RDMA gathers under 512 KiB (patch 0006): +6% decode, same bits |
| `TF_GLM_FILL_ROWS` | `2048` | fill chunk = the whole prompt chunk (patch, +warm fills, −26% cold 256k on 3 Sparks — TP=2 shares the win) |
| `SPILL_GIB` | `0` | opt-in prompt-state spill tier on NVMe (`SPILL_MIN_FREE_GIB=50` is why this cluster would qualify only on the head) |

## Licence and provenance

Kit Apache-2.0 (weights pack Apache-2.0, base Z.AI model MIT; TensorFold
Apache-2.0 from v0.6.0; DFlash2 CC BY-NC-ND 4.0; nvcr base image under
NVIDIA's licence; `:latest`-style tags adopted only on a matching recipe
stamp). The AGPL vLLM kit is NOT in this path — this workspace and its
Apache image are the permissive route to this model, which is a better
licence posture than `#glm53-flash` has ever had. `provenance: unverified`
flips only after a boot here whose numbers came out of a log.

## Sources

- [`MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold`](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold) @ `3fd60df`
- [`Mia-AiLab/GLM-5.3-Flash-EXL3-4bpw-TensorFold`](https://huggingface.co/Mia-AiLab/GLM-5.3-Flash-EXL3-4bpw-TensorFold) @ `078455ff`
- [`incoai/GLM-5.3-Flash-DFlash2`](https://huggingface.co/incoai/GLM-5.3-Flash-DFlash2) @ `bf582e4e`
- `docs/decisions.md#tensorfold-era` — the pass that found this, and what it did to this repo's earlier verdicts
