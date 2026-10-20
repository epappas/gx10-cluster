# `tensorfold-2node-dsv41-flash-1017` — DeepSeek-V4.1-Flash-1017 on the pair, on TensorFold

**Nodes: 2** · **Memory: ~98–99 GiB of weights a rank** · **Port: 8903** · **Engine: TensorFold (native Zig, BertholomusAI `dsv41`)** · **Status: `blocked` — on disk, measurably**

[MiaAI-Lab's 1017 kit](https://github.com/MiaAI-Lab/DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks)
(Apache-2.0, created 2026-10-19) at a pinned commit: EXL3 2.9 bpw EAQ-v1
checkpoint, the full 1,048,576-token window, DSpark drafting from the
checkpoint's own blocks, images and video, tool calls with `tool_choice:
required` enforced at the call gate, and prefill that no longer freezes a
decoding stream (interleave on by default at 250 ms — a 120k cold prompt
leaves a live stream's longest gap at 1.3 s, was 90 s).

This supersedes [`vllm-2node-dsv41-flash-exl3`](../vllm-2node-dsv41-flash-exl3/README.md)
as the DSV4.1-Flash recipe: upstream moved engine, checkpoint **and** Engram
tables, and the old pins no longer resolve (see "What moved" below).

## What upstream measured, on a pair like this one

Their numbers, sparkDash on the pair, `CONTEXT=524288`, ≤4 streams, drafts on
(kit README Status; head ran a desktop + ~18 containers, so they carry a
"busy head" caveat this cluster should too):

| | 1 stream | 2 | 4 |
|---|---|---|---|
| prose | **74.9** (TTFT 131 ms) | 105.5 agg | 130.0 agg |
| code | **109.9** | 139.8 agg | 155.5 agg |

Prefill 2,079–2,183 tok/s from 8K to 128K, 2,000 at 256K (TTFT 131.3 s);
479k-token needle 3/3 found. BertholomusAI's reference figures are cleared
on decode and run ~9-11% under on prefill — stated as their own limitation.
Compare against this repo's measured DSpark-vLLM pair
(`vllm-2node-deepseek-v4-flash`, FP8, ~100 GB/node): different checkpoint
(2.9 bpw EXL3 vs FP8), different engine, strictly better per-stream decode.

## The disk arithmetic — why this says `blocked`

Measured 2026-10-20 with the 2-node vLLM server up: **odysseus 343 GB free,
poseidon 125 GB free.** The recipe needs, by the kit's own Requirements table:

| | head | worker |
|---|---|---|
| checkpoint (39 shards) | 196 GiB | — (reads over NFS… **no** — see below) |
| Engram tables (shards 47-48 of the 1017 base) | ~203 GB | ~203 GB |
| per-rank weight file (rank-cache, `tf-dsv41-rank-cache`) | ~106 GB | ~106 GB |
| image | ~25 GB | ~25 GB |
| **steady state** | **~505 GB** | **~310 GB** |

- **Engram is the hard floor and it is local-disk-only by measurement:** a
  decode round takes ~70 random 4 KiB reads from it; over NFS that read costs
  ~940 µs against ~90 µs local, and prefill collapses to ~690-890 tok/s.
  Neither node has 203 GB to spare for a table it cannot share.
- The two rank weight files (~106 GB each) are build-time derivatives of the
  checkpoint (written once by prepare.sh); deleting them after a build and
  rebuilding costs one no-GPU pass, so a reclaim plan can treat them as
  peaks, not steady state — but the checkpoint and tables are both.
- A reclaim decision is exactly that, a decision: `gx10-storage` puts 249 GB
  of weights and 103 GB of locally-built images on odysseus, `/var/tmp/
  autoresearch-rl-models` 28 GB, and the RL archive named in the old dsv41
  port lives on poseidon. None of it is deleted by anything in this repo
  without an operator choosing it. `ws check` refuses here until `df` agrees,
  and `up.sh` refuses **both** nodes with these numbers printed.

## What moved since the vLLM port, and why the old cache does not count

- **Checkpoint renamed with content.** `Mia-AiLab/DeepSeek-V4.1-Flash-EXL3-2.9bpw`
  (what `vllm-2node-dsv41-flash-exl3` pins, rev `e8ac7684`, which the Hub no
  longer serves) → `Mia-AiLab/DeepSeek-V4.1-Flash-1017-EXL3-EAQ-v1-2.9-bpw`
  @ `6d54be4f`. The old name redirects at the repo level, but the HF cache is
  keyed by NAME+REVISION: a copy under either old identifier is invisible to
  this pin, and prepare.sh refuses to download 196 GiB into a disk that
  cannot hold it (their guard, 2026-10-19, for exactly this confusion).
- **Engram's tables are NEW in 1017** (shards 47+48 of
  `deepseek-ai/DeepSeek-V4.1-Flash-1017` @ `1bae0e10`). The model card lists
  their sha256; `VERIFY_SHA=1` checks them. **The older release's tables must
  not be used with this checkpoint** — the sizes differ and are checked.
- Engine: vLLM overlay → TensorFold's Zig `tensorfold-native` + `tf-dsv41-lanes`
  (BertholomusAI's `deepseek-v41-zig` @ `629c524`, three of Mia's patches +
  the measured interleave/image-cache patches 0005-0006). The ABLIT F16→F32
  confidence-head trap (grafted overlay makes the drafter draft 0.2-0.8
  tokens a round; fixed by `ablit_stock_dtypes.py`) is the kind of finding
  this engine layer has been collecting — see `docs/decisions.md#tensorfold-era`.

## Memory safety, which is why `memguard` matters here

~98 GiB of weights + FP4-compressed KV (~0.5 GiB at 262k, ~1.8 GiB at 1M)
leaves the head's *other software* deciding what survives. Upstream's record:
taking the memory too far does not error — **the machine stops answering and
has to be power-cycled**. The kit ships `scripts/memguard.sh` (2.5 GiB floor
held 4 s → kill the rank's container; 1 GiB → kill at once; a dip that
recovers is logged, not killed), `MIN_AVAIL_GIB=112` refusal at start, and
post-load headroom reporting. `ENGINE=jl` adds run-time admission refusal.
Their 655360-token incident (issue #17: rank 0 killed during a cache-hit turn
at 464k, head carried a desktop) is why this workspace keeps `CONTEXT ≤ 524288`
as the practical default on a busy head even though the manifest says 1M.

## Running it (when the disk is there)

```bash
ws up   tensorfold-2node-dsv41-flash-1017      # disk gate, then the kit: build/pull, download, both ranks, smoke
ws logs tensorfold-2node-dsv41-flash-1017 -f   # rank 0; rank 1: ssh <peer> docker logs -f dsv41-1017-exl3-tf
ws down tensorfold-2node-dsv41-flash-1017
```

`DRY_RUN=1` passes through to the kit and prints both ranks' commands. Then
the three questions, pointed at 8903 — remembering `tensorfold-native` returns
no token probabilities, so acceptance is proven by `tools/exact.py`
(drafted == plain), not by `spec-decode-accept`.

## Licence

Kit Apache-2.0; weights MIT (DeepSeek's, Mia's quantization); TensorFold fork
and BertholomusAI's kit Apache-2.0; optional `ABLIT=1` overlay (drowzeys/keys,
gated, MIT) replaces 104 attention tensors — not enabled here. Published image
`ghcr.io/miaai-lab/deepseek-v4.1-flash-1017-2x-dgx-sparks-tensorfold:exl3-tp2-7c9bf5d36350`.

## Sources

- [`MiaAI-Lab/DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks`](https://github.com/MiaAI-Lab/DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks) @ `31eea46`
- [`Mia-AiLab/DeepSeek-V4.1-Flash-1017-EXL3-EAQ-v1-2.9-bpw`](https://huggingface.co/Mia-AiLab/DeepSeek-V4.1-Flash-1017-EXL3-EAQ-v1-2.9-bpw) @ `6d54be4f`
- [`deepseek-ai/DeepSeek-V4.1-Flash-1017`](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017) @ `1bae0e10` (Engram shards 47-48 only)
- `docs/decisions.md#tensorfold-era`
