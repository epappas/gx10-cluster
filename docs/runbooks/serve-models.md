# Runbook: serve and run models

**What** — run open-weight models on the GX10, locally or over the network.
**When** — after `make apply`; models need `make models` (long).

## Why vLLM runs in a container here

vLLM has **no official sm_121 support**. Its pip wheels carry kernels up to
sm_120 and link `libcudart.so.12`, while this box has CUDA 13 — so the wheel
installs and then crashes at startup. sm_120 and sm_121 are binary compatible,
which is why the CUDA-13 *image* works where the wheel does not.

The container also keeps a fast-moving, unsupported-on-this-arch dependency out
of the ML venv: a bad version is a tag change, not a rebuild.

## What fits

Sizes and the disk budget live in [manage-models](manage-models.md#what-fits).
The short version: prefer **NVFP4** — it is the native format for GB10's
Blackwell FP4 tensor cores, so it is smaller *and* faster here. The 120B fits
one node at NVFP4 (74.8 GB) but not at FP8 or BF16.

## Three ways to run a model

**ollama** — quickest, good for chat and quick checks:

```bash
ollama run qwen3:8b
```

It runs as a system service from a pinned, checksum-verified release tarball —
not the vendor install script, whose back half installs CUDA drivers
([why](../decisions.md#ollama-comes-from-a-pinned-release-tarball-not-curl--sh)).
The service is bound to `ollama_host` (`127.0.0.1:11434`) and capped at
`OLLAMA_MAX_LOADED_MODELS=1`, because two large models resident on unified
memory is how you reach the swap cliff.

```bash
systemctl status ollama
ssh -L 11434:localhost:11434 odysseus     # reach it from your laptop
```

**llama.cpp** — GGUF, fine-grained control, best for quantized single-stream:

```bash
pcore llama-server -m <model.gguf> --no-mmap -t 10   # --no-mmap: see below
llama-bench -m <model.gguf>
```

`--no-mmap` matters on unified memory: mmap'd weights are pageable, and pageable
host-to-device copies are much slower here than pinned ones. `-t 10` and `pcore`
match the ten performance cores — they
[interleave](../hardware.md#the-cpu-cores-interleave), so `taskset -c 0-9` is
half E-cores.

**vLLM** — throughput serving with an OpenAI-compatible API:

```bash
vllm-serve nvidia/Qwen3.6-27B-NVFP4
vllm-serve nvidia/Qwen3.6-27B-NVFP4 --max-model-len 8192
```

Then:

```bash
curl http://localhost:8000/v1/models
curl http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"nvidia/Qwen3.6-27B-NVFP4","messages":[{"role":"user","content":"hi"}]}'
```

As a service (survives logout, restarts on failure):

```bash
sudo systemctl start "vllm@$(systemd-escape 'nvidia/Qwen3.6-27B-NVFP4')"
journalctl -u "vllm@$(systemd-escape 'nvidia/Qwen3.6-27B-NVFP4')" -f
```

`systemd-escape` is not optional — model ids contain both `/` and `-`, and only
systemd's own escaping round-trips them correctly.

## Both nodes

A model too big for one box is served with Ray plus
`--tensor-parallel-size 2`; see [run-distributed](run-distributed.md#ray). Ray
is opt-in (`make optional TAGS=ray`) and refuses to install until the QSFP cable
is in and addressed — it binds to the interconnect address and will not quietly
fall back to WiFi.

## When it fails

| Symptom | Cause |
|---|---|
| `no kernel image is available` | Something used a pip vLLM/torch instead of the container or cu130 index |
| OOM at load, or the box crawls | Model exceeds the pool — see [what fits](manage-models.md#what-fits); lower `vllm_gpu_memory_utilization` |
| `CUDA error: out of memory` mid-run | KV cache growth; lower `--max-model-len` |
| Port 8000 refused | Bound to `vllm_bind` (localhost) by design — `ssh -L 8000:localhost:8000 <node>` |
| Reachable over SSH, invisible to a Meshnet peer | Meshnet drops peer traffic to `172.17.0.0/16` — [fix](troubleshoot.md#a-meshnet-peer-cannot-reach-a-container-here) |
| `docker: permission denied` | Docker group needs a new login — [troubleshoot](troubleshoot.md#docker) |

vLLM sizes its KV cache from NVML, which on GB10 reports **no framebuffer** —
so it profiles against a pool the OS also lives in. That is why
`vllm_gpu_memory_utilization` defaults to 0.85 here rather than the usual 0.9+.

## The answers are wrong, not slow

Every check above asks whether the server is *up* and how *fast* it is. A
serving stack can pass all of them while returning garbage, and the failures
that do this are not model quality — they are the scheduler, the speculative
decoder and the reasoning parser:

| What you see | What it actually is |
|---|---|
| Reply opens mid-word, or echoes prompt/tool text | Spec-decode placeholders attached to the last chunk of a **cold** chunked prefill |
| `""` returned, full token budget billed | Reasoning ran past `max_tokens` before `</think>`; the parser then emits **neither** content nor reasoning |
| Reply drifts into another script, or repeats a phrase forever | A reasoning runaway — different from a long answer, and `max_tokens` does not fix it |
| Special tokens (`<｜begin▁of▁sentence｜>`) in the content | Detokenizer or template fault, not the model |

**A five-prompt smoke test cannot find any of them**, and this is the part
worth internalising: both conditions that produce them are ones a smoke test
does not create.

- **Cold prefill.** The corruption attaches to the final chunk of a long
  *first* prefill. A prefix-cache **hit never fails** — so asking the same
  question twice makes the problem look self-healing, and the second answer is
  the one you believe.
- **Concurrency.** Several appear only with more than one sequence in flight.

So the gate forces both:

```bash
ws up vllm-quality-gate                       # cold prefill, concurrency ladder
BASE_URL=http://127.0.0.1:8890/v1 ws up vllm-quality-gate -c 1,8 -n 8
ws up vllm-quality-gate --warm                # the control: this should pass
```

It exits non-zero if any request tripped a detector, so it works in front of a
deployment and not only as something to read. It also checks, off
`vllm:prefix_cache_hits`, that the run really was cold — an assertion nobody
verifies is a comment.

**`max_tokens` is a detector setting here, not a performance one.** With
reasoning enabled, a budget that runs out before `</think>` produces an empty
reply, and the rate is entirely a function of the budget — measured elsewhere
at temperature 0.5 with thinking on: 256 → 83% empty, 512 → 50%, 768 → 17%,
1024 → 0 of 18. Below ~1024 you are measuring your own cap.

The same trap ruins evaluations. A model scored with reasoning **on** and an 8K
cap can score *worse* than the same model with reasoning off, purely because
every failure is `finish_reason=length`. Report the thinking setting, and retry
length-capped failures with a real budget, or the number describes the harness.

One client-side detail that looks like a server fault: this family of runtimes
returns the reasoning trace in **`reasoning`**, while OpenAI-compatible clients
read **`reasoning_content`**. A client that knows only the second one renders
"Thinking…" until the whole response lands, and reports zero reasoning on a
server that is producing plenty.

### Correct output at half speed

Two causes, both of which leave output perfectly correct — which is exactly why
they get misdiagnosed as a bad recipe:

- **Draft acceptance collapsed.** On a speculative server, a broken draft path
  costs acceptance and *nothing else*: the target model still verifies every
  token. `ws up vllm-bench-serve` shows acceptance and tokens/step live. Below
  ~25% on a config that used to be fine, suspect the draft path — skipped
  draft weights, or a draft length the runtime silently clamped — before you
  touch any flag.
- **One node is clocked down.** A tensor-parallel pair is lockstep, so it runs
  at the **slowest** node's clock; a node that came back from a reboot in a low
  power state halves the deployment while its config, its image and its
  acceptance all look identical to its partner's. `gx10-top` and the bench view
  both flag the asymmetry between busy nodes. Check under load:

  ```bash
  nvidia-smi --query-gpu=clocks.sm,power.draw --format=csv,noheader
  ```

  Asymmetry between the two nodes is the finding. (`nvidia-smi -lgc` is the
  documented remedy on other Blackwell parts; this repo has not measured
  whether it is settable on GB10, where `-pl` and `-ac` are not — see
  [hardware](../hardware.md).)
