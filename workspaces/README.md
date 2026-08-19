# Workspaces

Runnable recipes for inference, cluster and RL environments. **Not Ansible.**

```bash
./workspaces/ws list                        # what exists, and what has been run
./workspaces/ws check vllm-qwen3.8-27b-nvfp4  # does THIS machine qualify?
./workspaces/ws up    vllm-qwen3.8-27b-nvfp4
./workspaces/ws logs  vllm-qwen3.8-27b-nvfp4 -f
./workspaces/ws down  vllm-qwen3.8-27b-nvfp4
```

## Why this is separate from `roles/`

Two different jobs on two different clocks:

| | `roles/` (Ansible) | `workspaces/` |
|---|---|---|
| Converges | a **machine** to a state | nothing — it **runs** things |
| Frequency | rare, privileged, slow | constant, unprivileged, fast |
| Answers | "is this box ready?" | "what am I running today?" |
| Failure | the node is broken | today's experiment is broken |

What you run changes far more often than the machine does. Coupling them means
every experiment needs a playbook run, and every recipe is reproducible only
through Ansible. So Ansible stops at *ready* and workspaces take it from there.

**The only coupling is the `requires:` block**, checked by `ws check`. No
workspace reads anything from `roles/`, and no role knows a workspace exists.
Every recipe is plain `docker`/`compose` or a plain command — read it, copy it,
run it by hand without `ws` if you prefer.

## The engine × quantisation matrix

The single most expensive thing to learn the hard way here:

| | llama.cpp | vLLM | SGLang |
|---|---|---|---|
| **NVFP4** (~22.6 GB) | no | **yes** | **NO** — quantised `lm_head` |
| **GGUF Q4** (~17–19 GB) | **yes** | yes | yes |
| **MixedInt4-AutoRound** (20.8 GB) | no | **yes** | no |

GB10 is Blackwell (`sm_121`), so NVFP4 is the format this hardware exists for —
and it is exactly the one SGLang cannot load. Pick SGLang for its scheduler,
not to run NVFP4.

## One node or two?

| | Use |
|---|---|
| Model fits one node with useful KV cache | `vllm-qwen3.8-27b-nvfp4` — simpler, no fabric involved |
| Model does **not** fit, or KV cache is starved | `vllm-2node-tp2` — tensor-parallel across the cable |

The 120B NVFP4 is the worked example: 75 GB of weights against ~110 GB
available leaves ~35 GB for KV on one node, which is not worth doing. Split
across two, each holds ~37 GB and the KV budget roughly triples.

**Two-node serving has three requirements single-node does not**, and all three
fail quietly rather than loudly:

1. **`--device /dev/infiniband` and `--ulimit memlock=-1` on the container.**
   Without the device nodes, ibverbs finds no adapter *inside the container* and
   NCCL falls back to TCP. It still works — at a fraction of the speed — so it
   looks like a slow model, not a broken config.
2. **`GLOO_SOCKET_IFNAME` and `TP_SOCKET_IFNAME`.** vLLM's distributed init is
   `torch.distributed`, and gloo does **not** read `NCCL_SOCKET_IFNAME`. Unset,
   it can pick `docker0` or the VPN and the ranks never meet.
3. **Identical image and flags on both ranks.** Mismatched ranks hang at init.
   `vllm-2node-tp2` launches both from one script so this cannot drift.

Always confirm the transport rather than assuming it:

```bash
docker logs ws-vllm-2node 2>&1 | grep -E 'NET/IB|NET/Socket'
```

`NET/IB` is ibverbs and covers RoCE — that is what you want. `NET/Socket` means
you are on TCP.

## Sampling: thinking vs instruct is not a preference

Qwen3.8 ships two documented parameter sets and using the wrong one degrades
output quality measurably:

| | temperature | top_p | top_k | presence_penalty |
|---|---|---|---|---|
| Thinking | 1.0 | 0.95 | 20 | 0.0 |
| Instruct | 0.7 | 0.80 | 20 | 1.5 |

Reasoning depth is separate: `--chat-template-kwargs '{"reasoning_effort":"medium"}'`
(`xhigh` default, then `medium`, `low`, `none`).

## Memory is the constraint, and it is one pool

On GB10 host memory **is** GPU memory. A serving workspace taking
`--gpu-memory-utilization 0.84` is claiming 84% of the same 121 GB that holds
the page cache, your shell, and any desktop session (~1.2 GB for Xorg and
gnome-shell). Two workspaces at those settings do not co-exist.

This is why `ws check` reads `MemAvailable` rather than asking `nvidia-smi`,
which reports `[N/A]` for memory on this hardware and cannot answer the
question. Watch it with `gx10-top`.

## Provenance

Same rule as the docs: **`verified` means it was run on this hardware.**
`ws list` colours it — green verified, yellow written-but-never-run.

Every workspace here is currently **unverified**. They are written from vendor
documentation and the sources listed in each `workspace.yml`, not from a
completed run. Expect to fix something the first time. When you do, fix the
recipe, flip `provenance`, and say what changed.

## Adding one

```
workspaces/<kind>/<name>/
  workspace.yml     required — manifest
  compose.yml       or up.sh/down.sh
  .env.example      optional; the real .env is gitignored
```

`workspace.yml` is deliberately a flat subset of YAML (`ws` parses it with awk
rather than depending on `yq`, which this repo does not install):

```yaml
name: my-thing            # must equal the directory name
kind: inference           # inference | cluster | rl
engine: vllm
provenance: unverified    # verified once you have run it
summary: one line, shown in `ws list`
requires:                 # all optional; each is checked by `ws check`
  gpu_arch: "12.1"        # compute capability
  min_unified_gb: 40      # against MemAvailable
  docker: true
  rdma: true              # an ACTIVE RoCE port
  peers: 1                # SSH-reachable peer nodes
images:   [...]           # warned about if not pulled
models:   [...]           # HF ids; warned about if not cached
endpoints: [...]
sources:  [...]           # where the flags came from — required in practice
```

`make check` validates every manifest, so a typo in a key fails offline rather
than at 3am.

## Secrets and local values

Same three tiers as the Ansible half
([why](../docs/decisions.md#private-vars)): tracked defaults in the recipe, a
gitignored `.env` per workspace for what is yours, and nothing secret in the
repo. `.env.example` is the tracked template.

## Relationship to `roles/ray` and `roles/slurm`

Both exist, and they are not duplicates:

- **Ray** — `roles/ray` installs a *standing* systemd service;
  `workspaces/cluster/ray` starts an *ephemeral* containerised cluster for one
  experiment. They will fight over ports. Pick one. For RL, prefer the
  ephemeral one: verl pins a Ray version and you want that one, not whatever
  the host was provisioned with.
- **Slurm** — the daemons stay with Ansible on purpose. A scheduler is
  infrastructure: munge keys, controller state, a daemon per node, a shared
  clock. `workspaces/cluster/slurm` ships only the part that changes per
  experiment — the job scripts.
