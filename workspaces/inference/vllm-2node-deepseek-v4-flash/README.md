# vllm-2node-deepseek-v4-flash

> DeepSeek-V4-Flash (284B total / 13B active) at FP8, tensor-parallel across
> **both** GX10s over RoCE, with DSpark speculative decoding. **The default way
> to run DeepSeek on this cluster.**

| | |
|---|---|
| Kind | `inference` |
| Engine | vLLM (container, both nodes) |
| Nodes | **2** — rank 0 serves, rank 1 is headless |
| Endpoint | `http://127.0.0.1:8890/v1` **on the rank-0 node** |
| Needs | ~100 GB unified *per node* · ~170 GB disk · Docker · ACTIVE RDMA · 1 peer |
| Provenance | `unverified` — written from the sources below, never run on this hardware |

## What

The model-specific sibling of
[`vllm-2node-tp2`](../vllm-2node-tp2/README.md). That workspace took the
*generic* half of the published 2× DGX Spark recipes; this is where the
DeepSeek half lives — the v4 tokenizer mode, the reasoning and tool parsers,
the FP4 indexer cache, DSpark drafts, and a `--max-num-seqs` low enough to be
honest about the KV budget.

They share the launcher ([`lib/twonode.sh`](../../lib/twonode.sh)) and nothing
else.

**Full two-node mechanism, prerequisites and debugging:
[the two-node serving runbook](../../../docs/runbooks/two-node-serving.md).**

## Why

### The arithmetic, because it is the whole design

| | |
|---|---|
| FP8 checkpoint | ~149 GiB |
| Split TP=2 | ~75 GiB of weights **per node** |
| Claimable at `0.80` | ~97 GiB per node (of 121 GiB unified) |
| **Left for KV** | **~22 GiB per node** |

Every non-obvious default in `up.sh` falls out of that last line.
`--max-num-seqs` is **6**, not 256. `--max-model-len` is **128K**, not the 1M
the model supports. Both look timid; both are the honest numbers for 22 GiB of
KV, and both match the measured 2× DGX Spark profile.

### Why not one node

The single-node alternative,
[`llamacpp-deepseek-v4-flash-gguf`](../llamacpp-deepseek-v4-flash-gguf/README.md),
runs `UD-IQ2_M` — a 2-bit quantisation — with ~21 GB left over. This runs the
same model at **FP8** with real KV cache. If both nodes are available, there is
no argument for the single-node version.

### Why not V4-Pro

**V4-Flash-0731 beats V4-Pro on every published agentic benchmark**, despite
13B active parameters against 48B. V4-Pro does not fit two nodes at any
quantisation ([the ladders](../../../docs/decisions.md#deepseek-v4)). Choosing
Flash is not a downgrade.

## When to use it — and when not

| Use it when | Use something else when |
|---|---|
| You want DeepSeek-V4 on this cluster, at all | You have one node → [`llamacpp-deepseek-v4-flash-gguf`](../llamacpp-deepseek-v4-flash-gguf/README.md) |
| You are driving an agent harness | You want a *generic* 2-node recipe → [`vllm-2node-tp2`](../vllm-2node-tp2/README.md) |
| You need tool calls and reasoning as structured fields | You need 1M context — possible, but read the trade below |

## How

```bash
ws check vllm-2node-deepseek-v4-flash   # checks THIS node only
ws up    vllm-2node-deepseek-v4-flash
docker logs -f ws-vllm-ds-v4-flash
curl -s localhost:8890/health && echo ready
```

**~149 GiB of weights split two ways.** Off a cold cache the first run also
downloads them. Expect **tens of minutes** before `/health` answers.

Confirm the transport before blaming the model:

```bash
docker logs ws-vllm-ds-v4-flash 2>&1 | grep -E 'NET/IB|NET/Socket'
```

### Then check it is answering *correctly*

This is the model in this repo most exposed to cold-prefill and concurrency
faults, and none of them move a tok/s number:

```bash
BASE_URL=http://127.0.0.1:8890/v1 ws up vllm-quality-gate
```

See [`vllm-quality-gate`](../../bench/vllm-quality-gate/README.md).

### Sampling

**Not** the Qwen table: **temperature 1.0, top_p 1.0** (0.95 for agentic).
Reasoning effort is a request field, not a server flag:
`--chat-template-kwargs '{"reasoning_effort":"high"}'`.

## The flags that are load-bearing

| Flag | Why it is not cosmetic |
|---|---|
| `--tokenizer-mode deepseek_v4` | V4 ships **no Jinja chat template** — it encodes with Python |
| `--reasoning-parser` / `--tool-call-parser deepseek_v4` | Turns reasoning traces and tool calls into structured fields instead of raw text in `content` |
| `--block-size 256` | Not the default 16. MLA reads a compressed latent per block; every published V4 config sets this |
| `--attention-config '{"use_fp4_indexer_cache": true}'` | Belongs to V4's compressed attention. In every official launch line |
| `--long-prefill-token-threshold 1024` | Without it a single 128K prompt serialises the server and concurrent chats appear to hang |
| `--generation-config vllm` | Prefer vLLM's sampling defaults over the checkpoint's. Silently inheriting someone else's temperature is how two "identical" servers disagree |

### `--gpu-memory-utilization` is the one value a smoke test cannot validate

Speculative decoding allocates its verify buffers on the **first real request**,
not at boot. A utilisation slightly too high boots cleanly, passes a smoke test,
serves a few requests, then dies under traffic — every quick check you would
run says it is fine.

If that is the shape of your failure, this is the **first** knob, not the last.
The published 2× Spark profile moved `0.80 → 0.78` for exactly this.

### DSpark drafts, and the number that tells you they work

`num_speculative_tokens` is **5**, not the model card's 7 — the card is written
for a 4×GB300 node, where a rejected draft costs less than it does here.

**Whether any of it is working is one number, and it is acceptance.** A broken
draft path costs acceptance and *nothing else*, because the target model still
verifies every token: output stays perfectly correct at half the speed, which
reads as bad hardware or a bad recipe and sends people off to rewrite flags.
`ws up vllm-bench-serve` reports it live.

`draft_sample_method` is carried because the published recipes carry it, **not**
because it does anything: the DSpark proposer only populates draft
probabilities under `VLLM_DSPARK_EXPORT_DRAFT_PROBS=1`, so greedy and
probabilistic take the same rejection-sampler path. The widely-circulated claim
that probabilistic is worth ~50% more throughput was withdrawn by its authors
after re-measurement. Do not spend a day here.

## The 1M-context path, and what it costs

1M context on two GB10s is real, but it rests entirely on **`nvfp4_ds_mla`** — a
sparse-MLA KV dtype with a 584-byte envelope per token. Upstream vLLM does not
have it; it comes from the DSpark fork lineage.

Asking for 1M on `fp8` does **not** fail at startup. It fails later, as
preemption, which reads as "the model got slow" rather than "the context was a
lie".

Switching to the fork means pinning this model to one project's release cadence
— a real trade, not a free upgrade. `.env.example` carries the full recipe and
[`decisions.md`](../../../docs/decisions.md#dspark-1m-recipe) carries the
reasoning. One trap if you do take it: **never omit `num_speculative_tokens` on
the fork image.** On that lineage the value falls back to
`num_nextn_predict_layers = 1`; the server boots, speculates one token per step,
reports nothing unusual, and you lose most of the speed the fork was taken for.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| Hangs at init | Ranks never met, or flags differ between ranks | Both ranks come from one script, so this means the peer's environment differs — check the image digest |
| Works, but slow | TCP fallback | `grep -E 'NET/IB\|NET/Socket'` in the logs |
| Boots fine, dies under real traffic | Speculative verify buffers — `GPU_MEMORY_UTILIZATION` slightly too high | Try `0.78` |
| Correct output at half the expected speed | Draft path silently broken | Watch acceptance in `ws up vllm-bench-serve` |
| Server "got slow" at long context | Preemption — 1M asked for on an `fp8` KV | Lower `MAX_MODEL_LEN`, or take the fork path knowingly |
| Empty replies, full token bill | The budget expired before `</think>` | Raise the client's `max_tokens` above ~1024 |
| `ws check` passes, `ws up` OOMs on the peer | `ws check` measures one node | Run it on both |

## Sources

- <https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash-DSpark>
- <https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash-0731>
- <https://recipes.vllm.ai/deepseek-ai/DeepSeek-V4-Flash>
- <https://github.com/MiaAI-Lab/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark>
- <https://github.com/tonyd2wild/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark>

See also: [`workspace.yml`](workspace.yml) · [`lib/twonode.sh`](../../lib/twonode.sh) ·
[two-node serving](../../../docs/runbooks/two-node-serving.md) ·
[what was ported from the 1M recipe](../../../docs/decisions.md#dspark-1m-recipe)
