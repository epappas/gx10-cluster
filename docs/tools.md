# Tools

Every command this repo adds, what it does, and how to read its output.

The [runbooks](runbooks/) are organised by **task** — you have a problem, they
tell you what to do. This page is organised by **command** — you typed
`gx10-<tab>`, or read a tool name in a runbook, and want to know what it is
before you run it. Each entry ends with the runbook that puts it to work.

Nothing here is third-party. These are the tools this repo writes, installs and
owns; the stock CUDA, docker and RDMA utilities are documented by their vendors
and, where they lie to you on this hardware, in
[diagnose-interconnect](runbooks/diagnose-interconnect.md).

## At a glance

| Command | Installed by | Answers |
|---|---|---|
| [`gx10-status`](#gx10-status) | `roles/monitoring` | What is this box doing right now? |
| [`gx10-top`](#gx10-top) | `roles/monitoring` | What is the **cluster** doing right now? |
| [`gx10-sample`](#gx10-sample) | `roles/monitoring` | What was it doing at 03:00? |
| [`gx10-storage`](#gx10-storage) | `roles/monitoring` | Where did the disk go, and what can I get back? |
| [`gx10-interconnect`](#gx10-interconnect) | `roles/cluster` | Are the two boxes connected, and over what? |
| [`vllm-serve`](#vllm-serve) | `roles/inference` | Serve one model, one node, no ceremony |
| [`allreduce_test.py`](#allreduce_testpy) | `roles/cluster` | Does NCCL actually use the cable? |
| [`gx10env.sh`](#gx10envsh) | `roles/shell` | *(sourced)* PATH and CUDA env for every shell |
| [`gx10-sessionizer`](#gx10-sessionizer) | `roles/shell` | Which project am I switching to? |
| [`nvim`](#nvim) | `roles/editor` | The editor, and the keys that drive tmux from inside it |
| [`gpu-metrics.sh`](#gpu-metricssh) | `roles/observability` | GPU metrics for Prometheus *(opt-in)* |
| [`bootstrap.sh`](#bootstrapsh) | repo root | Get a fresh box to where Ansible can take over |
| [`make`](#make) | repo root | Everything else: check, apply, verify, bench |
| [`ws`](#ws) | `workspaces/` | Run a recipe on a ready machine |
| [`spec-accept`](#spec-accept) | `workspaces/bench/` | Is the speculative decoder working, and where does it fail? |
| [`prefill-ladder`](#prefill-ladder) | `workspaces/bench/` | How long is time-to-first-token, on a **genuinely cold** prompt? |
| [`tests/check_*.py`](#testscheck_py) | repo root | The offline gates `make check` runs |

## Conventions

**Exit status is meant to be gated on.** `gx10-interconnect` and `gx10-storage`
both return a status you can put in an `if`, not just text for a human. Where
that is true it is stated in the entry. Everything else returns 0 unless it
actually failed.

**A `Managed by gx10-cluster ansible` header means local edits are
overwritten.** Every tool here is a file in `roles/*/files/` or
`roles/*/templates/`; the copy on the node is a deployment. Edit the repo and
re-apply — see [contributing](contributing.md). The one thing that can go wrong
silently is the reverse: a tool changed in the repo and never applied, which
`make diff` catches and `make verify` mostly does not.

**Nothing here runs as a daemon, on purpose.** On a unified-memory box every MB
a monitoring service holds resident is a MB the model cannot use. So the
observability story is a script you run, not a service that runs — `gx10-top`
forks a collector per node, renders one frame and sleeps; `gx10-sample` is a
systemd *timer* that holds nothing between invocations. The opt-in
[`exporters`](runbooks/monitoring.md) role is the deliberate exception, and it
is opt-in for exactly this reason.

**Two install prefixes, and the split is load-bearing:**

| Prefix | Tools | Why |
|---|---|---|
| `/usr/local/bin` | `gx10-interconnect`, `gx10-top`, `gx10-storage`, `gx10-sample` | Invoked over SSH by their own cluster fan-out. `ssh <node> gx10-top` is a **non-login** shell and never gets `~/.local/bin` on PATH |
| `~/.local/bin` | `gx10-status`, `vllm-serve` | Per-user, only ever run interactively |

Get that backwards and the tool works perfectly by hand and fails only in the
`-c` / `--cluster` path, on the peer, where you are least likely to look.

---

## On the node

Present after `make apply`. All are on `PATH` for a login shell.

### gx10-status

Everything worth knowing about **this** box, with zero resident cost.

```bash
gx10-status          # once
gx10-status -w       # watch, 2 s refresh
```

Five sections, in the order you actually need them: **GPU** (util, temp, power,
SM clock), **Unified memory** — labelled *this IS GPU memory*, because
`nvidia-smi` reports `memory.total` as `[N/A]` on GB10 and the host figure is
the real one — **Top memory consumers**, **Disk** (where weights and swap live),
and **Serving** if something is listening.

If the utilisation counter looks wedged at a constant value, that is the
persistence-mode latch, not the tool:
[troubleshoot](runbooks/troubleshoot.md).

→ [monitoring](runbooks/monitoring.md)

### gx10-top

Every node side by side in one screen, live. Same zero-resident-cost bargain as
`gx10-status`, extended across the cluster.

```bash
gx10-top             # all nodes, 2 s refresh
gx10-top -i 5        # slower
gx10-top -1          # one frame and exit (scriptable)
gx10-top -H a,b      # explicit hosts
gx10-top -h          # usage
                     # q or Ctrl-C to quit
```

Nodes come from `/etc/gx10/interconnect.peers` plus this host, so it needs no
inventory of its own — `roles/cluster` writes that file.

The collector is **shipped to each node over stdin**, not installed alongside
the renderer. One file to deploy, and a renderer can never disagree with a
stale collector left behind by an older run.

Two things in the output surprise people, both deliberate:

- **The RoCE rows do not come from netdev counters.** RDMA bypasses the kernel
  network stack. Measured: pushing 66 GiB across the cable moved
  `/sys/class/net/<if>/statistics/tx_bytes` by exactly **0**. The rows read the
  RDMA port counter instead, which matched `ib_write_bw` to the byte. A
  netdev-based panel would show a flat zero on a link running at full speed.
- **The bars are ASCII, the sparklines are not.** `bash printf` pads `%*s` by
  bytes, not display columns, so a bar drawn with block characters misaligns
  the moment it is padded.

→ [monitoring](runbooks/monitoring.md#cluster-wide)

### gx10-sample

One CSV row of history per invocation, driven by a systemd timer.

```bash
gx10-sample          # append one sample (what the timer runs)
gx10-sample -r       # show the last 20 rows
gx10-sample -r 100   # show the last 100
```

It exists because `gx10-status` answers *what is happening now* and nothing
answered *what happened at 03:00*. A thermal cap or a swap excursion during an
overnight run is invisible by morning; the job is just mysteriously slow.

Twelve columns: `ts, gpu_util_pct, gpu_temp_c, gpu_power_w, sm_clock_mhz,
throttle, swcap_us, mem_avail_mb, swap_used_mb, nvme_temp_c, nic_temp_max_c,
load1`. `throttle` is `+`-joined rather than comma-joined so it stays one CSV
field.

Writes to `/var/log/gx10/metrics.csv` (`$GX10_SAMPLE_OUT`), ~1 MB/day at the
default 10 s interval, logrotated. Measured cost per sample: ~0.03 s wall,
~21 MB peak RSS, all transient.

→ [monitoring](runbooks/monitoring.md)

### gx10-storage

Where the 916 GB went, and which of it you can get back.

```bash
gx10-storage                    # report: pressure, attribution, reclaimable
gx10-storage -c                 # every node side by side
gx10-storage --top [N]          # biggest directories, wherever they are
gx10-storage --reclaim          # exactly what would be freed, and by which command
gx10-storage --reclaim --apply  # run the safe ones
gx10-storage -H a,b             # explicit hosts
```

**Exit status:** `0` free space above the floor · `1` below it, or below it once
planned weights land.

`gx10-status` already prints free space and the HF cache. On a real box that is
a small fraction of the answer — measured here at 660 GB used, the HF cache was
175 GB and **485 GB was outside it**, in directories nobody thinks to `du`.
Crossing the `$HOME` ↔ `/var` boundary is the whole reason this tool exists.

Every row carries a **class**, and the class — not the size — is what decides
whether `--apply` may touch it:

| class | What it is | In the reclaim plan? |
|---|---|---|
| `weights` | Model data, inside the HF cache or out | **never** — expensive to re-fetch, and no script can know you are done with it |
| `job` | Output somebody's run left behind | **never** — and unlike weights it may still be being written to |
| `image` | A docker image **built here**, in no registry | **never** — `docker pull` cannot bring it back |
| `crash` | Core dumps | yes — always regenerable, always safe |
| `cache` | Build, JIT and package caches | yes — deleting one costs a recompile, not data |
| `system` | Journal, apt archives, superseded snaps | yes |
| `fixed` | Swap | no — reported so the arithmetic adds up, never a candidate |

`image` versus `cache` for `/var/lib/docker` is decided at runtime, not by path:
the moment anything unused was **built** on this box the whole row becomes
`image`, because a locally-built image is closer to a weight than to a cache.
It is regenerable only in the sense that you still have the Dockerfile and an
hour, which is not the promise `cache` makes. The build cache underneath it
stays in the plan either way.

`--reclaim` without `--apply` prints the plan and runs nothing. That the
classifier keeps `weights` out of the plan is not left to trust:
`tests/check_storage.py` drives the real script against a fixture tree, because
a checkpoint that stops classing as `weights` would land in the plan and
`--apply` would then delete somebody's training run.

→ [manage-storage](runbooks/manage-storage.md)

### gx10-interconnect

Are the two GX10s connected, and over what fabric?

```bash
gx10-interconnect          # report — passive, generates no traffic
gx10-interconnect --peer   # also prove the RDMA path with a real round trip
gx10-interconnect --gids   # print each port's GID table and stop
```

**Exit status:** `0` healthy · `1` degraded, and the report says which line ·
`2` no interconnect hardware (an uncabled node — legitimately healthy).

It exists because **every InfiniBand-native way of asking returns nothing on
this hardware**, and "nothing" is indistinguishable from "not connected". The
ConnectX-7 runs an Ethernet link layer carrying RDMA as RoCE v2, so `ibhosts`,
`ibnodes`, `iblinkinfo` and `ibnetdiscover` all fail with `can't open UMAD
port`, and `base lid` / `sm lid` are always `0x0`. Every one of those is
**correct behaviour on a healthy cluster**. This tool reports the fabric that is
actually there instead of the one that is not.

`--gids` answers one narrow question that costs an hour by hand: **which GID
index carries the routable RoCEv2 IPv4 entry.** Nothing in this repo needs it —
NCCL selects the GID itself via `NCCL_IB_ROCE_VERSION_NUM=2` and
`NCCL_IB_ADDR_FAMILY=AF_INET` — but published recipes pin
`NCCL_IB_GID_INDEX=3`, and index 3 is not that entry here. Reading the table:

| Raw GID starts with | Means |
|---|---|
| `fe80:0000:…` | link-local IPv6 — never routes between the boxes |
| `0000:…:0000:ffff:` | IPv4-mapped; the last two groups are the address in hex |
| all `0000` | empty slot |

Every address appears **twice**, once as `IB/RoCE v1` and once as `RoCE v2`, at
adjacent indices. Only one row is the answer — v2 **and** IPv4-mapped — and the
tool marks it `<- THIS ONE`. Skip any block marked `(DOWN)`; those are the
uncabled ports. Confirm the same index on the peer before pinning anything.

→ [diagnose-interconnect](runbooks/diagnose-interconnect.md),
[two-node-serving](runbooks/two-node-serving.md#gid-index)

### vllm-serve

Serve a model with vLLM in the foreground. Ctrl-C stops it.

```bash
vllm-serve nvidia/Qwen3.6-27B-NVFP4
vllm-serve nvidia/Qwen3.6-27B-NVFP4 --max-model-len 8192
```

A thin, readable wrapper over one `docker run` — the model id is `$1`,
everything after it is passed through to vLLM verbatim. Rendered from a
template, so the image, bind address, port and `--gpu-memory-utilization` come
from `group_vars/all.yml`.

Two flags in it are not decoration: `--ipc=host`, because vLLM's workers talk
over shared memory and the default 64 MB kills them; and `--gpus all`, because
the NVIDIA runtime being the docker default here is a setting somebody could
change.

**As a service instead:** the same role installs a templated unit,
`vllm@.service`, deliberately **not enabled** — which model to serve is a
per-session decision, and pinning tens of GB at boot is nobody's sensible
default.

```bash
sudo systemctl start "vllm@$(systemd-escape 'nvidia/Qwen3.6-27B-NVFP4')"
```

Use `systemd-escape`, **not** a hand-rolled slash-to-hyphen substitution: model
ids contain hyphens too, so `deepseek-ai/DeepSeek-V4-Flash` cannot be recovered
by replacing the first one. `systemd-escape` and `%I` round-trip correctly.

For anything beyond one model on one node — two-node tensor parallelism,
quantised kits, drafters — use a [workspace](#ws) instead.

→ [serve-models](runbooks/serve-models.md)

### allreduce_test.py

Two-node NCCL all-reduce over the ConnectX-7 link. Installed to
`~/cluster/allreduce_test.py`, run under `torchrun` from both boxes.

```bash
# on odysseus
torchrun --nnodes 2 --nproc_per_node 1 --node_rank 0 \
         --master_addr odysseus --master_port 29500 allreduce_test.py
# on poseidon — same command, only --node_rank changes
```

Addresses come from `/etc/hosts`, which `roles/cluster` populates.

**Reading the result:** published two-node GB10 figures are around 10 GB/s bus
bandwidth. Well under that means the collective fell back to TCP over the LAN
instead of RoCE over the direct cable — re-run with `NCCL_DEBUG=INFO`, which
prints the transport and interface it chose.

→ [run-distributed](runbooks/run-distributed.md),
[benchmark](runbooks/benchmark.md)

### gx10env.sh

Not a command — `~/.gx10env.sh`, sourced by `~/.bashrc` and `~/.zshrc`. POSIX
`sh`, because both shells read it.

Puts `$CUDA_HOME/bin`, `~/.cargo/bin`, `~/go/bin` and `~/.local/bin` on PATH
idempotently, and sets the CUDA and allocator environment. `make verify` checks
it by grepping for `PYTORCH_CUDA_ALLOC_CONF`. It also sets `EDITOR`, `VISUAL`
and `MANPAGER` to neovim when neovim is installed.

It deliberately sets **no `NCCL_*` variables.** NCCL gives the environment
precedence over `/etc/nccl.conf`, so exporting them here would override the
system config for interactive runs only — giving a locally-launched rank and an
SSH-launched rank different settings, which is a Tuesday-works-Wednesday-fails
bug. `/etc/nccl.conf` owns NCCL.

→ [provision-node](runbooks/provision-node.md)

### gx10-sessionizer

`prefix f` in tmux, `<Space>tf` in neovim, or just run it. Fuzzy-picks a
project and switches to a tmux session named after it, creating the session if
it does not exist.

Candidates are, in order: sessions that already exist, git repositories up to
three levels under `$GX10_PROJECT_ROOTS` (default `~/src ~/projects ~/work`),
and whatever zoxide has learned. Existing sessions come first because switching
back to a running job is the common case, and a directory list cannot offer it.

Installed to `/usr/local/bin`, not `~/.local/bin`, for the same reason as
`gx10-top`: `tmux display-popup` runs the command through a non-login shell
that never sources `~/.gx10env.sh`.

→ [edit-code](runbooks/edit-code.md)

### nvim

Neovim at the version in `group_vars/all.yml`, installed to
`/opt/nvim-<version>` and symlinked into `/usr/local/bin` — **not** the apt
package, which is 0.9.5 on noble and too old for the config.

The configuration lives in `roles/editor/files/nvim` and is deployed to
`~/.local/share/gx10/nvim-<content hash>`, with `~/.config/nvim` a symlink at
it — so an apply swaps the tree rather than editing it, and nothing deleted
from the repo lingers on the node. Your own settings go in
`~/.config/nvim-local/init.lua`, outside the deployment, and are loaded last.
Plugins are pinned by commit in `lazy-lock.json` and restored, never updated,
so both nodes run identical trees.

Two commands worth knowing before anything else:

```vim
:GX10Servers      " which language servers are installed, and which attached
```

```bash
nvim --headless -c 'lua require("gx10.provision").doctor()' +qa   # same, with an exit code
```

→ [edit-code](runbooks/edit-code.md)

### gpu-metrics.sh

Opt-in, and only present after `make optional TAGS=exporters`. Writes GB10 GPU
metrics in Prometheus text format for node_exporter's textfile collector.

**Not exported: GPU memory.** `nvidia-smi` reports `memory.total` and
`memory.used` as `[N/A]` here because CPU and GPU share one coherent pool — so
node_exporter's *host* memory metrics already are the GPU memory metrics.
Emitting a zero would be worse than emitting nothing, and the `emit` helper
skips any value that is not numeric rather than writing a fake `0`.

→ [monitoring](runbooks/monitoring.md#if-you-want-metrics-over-time)

---

## In the repo

Run from a clone, not on the node.

### bootstrap.sh

The only thing you run by hand on a fresh box, and it stops where Ansible
starts.

```bash
./bootstrap.sh && ansible-playbook site.yml -K
```

Seeds `inventory.yml` from `inventory.example.yml` if absent — the real one is
gitignored, so a fresh clone has none and the play check would otherwise fail
on a file the clone was never going to contain. **Edit it afterwards.**

→ [provision-node](runbooks/provision-node.md)

### make

`make` on its own lists every target. The split that matters:

| Group | Targets | Needs hardware? |
|---|---|---|
| Offline gates | `check` and its 13 members — `lint`, `syntax`, `smoke`, `render`, `handlers`, `optional-tags`, `workspaces`, `detectors`, `spec-accept`, `prefill-ladder`, `storage`, `docs`, `lockfile`, `shellcheck` | no — this is what CI runs |
| Convergence | `diff`, `apply`, `verify`, `idempotence` | yes, plus sudo |
| Content | `models`, `optional`, `bench`, `lock` | yes |

Two invocation traps worth knowing before you hit them:

- **`make apply -e foo=bar` does not work.** `make` eats `-e` as
  `--environment-overrides` and the variable never reaches Ansible. Use
  `EXTRA='-e foo=bar'`.
- **`ASKPASS=` turns off the sudo prompt**, which you want once
  `sudo_passwordless` has been applied — it is on by default because before the
  first apply there is no sudoers drop-in yet, and it cannot work at all from a
  non-tty.

`make lock` must run **on a GX10**: the resolution is specific to aarch64 and
the cu130 index, and resolving it elsewhere produces a lockfile that installs
the wrong torch. The target refuses on any other architecture.

→ [contributing](contributing.md)

### ws

The workspace runner. Recipes for inference, cluster and RL environments —
**deliberately not Ansible**.

```bash
ws list                 # every workspace, with provenance
ws show   <name>        # the manifest, readably
ws check  <name>        # does THIS machine meet its requirements?
ws up     <name>        # start it (runs check first)
ws down   <name>        # stop it
ws logs   <name> [-f]   # tail it
ws status               # what is running
```

The division of labour is the point:

```
roles/       converge a machine to a state         (slow, rare, privileged)
workspaces/  run an environment on a ready machine (fast, often, unprivileged)
```

What you *run* on a machine changes far more often than the machine does.
Coupling the two means every experiment needs a playbook run and every recipe is
only reproducible through Ansible. The **only** coupling is the `requires:`
block in each `workspace.yml`, which `ws check` enforces; no workspace reads
anything from `roles/`, and no role knows a workspace exists.

Every recipe is plain docker/compose or a plain command, so you can read it,
copy it and run it by hand without this script. `ws list` renders provenance in
yellow — every workspace is currently `unverified`, meaning written from vendor
documentation rather than a completed run.

→ [workspaces](runbooks/workspaces.md)

### tests/check_*.py

The offline gates. Each exists because it catches something no other check can
see, and each says so in its own docstring.

| Gate | Catches |
|---|---|
| `check_handlers.py` | A typo'd `notify:`. Ansible only errors on an unknown handler when the notifying task reports *changed*, so it stays invisible on a provisioned box and detonates on a first-time provision |
| `check_optional_tags.py` | An `include_role` missing `apply:`. Without it `make optional TAGS=ray` includes the role, runs **zero tasks** and reports success |
| `check_docs.py` | A stale index, and dead relative links and anchors. A dead anchor is silent — the page loads and ignores the fragment |
| `check_workspaces.py` | A malformed or unrunnable manifest, a name/directory mismatch |
| `check_lockfile.py` | A lockfile regenerated without `--index-strategy`, or hand-edited by a security bump. Either turns one resolution into something that is not one |
| `check_detectors.py` | The serving quality gate's regexes quietly ceasing to match — which turns the gate green forever |
| `check_storage.py` | `gx10-storage` misclassifying weights, or planning to delete them |
| `check_spec_accept.py` | The acceptance parser and its ladder verdicts |
| `check_prefill_ladder.py` | The coldness proof. A contaminated rung is **fast**, not wrong — it reads as an optimisation that worked |

The common thread: every one of them guards a failure that is *silent and looks
like success*. `render.yml` is the same idea for templates — an undefined
variable or bad filter only surfaces when something renders.

→ [contributing](contributing.md)

---

## Inside a workspace

Run against a live server, usually via `ws up`.

### spec-accept

Is the speculative decoder actually working — and if not, **where** does it
fail? `workspaces/bench/spec-decode-accept/`.

```bash
ws up spec-decode-accept                       # the normal way
BASE_URL=http://127.0.0.1:8893/v1 ws up spec-decode-accept

./spec-accept --base-url URL [--model M] [--class structured|prose|both] \
              [--runs N] [--max-tokens N] [--timeout S] [--json PATH]
```

Every flag also reads an environment variable — `BASE_URL`, `MODEL`,
`PROMPT_CLASS`, `RUNS`, `MAX_TOKENS`, `TIMEOUT`, `JSON_OUT` — which is how `ws`
passes them.

**The failure this exists for:** a broken draft path costs acceptance and
nothing else. The target model still verifies every token, so the output stays
perfectly correct and you just get half the speed. No error, no warning, no
wrong answer to notice. It reads as bad hardware and sends people to rewrite
flags that were never the problem.

Aggregate acceptance answers *is the drafter working at all*. This answers the
harder question — acceptance **by draft position** — which is the only view that
separates the two ways a drafter breaks:

| Shape | Diagnosis |
|---|---|
| Every position low, curve falls smoothly | a weak drafter |
| Position 0 **healthy**, positions 1…k−1 collapse | a broken attention **mask** |

The second is what a causal mask inside a non-causal draft block produces: the
first drafted token is predicted from real context and is fine; every later one
is predicted from a block it is not allowed to see. Aggregate acceptance halves
and nothing else moves.

`--class both` is the default on purpose: prose alone cannot convict, and
structured alone hides that acceptance is text-dependent.

→ [workspaces](runbooks/workspaces.md),
[two-node-serving](runbooks/two-node-serving.md#failure-modes)

### prefill-ladder

Time-to-first-token on a **genuinely cold** prompt, measured so the number still
means something the next day. `workspaces/bench/vllm-prefill-ladder/`.

```bash
ws up vllm-prefill-ladder

./prefill-ladder --base-url URL [--model M] [--rungs 8000,12000,16000] \
                 [--page N] [--chunk-tokens N] [--tolerance 0.02] \
                 [--no-apc] [--timeout S] [--json PATH]
```

Prefill is the half of a request a user feels first — the seconds between
pressing enter and the first character — and no decode benchmark will ever show
it to you. On a long-context server it dominates.

**The one thing that makes or breaks a prefill number:** prefix caching is on
for every serving workspace here, so the second time you send a prompt it is
not a prefill at all, it is a cache hit wearing a prefill's clothes. Measured on
the kit this was ported from, rerunning a "cold" ladder without changing the
prompt took TTFT from **10.3 s to 1.9 s** — a 5× speedup that is entirely an
artefact of the measurement.

So every cold prompt starts with a unique salt (fresh UUID plus random pad)
placed **first**, before a single token of shared text, and the tool then
*checks* the server agrees by reading the prefix-cache hit counter across each
request. There is no reset to fall back on — these images expose no
`/reset_prefix_cache` — so salting is the only mechanism available. **A cold
rung that reports any hits is reported as invalid rather than fast.**

→ [workspaces](runbooks/workspaces.md),
[capacity-planning](runbooks/capacity-planning.md)

### Per-workspace helpers

Small, single-purpose scripts that live with the one recipe that needs them.
They are separate files rather than lines in a README because each is a *step
you can re-run*, and separate from `up.sh` because none is a precondition for
the server starting.

| Script | Workspace | What it does |
|---|---|---|
| `warmup.sh` | `vllm-2node-glm53-flash-exl3` | Burns the JIT shapes before the first real client does, then proves it worked. Triton and TileLang compile per **shape**, not per model; if that happens inside a served request on TP=2, the *other* rank sits in a collective waiting for it |
| `stage-weights.sh` | `vllm-2node-glm53-flash-exl3` | Copies this node's weights to the peer over the cable. Each rank loads from its own disk, and at 164 GiB the second copy is hours of WAN for bytes already sitting at the end of a link measured at 22.7 GB/s |
| `patch_kpool_tail_slotmap.py` | `vllm-2node-glm53-flash-exl3` | Clamps K-pool tail slot mapping to the one-block circular contract. The generic paged Triton kernel bounds token validity but not `block_indices` |
| `report.sh` | `sglang-nemotron35-lightning-nvfp4` | What the server **actually** allocated, not what you asked for. Token pool, KV size and `max_running_requests` are all derived at boot from a fraction of whatever memory was free at that moment — so a published capacity figure is an outcome, not a constant |

→ [two-node-serving](runbooks/two-node-serving.md)

---

## Libraries

Sourced, never executed. Listed because you will read them while debugging.

### workspaces/lib/common.sh

Shared by `ws`: colour helpers, `die`/`warn`/`ok`/`bad`, and the manifest
readers. `yq` is deliberately **not assumed** — it is not in the base image and
this repo does not install it — so these readers handle the flat subset of YAML
the workspace schema allows, and the schema stays flat so that remains true.

### workspaces/lib/twonode.sh

Launches one vLLM server across **both** nodes. Sourced by a workspace's
`up.sh`.

Every other recipe in `workspaces/` is deliberately standalone — read it, copy
it, run it by hand. Two-node serving is the one case where that trade goes the
other way, because **the failure mode of a mismatch is silent**: ranks that
disagree hang at init with no error, a container missing `/dev/infiniband`
quietly runs at TCP speed, and a gloo interface variable set in one recipe and
forgotten in another produces a cluster that works on Tuesday and not on
Wednesday. Two *workspaces* carrying their own copies of that wiring drift the
same way, just more slowly and with nobody watching.

So the wiring lives once. A workspace supplies only what is genuinely
model-specific:

| Required | Meaning |
|---|---|
| `NAME` | container name, on both nodes |
| `IMAGE` | same image on both ranks — a digest mismatch hangs at init |
| `PORT` | rank 0 serves here; rank 1 is headless |
| `MODEL_ARGS` | array of vLLM flags, and **only** model-specific ones |

Optional: `MASTER_PORT`, `SHM_SIZE`, `PEER`, `MASTER_ADDR`, `MGMT_IFACE`,
`IB_HCA`, `IB_GID_INDEX`, `VLLM_API_KEY`, `EXTRA_ENV`, `EXTRA_MOUNTS`,
`PRE_EXEC`. Topology, rendezvous and RDMA are set by the library, not by the
workspace.

→ [two-node-serving](runbooks/two-node-serving.md)

---

## Adding a tool

Put the script in `roles/<role>/files/` (or `templates/` only if it genuinely
substitutes something — a template that templates nothing is pure downside, and
shell is full of sequences Jinja claims: `${#arr[@]}` opens a comment tag, and
`{{ }}` / `{% %}` appear in `awk` and parameter expansion).

Then:

1. Install it from the role, with the right prefix — see the
   [table above](#conventions). Over-SSH callers need `/usr/local/bin`.
2. Add a `verify_checks` entry that tests **behaviour, not presence**.
   `test -x` proves only that a file exists; it passed for a fortnight against
   a stale `gx10-interconnect` whose `--gids` flag silently did nothing.
3. Add a gate under `tests/` if any part of it can be wrong without *looking*
   wrong — a parser, a classifier, a regex.
4. Add a row to the [table at the top of this page](#at-a-glance) and a section
   below it, and link the runbook that uses it.

`make check` enforces 1 and 4 indirectly (`check_docs.py` will fail on a broken
link) and `shellcheck` runs over every `#!/usr/bin/env bash` file in `roles/`
and `workspaces/`. See [contributing](contributing.md).
