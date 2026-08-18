# gx10-cluster

**Turn NVIDIA GB10 boxes into a working GPU cluster — fully configurable automation playbooks.**

[![CI](https://github.com/epappas/gx10-cluster/actions/workflows/ci.yml/badge.svg)](https://github.com/epappas/gx10-cluster/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-aarch64%20Ubuntu%2024.04-lightgrey)
![Hardware](https://img.shields.io/badge/hardware-NVIDIA%20GB10%20%C2%B7%20DGX%20Spark-76B900)
![Daemons](https://img.shields.io/badge/monitoring%20daemons-0-success)

Ansible that provisions ASUS Ascent GX10 / NVIDIA DGX Spark nodes, links them
over the ConnectX-7 cable, and ships three zero-cost diagnostic tools. Every
non-obvious choice has a written reason, and every hardware claim says whether
it was measured or merely read on a forum.

## Is this for you?

| You… | Then |
|---|---|
| own one or more **GB10 / DGX Spark** boxes | Run it — this is exactly what it is for |
| own **one** box, not two | Fine. The cluster half skips cleanly when uncabled |
| are debugging GB10 and landed here from a search | **You do not need the playbook.** Jump to [what we learned](#what-we-learned-the-hard-way) — that is the half most people want |
| have different GPU hardware | Read the decisions, skip the playbook. `site.yml` asserts `sm_121` and refuses to run elsewhere |

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

`make` on its own lists every target. First run needs a sudo password; after
that a sudoers drop-in removes the prompt — details and the full preflight
checklist are in [provision-node](docs/runbooks/provision-node.md).

**`inventory.yml` is gitignored** — your hostnames and addresses never enter the
repo. `bootstrap.sh` seeds it from `inventory.example.yml`, which ships two
example nodes to replace: hostnames, `ansible_host` addresses, and
`cluster_index`. Its `192.0.2.x` addresses are RFC 5737 documentation addresses
and route nowhere on purpose, so forgetting to edit fails fast rather than
reaching some other device on your LAN.

**Your username is not in there.** The account to log in as comes from
`gx10_user` in `group_vars/all.yml`, which defaults to whoever you are locally.
Set it only if the account on the boxes differs:

```bash
make apply EXTRA='-e gx10_user=ubuntu'    # once, or set it in group_vars
```

The inventory name **is** the machine's hostname — the play
sets it, and `/etc/hosts`, `~/.ssh/config`, the Slurm `NodeName` and the
Prometheus label all derive from that one string
([renaming](docs/runbooks/provision-node.md#renaming-a-node)).

Two things the play deliberately cannot do for you:

- **Move the cluster admin private key off the node.** Generated at
  `~/.ssh/gx10_admin`; it belongs on your laptop
  ([how](docs/runbooks/provision-node.md#the-cluster-admin-key)).
- **Join the Meshnet.** The client is installed and the firewall is open, but
  logging in needs a token you generate
  ([how](docs/runbooks/provision-node.md#join-the-meshnet)).

## What we learned the hard way

The playbook is the smaller half of this repo. These are GB10 findings that cost
real debugging time, each measured on the hardware:

| Finding | Why it bites |
|---|---|
| **There is no InfiniBand.** The ConnectX-7 runs Ethernet and carries RDMA as RoCE v2 | `ibhosts`, `iblinkinfo` and `ibnetdiscover` all fail with `can't open UMAD port` on a *perfectly healthy* cluster, and "nothing" reads as "not connected" ([why](docs/decisions.md#roce-not-ib)) |
| **`nvidia-smi` cannot report GPU memory** | Host memory *is* GPU memory. `free -h` is your VRAM monitor; imported dashboards show blank tiles ([detail](docs/runbooks/monitoring.md)) |
| **`SW Power Cap` is "Active" ~46% of the time at idle** | It is DVFS, not a fault. Alarming on it fires on every other glance and buries a real thermal slowdown ([measurements](docs/decisions.md#history-timer)) |
| **One cable, two PCIe partitions — not two cables** | Two netdevs on two PCIe roots look like two ports until you check `phys_port_name` ([how to tell](docs/decisions.md#one-cable-two-partitions)) |
| **Jumbo frames buy ~3.3%, and 9000 is the wrong number to care about** | RoCE quantises to powers of two and caps at 4096; above that is inert for RDMA ([measurements](docs/decisions.md#jumbo-mtu)) |
| **RDMA is invisible to netdev counters** | 66 GiB across the cable moved `tx_bytes` by *exactly 0*. A netdev-based panel reads zero on a saturated link ([why](docs/runbooks/monitoring.md#roce-counters)) |
| **NCCL logs `NET/IB` on a RoCE fabric** | That is its name for ibverbs. It is *not* evidence of InfiniBand ([detail](docs/runbooks/connect-cluster.md#no-infiniband)) |

Measured here: **22.7 GB/s** busbw on a two-node NCCL all-reduce, ~91% of the
200 Gb/s cable. If your number is half that, you have one partition addressed.

**Every claim is labelled.** Unlabelled means verified on our hardware with the
command in the doc; community-reported claims ship with a way to measure whether
they applied to you. See [provenance](docs/README.md#provenance) — most GB10
information online is unsourced and some of it is wrong.

## Runbooks

Task-oriented. Start here.

| I want to… | Runbook |
|---|---|
| Set up a brand-new GX10 | [provision-node](docs/runbooks/provision-node.md) |
| Cable two boxes together and verify 200 Gb/s | [connect-cluster](docs/runbooks/connect-cluster.md) |
| Work out what the fabric is and whether it works | [diagnose-interconnect](docs/runbooks/diagnose-interconnect.md) |
| Tune host network settings for the interconnect | [tune-network](docs/runbooks/tune-network.md) |
| Get back in after an SSH lockout | [recover-ssh-lockout](docs/runbooks/recover-ssh-lockout.md) |
| Update packages without breaking CUDA | [upgrade-drivers](docs/runbooks/upgrade-drivers.md) |
| Run or serve a model | [serve-models](docs/runbooks/serve-models.md) |
| Spin up inference, Ray or RL environments | [workspaces](docs/runbooks/workspaces.md) |
| Download or clean up model weights | [manage-models](docs/runbooks/manage-models.md) |
| Run a job across both nodes | [run-distributed](docs/runbooks/run-distributed.md) |
| Measure the cluster and prove it performs | [benchmark](docs/runbooks/benchmark.md) |
| See what the machine is doing | [monitoring](docs/runbooks/monitoring.md) |
| Watch every node live in one screen | [monitoring](docs/runbooks/monitoring.md#cluster-wide) |
| Fix something that's broken | [troubleshoot](docs/runbooks/troubleshoot.md) |

## The tools

Installed by the `monitoring` and `cluster` roles. All three are plain scripts —
**no daemon, nothing resident between invocations**, because on unified memory
every resident MB is a MB the model cannot use.

| Command | Answers |
|---|---|
| `gx10-status` | What is this box doing right now? |
| `gx10-top` | What is every node doing, and where do they disagree? |
| `gx10-interconnect` | Is the fabric up, and what is it? (`--peer` proves RDMA end to end) |
| `gx10-sample -r` | What happened at 03:00? (systemd timer, ~1 MB/day of CSV) |

## Reference

| | |
|---|---|
| [docs/](docs/README.md) | Index of everything, and the provenance rules |
| [decisions.md](docs/decisions.md) | Why the repo is the way it is — one entry per choice |
| [hardware.md](docs/hardware.md) | Verified GX10 facts, and what DGX OS already owns |
| [roles/](roles/README.md) | What each role does, and its tag |
| [contributing](docs/contributing.md) | How to change this without it rotting |
| [SECURITY.md](SECURITY.md) | Reporting, deliberate posture, accepted risks |

## Layout

```
site.yml            main playbook (serial: 1, any_errors_fatal)
verify.yml          assertion-based health check
optional.yml        opt-in components, never run by site.yml
benchmark.yml       the benchmark runner
bootstrap.sh        the one thing you run by hand
Makefile            every command you need
inventory.yml       your nodes, interconnect index and rank
group_vars/all.yml  every tunable
roles/              16 roles, 11 of them in site.yml  -> roles/README.md
vars/               playbook-scoped data              -> vars/README.md
tests/              render, handler, tag and docs checks
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

Five roles are opt-in and never run from `site.yml`:

```bash
make optional TAGS=ray|slurm|exporters|dashboards|node|bench
```

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

Provisioning is applied end-to-end on both nodes: `make verify` passes, a full
`make diff` reports zero changes, and the interconnect carries 22.7 GB/s.

Honest gaps: the **benchmark suite installs but has never been run**
([so labelled](docs/runbooks/benchmark.md)), and the history sampler's timer is
not started on these nodes. The tier-2 items in
[tune-network](docs/runbooks/tune-network.md) are explicitly unmeasured.

## Contributing

Issues and PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). The one rule
that matters: `make check` must pass, and if you change behaviour, say in the
commit message how you verified it.

Security issues go through [SECURITY.md](SECURITY.md), not a public issue.

## License

[MIT](LICENSE) © Evangelos Pappas
