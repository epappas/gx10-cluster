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

The kit has a stall watchdog and a start-time reserve, but nothing that watches
memory while serving, and its README says exhaustion tends to freeze the
machine. These two nodes have no remote power control we can rely on, so this
workspace adds its own guard, `memory_guard.py`, written here and not copied
from any kit.

It runs on each rank, samples `MemAvailable` from `/proc/meminfo` every 0.2 s,
and kills that rank's container, with the same floors as the DeepSeek arm:

| | floor | action |
|---|---|---|
| soft | under 2.5 GiB for 4 s | kill the container; a dip that recovers first is only logged |
| hard | under 1 GiB | kill the container at once |

- **Lifetime.** `ws up` starts it on both nodes after `start.sh` returns, and
  also when `start.sh` failed, because some failures leave the ranks running.
  `ws down` stops it. It exits by itself when the container stops or is
  replaced, and it keeps no pid file or lock, so nothing blocks a restart.
- **`ws up` fails if a rank is unguarded.** A guard that cannot start prints
  `UNGUARDED` and `ws up` exits non-zero, with the server left running. Running
  `ws up` again is safe: `start.sh` leaves a live server alone and the guards
  are replaced.
- **Log.** `~/.cache/tensorfold-glm53/logs/memguard.log` on each node, one line
  per event, timestamped in UTC:

  | line contains | means |
  |---|---|
  | `dip:` | fell under the soft floor |
  | `recovered: no kill` | came back in time, with the lowest value and duration |
  | `killing container` | the decision, written before docker is asked |
  | `killed container` | docker killed it, with the lowest value |
  | `kill failed, will retry` | docker refused or timed out; still guarding |
  | `docker unreachable, still guarding` | docker gave no answer; that is not "gone" |

  `docker kill` keeps the stopped container, so its log survives for the kit's
  next start to archive. Only the rank under pressure is killed: its peer keeps
  running until `ws down` or the next `ws up`, which restarts both.

What it does **not** cover:

- **The weight load.** The guards start after the server answers, so the 2-6
  minute load, and each retry inside `start.sh`, is protected only by the kit's
  start-time reserve.
- **`./start.sh restart` run by hand from the kit directory.** The old guards
  exit when their containers go, and nothing starts new ones, so the new server
  runs **unguarded** until you run `ws up` once. `ws up <name> restart` restarts
  the guards itself. The same applies to `FOREGROUND=1`, where `start.sh` only
  returns once the server has ended.
- **A slow docker.** The decision is the guard's, but the kill is docker's:
  `docker kill` took from 0.5 s to 12 s on a busy devbox at load 39, and one
  run points to a kill with no reply inside the guard's 30 s timeout, finished
  by its retry. A starving node could be slower still, so a kill can land well
  after the floor's time, and that margin is unmeasured on a GB10.

Tested for real on devbox docker with throwaway containers
(`make memory-guard`). **It has never run on a GB10 or against a GLM boot.**

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
