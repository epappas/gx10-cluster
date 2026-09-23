# Runbook: add a node

**What** — bring a third (or fourth) machine into the cluster, or replace one.
**When** — you bought another GX10, or a model needs more pooled memory than
two nodes hold.
**Risk** — **moderate, and it lands on the nodes you are not touching.** Several
facts here are derived from inventory and written onto *every* node, so a
`--limit`ed run leaves the existing nodes with a stale view of the cluster.

> **Not verified.** This cluster is two nodes. Everything below follows from
> what the roles actually template — each step names the file it writes, so you
> can check — but no third GX10 has been provisioned. Treat the fabric section
> in particular as reasoning, not as a result.

## Read this first: the cable does not scale

The 200 Gb/s interconnect is a **direct QSFP cable between two boxes**. One
cable, two PCIe partitions, point to point
([how to tell that from two cabled ports](../decisions.md#one-cable-two-partitions)).

**There is no third port to plug a third node into.** So:

| Nodes | Fabric |
|---|---|
| 2 | Direct cable. 200 Gb/s, RoCE v2, measured 22.7 GB/s busbw |
| 3+ | Needs a **200 GbE switch**, or the extra nodes join on management only |

A node on management-only networking is still a real cluster member for
`torchrun`, Ray, Slurm and the monitoring tools — it just does its collectives
over the management NIC at management speed. For **tensor-parallel serving that
is not good enough**, and the failure is quiet: it works, slowly.

So decide which you are doing before you start:

| Goal | Needs the fabric? |
|---|---|
| More pooled memory for TP serving | **Yes** — switch required |
| More CPU, more disk, a build box | No |
| Slurm/Ray capacity for independent jobs | No |
| Data-parallel training | Not strictly, but you will feel it |

## What is derived from inventory, and therefore has to be re-applied everywhere

This is the whole reason a `--limit`ed run is not enough.

| Fact | Written to | By | Derived from |
|---|---|---|---|
| Peer name → management address | `/etc/hosts` | `roles/cluster` | every host's `ansible_host` |
| `<node>.cluster` → interconnect address | `/etc/hosts` | `roles/cluster` | every host's `cluster_index` |
| Peer list for the tools | `/etc/gx10/interconnect.peers` | `roles/cluster` | `groups['gx10']` |
| ufw "trust this peer wholesale" | ufw rules | `roles/remote` | `cluster_peer_mgmt_addrs` |
| Inter-node SSH trust | `authorized_keys` | `roles/cluster` (`trust.yml`) | every node's cluster key |
| Rank 0 / controller | Ray unit, `slurm.conf` | `roles/ray`, `roles/slurm` | `cluster_rank == 0` |
| Mesh VPN local-network allowances | NordVPN | `roles/remote` | the other nodes' nicknames |

**Every one of those is a list over `groups['gx10']`.** Add a host and the
existing nodes do not know about it until they are re-run.

## Steps

### 1. Prepare the machine

Same requirements as the first two: **aarch64 Ubuntu 24.04 (DGX OS 7.x) on
GB10**. `site.yml` asserts the architecture and compute capability `12.1` and
refuses to run anywhere else, because the PyTorch index and the llama.cpp CUDA
arch are chosen for `sm_121`.

Reachable over SSH with your key, on the **wired** address — see
[provision-node](provision-node.md) for the full preflight.

> A non-GB10 machine (a CPU box, a build host) must **not** go in the `gx10`
> group; `site.yml` will refuse it. Give it its own group and its own play.

### 2. Add it to `inventory.yml`

```yaml
all:
  children:
    gx10:
      hosts:
        odysseus:
          ansible_host: 192.168.1.70
          cluster_index: 10
          cluster_rank: 0
        poseidon:
          ansible_host: 192.168.1.71
          cluster_index: 11
          cluster_rank: 1
        telemachus:                    # <- the new one
          ansible_host: 192.168.1.72
          cluster_index: 12
          cluster_rank: 2
```

Three fields, and each has a job:

- **The inventory name IS the hostname.** `roles/base` sets it, and `/etc/hosts`,
  `~/.ssh/config`, the Slurm `NodeName` and the Prometheus label all derive from
  that one string ([why](../decisions.md#the-inventory-name-is-the-hostname)).
- **`ansible_host` is the management address**, and it is load-bearing well
  beyond SSH — it becomes the `/etc/hosts` entry on every peer and the ufw rule
  that lets NCCL's bootstrap through. Use the wired address.
- **`cluster_index` is the host octet on both interconnect subnets** —
  `192.168.100.<index>` and `192.168.101.<index>`. Must be unique.
- **`cluster_rank` names rank 0 and nothing else.** `cluster_controller` is
  derived from `cluster_rank == 0`, never from inventory order, so reordering
  the file cannot silently move the controller. **Do not give the new node
  rank 0** unless you are deliberately moving the controller — see step 7.

#### If the node will never hold a cable

A GB10 you reach only over Meshnet is still a `gx10` member — the group names
the hardware — but it must not carry a `cluster_index`, which is the marker of
interconnect membership: present exactly on the boxes that can hold a DAC, and
every fabric-scoped consumer (`.cluster` names, the peer file `twonode.sh`
picks rank 1 from, the benchmark pair, verify's driver/kernel comparison, and
the ray/slurm/nfs roles) keys off its definedness. Inventory order is
alphabetical, and an indexed-looking newcomer sorting first would otherwise
silently *become* the pair's "peer". The shape, from `gb10-homer`:

```yaml
        gb10-homer:
          ansible_host: 100.75.97.15   # the mesh address: the one peers can reach
          cluster_rank: 2              # deliberately no cluster_index
          mgmt_addr_static: false      # Nord owns that lease
          nordvpn_nickname: gb10-homer # keep the name it registered with
```

Two things to measure before writing `ansible_host`, because the invariant is
"every node can reach every node's management address" and a mesh member
satisfies it asymmetrically: inbound to the node's own LAN/WiFi may be dead
(homer's is — 100% loss), while outbound from it to the pair's addresses may
work fine (homer's does, at 7-14 ms). And verify you are reaching the *right*
machine before believing the route: compare SSH host keys, not just ping
reply. What such a node skips: the interconnect addressing, `<node>.cluster`
in either direction, `/etc/gx10/interconnect.peers` (so two-node launches
there refuse with "no peer found" instead of aiming at a missing
`/dev/infiniband`), Ray, Slurm, and the NFS mount. The full reasoning,
measured numbers included, is
[decisions.md#mesh-only-member](../decisions.md#mesh-only-member).

Everything below assumes the indexed, cableable case; skip step 6 entirely for
a mesh-only member, and mind the `LIMIT=` note in step 7 — a full-play run now
needs every node, mesh member included, powered and meshed
(`serial: 1` + `any_errors_fatal` still stop the play at the first failure).

### 3. Provision the new node

```bash
make apply LIMIT=telemachus
```

`serial: 1` and `any_errors_fatal` still apply. This is the long one — the
`models` role alone is ~130 GB. Skip it and pull later if you want the node
usable sooner:

```bash
make apply LIMIT=telemachus SKIP=models
make models LIMIT=telemachus            # later
```

### 4. Re-apply the inventory-derived roles to **every** node

This is the step that is easy to skip and quietly wrong.

```bash
make apply TAGS=cluster,remote          # NO --limit
```

| That re-writes | So that |
|---|---|
| `/etc/hosts` on all nodes | Every node can resolve the new one, and `<new>.cluster` |
| `/etc/gx10/interconnect.peers` | `gx10-top`, `ws check`, the bench NODES pane and `twonode.sh` see it |
| ufw peer rules | NCCL's **ephemeral** bootstrap ports from the new node are not dropped ([why](../decisions.md#ufw-peers)) |
| Mesh VPN local-network allowances | Peers can reach containers on it |

**The ufw one is the failure worth knowing by heart.** A node added to
`inventory.yml` without re-running `--tags remote` **on the others** produces a
collective that hangs at init on a cable you just seated correctly. There is no
port-scoped rule that can express "NCCL's bootstrap", so the peer is trusted by
address or the job hangs.

### 5. Establish inter-node SSH trust

`site.yml`'s **second play** cross-authorizes every node's cluster key on every
other node. It is deliberately a separate play with no `serial:`, because it can
only run once every host has generated its key.

A `--limit`ed run in step 3 did not do this for the existing nodes. Fix it with:

```bash
make apply TAGS=cluster                 # NO --limit — this includes the trust play
```

Verify from each node:

```bash
for h in odysseus poseidon telemachus; do ssh -o BatchMode=yes $h true && echo "$h ok"; done
```

### 6. Cable it, or accept management-only

**If you have a switch:** cable the new node's ConnectX-7 into it along with the
others, then re-run the cluster role and check:

```bash
make apply TAGS=cluster LIMIT=telemachus
gx10-interconnect                       # on the new node
gx10-interconnect --peer odysseus       # proves RDMA end to end
```

Exit code `0` healthy · `1` degraded · `2` no NIC.

Note the addressing scheme already assumes a shared subnet:
`192.168.100.<index>/24` and `192.168.101.<index>/24`, so a switched fabric
needs no variable changes — only cabling.

**If you do not:** the cluster role reports a missing interconnect and skips the
addressing rather than failing. That is a supported state — `ws check`'s `rdma`
requirement will fail on that node, which is correct and is the point.

### 7. Verify the whole cluster, not just the new node

```bash
make verify                             # NO --limit
```

`verify.yml` compares driver and kernel **across the interconnect nodes** and
torch across **every** node: ranks that disagree on a collective fail in ways
that read like a fabric problem, and the same lockfile on two boxes is what
makes those boxes interchangeable — but a driver point-release difference
between nodes that will never share a collective is a fact to report, not a
failure to abort on. A newly provisioned cabled node picking up a newer driver
than the others is still exactly the drift this catches. The full-play caveat:
every node in the group must be reachable for this and for `make apply` —
including a mesh-only member, asleep behind an account-wide mesh. For a
pair-only run: `make verify LIMIT=odysseus,poseidon` (driver/kernel and torch
among the pair; the cross-node comparison then just names the hosts that took
part).

```bash
gx10-top                                # three columns now, with no configuration
```

### 8. Re-do the optional components

`optional.yml` is never run by `site.yml`, so nothing above installed Ray or
Slurm on the new node.

```bash
make optional TAGS=ray                  # NO --limit
make optional TAGS=slurm                # NO --limit — see below
```

**Do not `--limit` a Slurm worker.** The munge key is generated on
`cluster_controller` and copied from there; a run that excludes it installs
`slurmd` with a key no other node shares, and the failure surfaces as Slurm
being unable to talk to the controller, with nothing in the message naming
munge. The role fails loudly instead of skipping.

For Ray: `roles/ray` asserts that `192.168.100.<index>` is actually configured
on the node, because binding to an address the box does not hold is
`EADDRNOTAVAIL` and `ray start` reports it as an addressing error with nothing
about cabling. **An uncabled node cannot join the standing Ray cluster** — that
refusal is deliberate, and falling back to the management interface is
explicitly not offered, because it would put every object transfer on the slow
path and still report success. A mesh-only member (no `cluster_index`, step 2)
does not even reach the assert — the role ends at its door: "cable it and
re-run" is not advice for a node that never will be cabled. Slurm skips the
same way; see [decisions.md#mesh-only-member](../decisions.md#mesh-only-member).

### 9. Weights, which are not shared

There is no shared filesystem. The new node has an empty HF cache.

```bash
make models LIMIT=telemachus
# or, faster, over the fabric if it is cabled:
rsync -a ~/.cache/huggingface/hub/ telemachus.cluster:.cache/huggingface/hub/
```

## Moving the controller

`cluster_rank: 0` is the only thing that names rank 0. To move it, swap the
ranks in `inventory.yml` and re-run **without** `--limit`:

```bash
make apply TAGS=cluster,remote
make optional TAGS=ray
make optional TAGS=slurm
```

Both orchestrators derive head/controller from `cluster_rank`, so nothing else
needs editing — but both have state on the old controller. Stop them first.

## Removing a node

Reverse of the above, and the order matters:

1. Drain it — `scancel` its jobs, `ws down` anything it is a rank of.
2. Remove it from `inventory.yml`.
3. `make apply TAGS=cluster,remote` on the remaining nodes. This rewrites
   `/etc/hosts` and the peer list, and drops the ufw rule.
4. `make optional TAGS=slurm` if it was a Slurm node.
5. Revoke its key: the `authorized_key` module **never removes what it did not
   add**, so the departed node's cluster key stays in `authorized_keys` until
   you delete it by hand. Do that.

Step 5 is the one people forget. `authorized_keys` being additive is what keeps
the per-node trust from being wiped on every run — the cost is that removal is
manual.

## What scaling actually buys you

| Nodes | Unified memory | What becomes possible |
|---|---|---|
| 1 | ~121 GB | Qwen3.8-27B NVFP4 comfortably; V4-Flash at 2-bit |
| 2 | ~242 GB | 120B NVFP4 with real KV; **V4-Flash at FP8** — the good configuration |
| 3 | ~363 GB | V4-Pro IQ1_S fits in RAM, with nothing left for KV |
| 4 | ~484 GB | V4-Pro IQ1_S/IQ1_M — the first sane V4-Pro configuration |

Pooled memory is the thing that scales. Per-token latency is not: more nodes
means more collectives on the same fabric.

And the caveat that matters for the headline case: **llama.cpp's multi-node path
is RPC over TCP** and does not use RoCE, so adding nodes changes the *memory*
answer for V4-Pro without changing the "this is not how you serve V4-Pro"
answer ([the arithmetic](../decisions.md#deepseek-v4)).

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `site.yml` refuses the new node | Not aarch64, or not compute capability `12.1` | It is not a GB10. Put it in its own group |
| Collectives hang at init after adding a node | **ufw on the *existing* nodes** does not trust the new address | `make apply TAGS=remote` with **no** `--limit` |
| `ssh <newnode>` works, `ssh <newnode>` *from a peer* does not | The trust play never ran for the existing nodes | `make apply TAGS=cluster`, no `--limit` |
| `gx10-top` shows only the old nodes | `/etc/gx10/interconnect.peers` is stale | `make apply TAGS=cluster`, no `--limit` |
| `ray start` fails with an addressing error | Uncabled node, no `192.168.100.<index>` | Cable it, or leave it out of Ray. The refusal is deliberate |
| `srun` hangs with nothing about munge | Slurm installed with `--limit` | Re-run `make optional TAGS=slurm` with no `--limit` |
| `make verify` reports version drift | The new node picked up a newer driver | [upgrade-drivers](upgrade-drivers.md#after-any-driver-or-kernel-change) |
| Two-node serving is slower after adding a third | More collectives, same fabric — or a management-only node in the ranks | Keep TP to cabled nodes |
| A removed node still has cluster access | `authorized_keys` is additive by design | Delete its key by hand on every node |
| The new node has no models | The HF cache is per node | `make models LIMIT=<node>`, or `rsync` over `<node>.cluster` |

## See also

- [provision-node](provision-node.md) — the full first-node procedure
- [connect-cluster](connect-cluster.md) — cabling and verifying the fabric
- [two-node-serving](two-node-serving.md) — what the extra node is for
- [capacity-planning](capacity-planning.md) — whether it will actually help
- [recover-ssh-lockout](recover-ssh-lockout.md) — because step 4 touches ufw
