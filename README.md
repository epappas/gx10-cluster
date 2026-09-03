<div align="center">

# gx10-cluster

**Turn NVIDIA GB10 boxes into a working GPU cluster — and then actually run things on it.**

[![CI](https://github.com/epappas/gx10-cluster/actions/workflows/ci.yml/badge.svg)](https://github.com/epappas/gx10-cluster/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-aarch64%20Ubuntu%2024.04-lightgrey)
![Hardware](https://img.shields.io/badge/hardware-NVIDIA%20GB10%20%C2%B7%20DGX%20Spark-76B900)
![Daemons](https://img.shields.io/badge/monitoring%20daemons-0-success)

[Quickstart](#quickstart) ·
[The two halves](#the-two-halves) ·
[Workspaces](#workspaces) ·
[What GB10 teaches you the hard way](#what-gb10-teaches-you-the-hard-way) ·
[Runbooks](#runbooks) ·
[Docs](#reference)

</div>

---

## What this is

Ansible that provisions ASUS Ascent GX10 / NVIDIA DGX Spark nodes, links them
over the ConnectX-7 cable, and ships three zero-cost diagnostic tools — plus a
catalogue of **runnable recipes** for serving, benchmarking, gating and
agent-driving the models you then want to run on it.

Two claims hold the whole thing together:

> **Every non-obvious choice has a written reason**, one entry per choice in
> [decisions.md](docs/decisions.md).
>
> **Every hardware claim says whether it was measured or merely read on a
> forum.** Unlabelled means it was run here, with the command in the doc
> ([provenance](docs/README.md#provenance)).

Most GB10 information online is community-written, some machine-generated, and
some of it is wrong. That is the gap this repo exists to close.

## Is this for you?

| You… | Then |
|---|---|
| own one or more **GB10 / DGX Spark** boxes | Run it — this is exactly what it is for |
| own **one** box, not two | Fine. The cluster half skips cleanly when uncabled |
| are debugging GB10 and landed here from a search | **You do not need the playbook.** Jump to [what GB10 teaches you](#what-gb10-teaches-you-the-hard-way) — that is the half most people want |
| want to serve a big model on two Sparks | [Two-node serving](docs/runbooks/two-node-serving.md), and [will it fit?](docs/runbooks/capacity-planning.md) |
| have different GPU hardware | Read the decisions, skip the playbook. `site.yml` asserts `sm_121` and refuses to run elsewhere |

## The two halves

This is the single organising idea of the repo, and everything else follows
from it.

```
  ┌──────────────────────────┐        ┌──────────────────────────┐
  │        roles/            │        │       workspaces/        │
  │        (Ansible)         │   →    │        (recipes)         │
  ├──────────────────────────┤        ├──────────────────────────┤
  │ converges a MACHINE      │        │ converges nothing —      │
  │ to a state               │        │ it RUNS things           │
  │                          │        │                          │
  │ rare · privileged · slow │        │ constant · unprivileged  │
  │                          │        │          · fast          │
  │ "is this box ready?"     │        │ "what am I running       │
  │                          │        │  today?"                 │
  │ failure = node broken    │        │ failure = today's        │
  │                          │        │  experiment broken       │
  └──────────────────────────┘        └──────────────────────────┘
              └──────── requires: ─────────┘
                 the ONLY coupling
```

**What you run changes far more often than the machine does.** Coupling them
means every experiment needs a playbook run, and every recipe is reproducible
only through Ansible. So Ansible stops at *ready*, and workspaces take it from
there ([why](docs/decisions.md#workspaces)).

The only seam is each workspace's `requires:` block, checked by `ws check`. No
workspace reads anything from `roles/`, and no role knows a workspace exists —
so when `ws check` fails it names an Ansible fix, and when a workspace fails
*after* checks pass, the machine is fine.

## What it looks like

`gx10-top` — every node in one screen, **nothing resident between refreshes**:

```
 gx10-top  2 node(s) · 2s · q quits · inet 1.1.1.1  07:12:44
   OK    nodes agree · nothing throttled · no swap growth

                                     odysseus                poseidon
  GPU   util                [#########-]  96%       [----------]   0%
        trend                              ▇▇                      ▁▁
        temp/power                71C  89.26W             52C  11.07W
        throttle                         none                    none
        on-GPU          41642M @train-7f2a91c4  431M @infer-pool-d64
  CPU   total               [#---------]  11%       [----------]   1%
        P-cores             [##--------]  21%       [----------]   1%
  BUSY  top by cpu       103.0% python   737.7M      3.5% bash     3.3M
  MEM   used(=GPU)          [####------]  45%       [----------]   6%
        swap                           636 kB                 2316 MB
  THERM hottest C        nic 57 soc 51 ssd 47    nic 56 soc 54 ssd 49
  NET   RoCE p1s0f0             v44.2M ^17.6G           v15.1G ^37.8M
        RoCE mtu                     mtu 9000                mtu 9000
        reach            gw 0.7ms  net 14.6ms    gw 0.7ms  net 13.7ms
  DOCK  containers                1/1 running             2/2 running
```

<sub>Real output, but a composite of two captures — the GPU load and the RoCE
traffic were measured minutes apart. Container names are placeholders.</sub>

The `@` prefix marks a **container** — `nvidia-smi` only ever sees a host pid, so
"which container is using the GPU" has no answer without this.

`gx10-interconnect` — what the fabric actually is, and whether it works:

```
Fabric
  RoCE v2 over Ethernet - there is NO InfiniBand subnet here, by design.
  MT4129, firmware 28.45.4028
Links
  rocep1s0f0     enp1s0f0np0      ACTIVE  200 Gb/sec
                                  addr 192.168.100.10/24  mtu 9000 (RoCE 4096)
                                  PCIe 5.0 x4, ~126 Gb/s ceiling
Peers
  poseidon   192.168.100.11   RDMA ok via enp1s0f0np0 - 1.71 us write latency
Interconnect healthy.
```

Exit code `0` healthy · `1` degraded · `2` no NIC, so you can gate on it.

## Quickstart

```bash
git clone https://github.com/epappas/gx10-cluster && cd gx10-cluster
./bootstrap.sh            # installs ansible via uv, no sudo; seeds inventory.yml
$EDITOR inventory.yml     # your hostnames and addresses - see below
make apply                # provisions EVERY node in the inventory
# log out and back in     -- picks up docker/nordvpn groups, zsh, shell env
make verify               # asserts the nodes are in the expected state
```

Then run something on it:

```bash
./workspaces/ws list                          # the catalogue
./workspaces/ws check vllm-qwen3.8-27b-nvfp4  # does THIS machine qualify?
./workspaces/ws up    vllm-qwen3.8-27b-nvfp4  # -> :8888, OpenAI-compatible
```

`make` on its own lists every target. First run needs a sudo password; after
that a sudoers drop-in removes the prompt — details and the full preflight
checklist are in [provision-node](docs/runbooks/provision-node.md).

### Three things worth reading before the first run

**`inventory.yml` is gitignored** — your hostnames and addresses never enter the
repo. `bootstrap.sh` seeds it from `inventory.example.yml`, which ships two
example nodes to replace: hostnames, `ansible_host` addresses, and
`cluster_index`. Its `192.0.2.x` addresses are RFC 5737 documentation addresses
and route nowhere on purpose, so forgetting to edit fails fast rather than
reaching some other device on your LAN.

**Your username is not in there.** The account to log in as comes from
`gx10_user` in `group_vars/all.yml`, which defaults to whoever you are locally.
Set it only if the account on the boxes differs — and prefer the private tier
over editing a tracked file ([three tiers](docs/runbooks/manage-secrets.md)):

```bash
make apply EXTRA='-e gx10_user=ubuntu'    # once, or set it in group_vars/gx10/local.yml
```

**The inventory name *is* the machine's hostname.** The play sets it, and
`/etc/hosts`, `~/.ssh/config`, the Slurm `NodeName` and the Prometheus label all
derive from that one string
([renaming](docs/runbooks/provision-node.md#renaming-a-node)).

### Two things the play deliberately cannot do for you

- **Move the cluster admin private key off the node.** Generated at
  `~/.ssh/gx10_admin`; it belongs on your laptop
  ([how](docs/runbooks/provision-node.md#the-cluster-admin-key)).
- **Join the Meshnet.** The client is installed and the firewall is open, but
  logging in needs a token you generate
  ([how](docs/runbooks/provision-node.md#join-the-meshnet)).

## Workspaces

Runnable recipes for everything you would actually do with the cluster. Each
one has **its own README** answering what it is, why it exists, when to reach
for it and how to run it — the [catalogue](workspaces/README.md) is the map.

| Kind | Workspaces | Note |
|---|---|---|
| `inference` | 10 — vLLM, llama.cpp, SGLang; one node and two | These start a model. **No two co-exist** — one memory pool |
| `bench` | 4 — a concurrency sweep, a correctness gate, a draft-acceptance probe and a cold-prefill ladder | Clients. They **do** co-exist with a server |
| `agent` | 1 — DeepSeek's harness, pointed at your own server | So no token leaves the house |
| `cluster` / `rl` | 3 — ephemeral Ray, Slurm job scripts, verl GRPO | |

Three questions the catalogue answers that nothing else does:

| Question | Where |
|---|---|
| **Will this model even fit?** | [capacity-planning](docs/runbooks/capacity-planning.md) — the arithmetic, before you download 150 GB |
| **How do I run one model across both nodes?** | [two-node-serving](docs/runbooks/two-node-serving.md) — and the three things that fail *quietly* |
| **Is my server fast, or is it fast and wrong?** | [`vllm-quality-gate`](workspaces/bench/vllm-quality-gate/README.md) — a third check, which exits non-zero |
| **Is it slow because the drafter is broken?** | [`spec-decode-accept`](workspaces/bench/spec-decode-accept/README.md) — acceptance per draft *position*, the one failure that costs speed and nothing else |
| **How long until the first character — really?** | [`vllm-prefill-ladder`](workspaces/bench/vllm-prefill-ladder/README.md) — cold prefill *proven* cold, because a rerun hits the prefix cache and looks like an optimisation |

## What GB10 teaches you the hard way

The playbook is the smaller half of this repo. These are findings that cost real
debugging time, each measured on the hardware:

| Finding | Why it bites |
|---|---|
| **There is no InfiniBand.** The ConnectX-7 runs Ethernet and carries RDMA as RoCE v2 | `ibhosts`, `iblinkinfo` and `ibnetdiscover` all fail with `can't open UMAD port` on a *perfectly healthy* cluster, and "nothing" reads as "not connected" ([why](docs/decisions.md#roce-not-ib)) |
| **`nvidia-smi` cannot report GPU memory** | Host memory *is* GPU memory. `free -h` is your VRAM monitor; imported dashboards show blank tiles ([detail](docs/runbooks/monitoring.md)) |
| **`nvidia-smi` can report 96% utilisation with nothing on the GPU** | An OOM-killed CUDA process leaves state that persistence mode then keeps alive indefinitely. Cleared by restarting `nvidia-persistenced` — *not* `nvidia-smi -r`, which this SoC has no path for ([why](docs/decisions.md#persistence-latch)) |
| **`SW Power Cap` is "Active" ~46% of the time at idle** | It is DVFS, not a fault. Alarming on it fires on every other glance and buries a real thermal slowdown ([measurements](docs/decisions.md#history-timer)) |
| **One cable, two PCIe partitions — not two cables** | Two netdevs on two PCIe roots look like two ports until you check `phys_port_name` ([how to tell](docs/decisions.md#one-cable-two-partitions)) |
| **Jumbo frames buy ~3.3%, and 9000 is the wrong number to care about** | RoCE quantises to powers of two and caps at 4096; above that is inert for RDMA ([measurements](docs/decisions.md#jumbo-mtu)) |
| **RDMA is invisible to netdev counters** | 66 GiB across the cable moved `tx_bytes` by *exactly 0*. A netdev-based panel reads zero on a saturated link ([why](docs/runbooks/monitoring.md#roce-counters)) |
| **NCCL logs `NET/IB` on a RoCE fabric** | That is its name for ibverbs. It is *not* evidence of InfiniBand ([detail](docs/runbooks/connect-cluster.md#no-infiniband)) |
| **Swap is a cliff, not a slope** | On coherent memory, paging does not degrade gracefully. `gx10-top` judges swap on *growth*, not presence ([why](docs/runbooks/capacity-planning.md)) |
| **`--n-cpu-moe` and friends do nothing here** | Every x86 MoE guide recommends them. They keep experts in system RAM when *VRAM* is scarce; both sides of that split are the same 121 GB |
| **Every RoCE IPv4 GID is published twice, and the index everyone pins is the wrong one** | v1 and v2 sit at adjacent indices and only v2 routes; the widely-copied `NCCL_IB_GID_INDEX=3` is a *populated but link-local* entry here, so a "is it empty" preflight passes and the remote rank dies a minute in ([`--gids`](docs/runbooks/two-node-serving.md#gid-index)) |
| **A core dump here is a RAM image, and RAM is 121 GB** | One crashed process wrote a **41 GB** core to the disk holding the weights and the swap file. `ulimit -c` says 0 and is irrelevant — systemd's `DefaultLimitCORE` is `infinity`, and what crashes here is a unit or a container ([detail](docs/runbooks/manage-storage.md#core-dumps)) |
| **`/var/tmp` never expires on Ubuntu** | The 30-day rule ships commented out, and it is where training jobs write checkpoints — measured **303 GB** there, invisible to `du ~/.cache` and to `hf cache scan` ([detail](docs/runbooks/manage-storage.md#var-tmp)) |
| **A broken speculative drafter is invisible** | It costs acceptance and nothing else — the target still verifies every token, so the answers stay correct at half the speed ([`spec-decode-accept`](workspaces/bench/spec-decode-accept/README.md)) |
| **"Engine X cannot do quantisation Y" is usually a claim about a checkpoint** | This repo told people for months that SGLang cannot serve NVFP4 on Blackwell. It cannot serve *one* NVFP4 checkpoint — a quantised `lm_head` — and serves NVIDIA's Nemotron 3.5 Lightning NVFP4 on day 0 ([the correction](docs/decisions.md#nemotron35-lightning)) |
| **NVFP4 on `sm_121` is a claim about size, not about FP4 silicon** | Native FP4 tensor-core execution is GB200; NVIDIA's own hardware table routes DGX Spark through a W4A16 **Marlin** kernel. Still the right default here — it is what fits — but not for the reason usually given |
| **A hybrid model's 1M window can fit one node** | 6 attention layers of 52 pay a growing K/V cost; the mamba state is a flat 716 MiB. ~4.93M pool tokens in ~14.1 GiB, and a *speculative drafter's* separate KV is the biggest allocation in the server ([arithmetic](docs/runbooks/capacity-planning.md)) |
| **Re-running a prompt is not a second measurement** | Prefix caching makes the rerun a cache hit: 10.3 s → 1.9 s for free, which reads exactly like a flag that worked. Salt the prompt and read the hit counter ([`vllm-prefill-ladder`](workspaces/bench/vllm-prefill-ladder/README.md)) |

Measured here: **22.7 GB/s** busbw on a two-node NCCL all-reduce, ~91% of the
200 Gb/s cable. If your number is half that, you have one partition addressed.

## Runbooks

Task-oriented, each answering **what / when / why / how** with runnable commands
and a failure table. Start here.

### Set it up

| I want to… | Runbook |
|---|---|
| Set up a brand-new GX10 | [provision-node](docs/runbooks/provision-node.md) |
| Cable two boxes together and verify 200 Gb/s | [connect-cluster](docs/runbooks/connect-cluster.md) |
| Work out what the fabric is and whether it works | [diagnose-interconnect](docs/runbooks/diagnose-interconnect.md) |
| Tune host network settings for the interconnect | [tune-network](docs/runbooks/tune-network.md) |
| Add a third node, or replace one | [add-a-node](docs/runbooks/add-a-node.md) |
| Put a token somewhere safe, or rotate one | [manage-secrets](docs/runbooks/manage-secrets.md) |

### Run things on it

| I want to… | Runbook |
|---|---|
| Work out whether a model will fit at all | [capacity-planning](docs/runbooks/capacity-planning.md) |
| Run or serve a model | [serve-models](docs/runbooks/serve-models.md) |
| Spin up inference, Ray, RL or agent environments | [workspaces](docs/runbooks/workspaces.md) |
| **Serve one model across both nodes** | [two-node-serving](docs/runbooks/two-node-serving.md) |
| Download or clean up model weights | [manage-models](docs/runbooks/manage-models.md) |
| Work out where the disk went, and get it back | [manage-storage](docs/runbooks/manage-storage.md) |
| Run a training job across both nodes | [run-distributed](docs/runbooks/run-distributed.md) |
| Measure the cluster and prove it performs | [benchmark](docs/runbooks/benchmark.md) |

### Keep it running

| I want to… | Runbook |
|---|---|
| See what the machine is doing | [monitoring](docs/runbooks/monitoring.md) |
| Watch every node live in one screen | [monitoring](docs/runbooks/monitoring.md#cluster-wide) |
| Update packages without breaking CUDA | [upgrade-drivers](docs/runbooks/upgrade-drivers.md) |
| Bring the cluster back after a reboot or power loss | [reboot-recover](docs/runbooks/reboot-recover.md) |
| Get back in after an SSH lockout | [recover-ssh-lockout](docs/runbooks/recover-ssh-lockout.md) |
| Fix something that's broken | [troubleshoot](docs/runbooks/troubleshoot.md) |
| Edit code on the box, and drive tmux from the editor | [edit-code](docs/runbooks/edit-code.md) |

## The tools

Installed by the `monitoring` and `cluster` roles. All are plain scripts —
**no daemon, nothing resident between invocations**, because on unified memory
every resident MB is a MB the model cannot use.

| Command | Answers |
|---|---|
| `gx10-status` | What is this box doing right now? |
| `gx10-top` | What is every node doing, and where do they disagree? |
| `gx10-interconnect` | Is the fabric up, and what is it? (`--peer` proves RDMA end to end, `--gids` names the routable GID index) |
| `gx10-storage` | Where did the 916 GB go, and what is safe to delete? (`--reclaim` plans it, `--top` ranks it, `-c` does both nodes) |
| `gx10-sample -r` | What happened at 03:00? (systemd timer, ~1 MB/day of CSV) |
| `ws` | What can I run, will it fit, and is it running? |
| `gx10-sessionizer` | Which project am I switching to? (`prefix f`, or `<Space>tf` in neovim) |

Plus `vllm-serve`, `allreduce_test.py`, the two bench probes and the workspace
helpers. **[tools.md](docs/tools.md) is the full reference** — every command,
its flags, its exit codes, and how to read what it prints.

## Reference

| | |
|---|---|
| [docs/](docs/README.md) | Index of everything, and the provenance rules |
| [tools.md](docs/tools.md) | Every command this repo adds, indexed by command |
| [decisions.md](docs/decisions.md) | Why the repo is the way it is — one entry per choice |
| [hardware.md](docs/hardware.md) | Verified GX10 facts, and what DGX OS already owns |
| [roles/](roles/README.md) | What each role does, and its tag |
| [workspaces/](workspaces/README.md) | The recipe catalogue, and how to add one |
| [vars/](vars/README.md) | Playbook-scoped data, and the checks `make verify` runs |
| [contributing](docs/contributing.md) | How to change this without it rotting |
| [SECURITY.md](SECURITY.md) | Reporting, deliberate posture, accepted risks |

## Layout

```
site.yml            main playbook (serial: 1, any_errors_fatal)
workstation.yml     the editor alone, on a box that is not a GX10
verify.yml          assertion-based health check
optional.yml        opt-in components, never run by site.yml
benchmark.yml       the benchmark runner
bootstrap.sh        the one thing you run by hand
Makefile            every command you need
inventory.yml       your nodes, interconnect index and rank  (gitignored)
group_vars/all.yml  every tunable
roles/              18 roles, 14 of them in site.yml   -> roles/README.md
workspaces/         18 runnable recipes + the `ws` runner
                                                      -> workspaces/README.md
vars/               playbook-scoped data              -> vars/README.md
tests/              render, handler, tag, detector and docs checks
docs/               runbooks and reference            -> docs/README.md
```

## Running less than everything

```bash
make apply TAGS=ml                      # one role
make apply SKIP=models                  # all but one (models is ~130 GB)
make apply EXTRA='-e allow_apt_upgrade=true'
```

Not `make apply -e …` — make eats `-e` as its own flag and it never reaches
Ansible.

Four roles are opt-in and never run from `site.yml`:

```bash
make optional TAGS=ray|slurm|exporters|dashboards|bench
```

## The editor, on a box that is not a GX10

`site.yml` provisions a GX10 and asserts as much. The editor it installs is not
GX10-specific, though, and `workstation.yml` puts *only* that on a machine in
the `workstation` inventory group — sharing every pinned version, the same
`lazy-lock.json`, and the same health checks:

```bash
make workstation-diff LIMIT=devbox   # dry run
make workstation LIMIT=devbox        # apply, then prove the editor works
```

Architecture is not part of the difference: every release binary is downloaded
through the `arch_*` spellings in `group_vars/all.yml` and checksummed per
architecture, so an x86_64 workstation and an aarch64 node run the same play.

What *is* the difference is that a workstation is somebody's daily driver, so
the play does not re-pin what the box already has — its node, its rustc, its
`ruff`, or the permissions on its `~/.config`. Every one of those decisions,
and its cost, is written down in `group_vars/workstation.yml`; read that file
before pointing this at a machine.

A bare `optional.yml` run is a no-op. There is no `enable_*` variable per role —
tags do that — though a few within-role toggles remain (`build_llama_cpp`,
`install_ollama`, `install_nordvpn`, `enable_ufw`) because tags cannot reach
inside a role.

## Requirements

**aarch64 Ubuntu 24.04 (DGX OS 7.x) on GB10.** `site.yml` asserts the
architecture and GPU compute capability before doing anything, because the
PyTorch index and llama.cpp CUDA arch are chosen for `sm_121` and would silently
misbuild elsewhere. It also refuses to run as root — everything lands in the
connecting user's home, which under `sudo` would be `/root`.

The ML venv installs from a committed lockfile
(`roles/ml/files/requirements-ml.txt`), resolved for aarch64 against the cu130
index. `make lock` regenerates it and must run **on a GX10**
([why](docs/contributing.md#adding-or-changing-a-python-package)).

## Status

**Provisioning is applied end-to-end on both nodes**: `make verify` passes, a
full `make diff` reports zero changes, and the interconnect carries 22.7 GB/s.

Honest gaps, each labelled where it appears:

| | |
|---|---|
| The **benchmark suite installs but has never been run** | [so labelled](docs/runbooks/benchmark.md) |
| The history sampler's timer is not started on these nodes | |
| The tier-2 items in [tune-network](docs/runbooks/tune-network.md) are unmeasured hypotheses | |
| **Most workspaces are `unverified`** — written from vendor docs and the sources in each manifest, not from a completed run. The ones that have been run are `verified`; one is `blocked` | `ws list` colours all three — green, yellow, red |

Expect to fix something the first time you run a workspace. When you do: fix the
recipe, flip `provenance: verified`, and say what changed. That is the same rule
the rest of these docs follow.

## Contributing

Issues and PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). The one rule
that matters: `make check` must pass, and if you change behaviour, say in the
commit message how you verified it.

`make check` is not only lint. It asserts that every role, runbook, vars file
and workspace is listed in its index, that every relative link and anchor in
every markdown file resolves, that every workspace has a README, and that the
quality gate's detectors can still fail. **A stale index is worse than no index
— it denies the existence of a runbook, confidently.**

Security issues go through [SECURITY.md](SECURITY.md), not a public issue.

## License

[MIT](LICENSE) © Evangelos Pappas
