# Runbook: tune the host network settings

**What** — the host-side knobs that affect interconnect performance on a GX10,
ranked by whether they have actually been measured here.
**When** — you have a baseline, a number you want to improve, and time to measure.
**Risk** — medium. Several of these bounce the interconnect, and an asymmetric
MTU drops packets silently. Nothing here touches sshd, the boot path or the
management NIC, so none of it can lock you out — ansible reaches both boxes over
management, never over the cable.

## Read this first, or skip the rest

**Most RoCE tuning advice on the internet does not apply to this cluster.** It is
written for RoCE across a *switch*, where the switch can congest and drop, and
where you therefore need PFC, ECN, DCQCN and a lossless queue plan.

You have a **back-to-back DAC cable and no switch**
([topology](../decisions.md#one-cable-two-partitions)). There is nothing in the
middle to congest. Link-level pause is already on and is sufficient. Importing a
switched-fabric tuning guide here is how you spend a weekend and lose bandwidth.

Second: **the RDMA data path bypasses the kernel networking stack.** Ring
buffers, interrupt coalescing, GRO/TSO and `net.core.*` socket buffers shape
*TCP* traffic. NCCL's collectives are ibverbs, and its only TCP is the bootstrap
channel, which by design runs on the management NIC
([why](../decisions.md#nccl-socket-ifname)). So the kernel-stack knobs are
mostly irrelevant to the number you care about — which is exactly why they are
in tier 3 below and not tier 1.

## Measure before and after, four runs each way

A few-percent effect is invisible in one sample. This was learned the hard way:
a single pre-change reading suggested +4.6% where the real, reproducible figure
was +3.3% ([the correction](../decisions.md#jumbo-mtu)).

```bash
# aggregate - the number that matters. Repeat 4x, take the range.
~/venvs/ml/bin/torchrun --nnodes 2 --nproc_per_node 1 --node_rank 0 \
  --master_addr odysseus --master_port 29500 ~/cluster/allreduce_test.py

# per partition - isolates a single x4 path
ib_write_bw -R -p 18515 -D 5 -s 1048576 -q 4            # on the peer
ib_write_bw -d rocep1s0f0 -R -p 18515 -D 5 -s 1048576 -q 4 <peer-ip>

# small-message latency - check you did not trade it away
gx10-interconnect --peer
```

**Accept a change only if the ranges do not overlap.** And keep both numbers:
per-partition and aggregate move for different reasons, and a lever that helps
one can be invisible in the other. Jumbo frames gained 3.3% on the aggregate and
*exactly nothing* per partition, because one x4 partition is PCIe-bound while
the pair is cable-bound.

## Current state on this hardware

Measured, both nodes, so you know what you are starting from:

| Setting | Value | Notes |
|---|---|---|
| netdev MTU | **9000** | tuned; `active_mtu` 4096 |
| CPU governor | **performance** | already optimal |
| `irqbalance` | **inactive** | good — it would fight manual affinity |
| Link pause (802.3x) | **RX on, TX on** | lossless already, without PFC |
| Adaptive coalescing | **on**, rx-usecs 8 / rx-frames 128 | driver default |
| Ring buffers | **1024** RX / 1024 TX (max 8192) | untuned |
| mlx5 queue IRQs | pinned to CPUs **0–4** | these are *efficiency* cores |
| `OMP_NUM_THREADS` | **10** | matches the P-core count |

Core topology, verified from `/proc/cpuinfo` part IDs:

| CPUs | Part | Type |
|---|---|---|
| **5–9, 15–19** | `0xd85` Cortex-X925 | performance |
| 0–4, 10–14 | `0xd87` Cortex-A725 | efficiency |

## Tier 1 — measured, applied, kept

### Jumbo frames on the interconnect

**+3.3% aggregate** (21.95 → 22.68 GB/s busbw, four runs each, non-overlapping
ranges). Latency unchanged at ~1.7 µs. Already set via `cluster_mtu: 9000`.

The operative number is **4096, not 9000**: RoCE's path MTU is quantised to
powers of two at or below the netdev MTU and the card's `max_mtu` is 4096, so
1500 negotiates 1024 and anything above 4096 is inert for RDMA. Full details and
the NetworkManager trap that nearly hid it: [decisions](../decisions.md#jumbo-mtu).

```bash
make apply TAGS=cluster          # already includes it
```

> **Never set MTU by hand on one node.** An asymmetric MTU drops packets silently
> rather than failing loudly. Ansible owns both ends; that is what makes it safe.

## Tier 2 — plausible, NOT measured here

> **Confidence: unverified.** These have a concrete mechanism and are worth an
> afternoon with the harness above. None is applied. Do not assume any of them
> helps — the honest prior, given that the RDMA path bypasses the kernel stack,
> is that most will do nothing for NCCL.

### IRQ affinity onto the performance cores

The clearest anomaly in the table above: the NIC's per-queue interrupts sit on
CPUs 0–4, which are Cortex-A725 efficiency cores.

```bash
grep mlx5 /proc/interrupts | awk '{print $1}' | tr -d ':' \
  | while read n; do echo "irq $n -> $(cat /proc/irq/$n/smp_affinity_list)"; done

# mlnx-tools ships the right way to change it
sudo set_irq_affinity_cpulist.sh 5-9,15-19 enp1s0f0np0
```

**Temper your expectations.** This is the standard advice for TCP throughput, and
it is genuinely wrong-looking as configured. But NCCL polls completion queues
rather than waiting on interrupts for bulk transfer, so the gain on the
collective may be nil. Where it should show up is TCP on these interfaces and
latency jitter. Measure the aggregate anyway — cheap to test, easy to revert.

Not persisted anywhere in this repo on purpose: an affinity change that is not
measured does not earn a place in the IaC.

### Ring buffers

1024 of a possible 8192, both directions.

```bash
sudo ethtool -G enp1s0f0np0 rx 4096 tx 4096
```

Larger rings absorb bursts without drops, at the cost of cache footprint and
latency. On a two-node point-to-point link with pause frames on, there is not
much burst to absorb — the mechanism that would justify this is largely already
handled. Low expected value; listed because it is the other obvious default.

### Interrupt coalescing

Adaptive is on, which is usually the right answer. If you are chasing *latency*
rather than throughput and are willing to spend CPU:

```bash
sudo ethtool -C enp1s0f0np0 adaptive-rx off rx-usecs 0 rx-frames 0
```

Only meaningful for the kernel path. Irrelevant to RDMA verbs.

### `mlnx_tune`

Present on the box. It reports and applies vendor-recommended profiles.

```bash
sudo mlnx_tune -r                       # report only, safe
```

Read its report before applying anything. Its profiles assume server-class
hardware and a switched fabric, so treat suggestions as hypotheses.

## Tier 3 — do not touch, and why

| Knob | Why not |
|---|---|
| **PFC / DCQCN / ECN** (`mlnx_qos`) | These make a *switch* lossless. You have no switch; link pause is already on and sufficient. Enabling PFC on a back-to-back link adds a failure mode and no benefit |
| **`opensm`** | A subnet manager on an Ethernet link layer manages nothing. See [there is no InfiniBand here](connect-cluster.md#no-infiniband) |
| **`net.core.rmem_max` / `wmem_max`** | `nordvpnd` overwrites these at runtime, so the repo stopped claiming them ([why](../decisions.md#nordvpn-sysctl)). They also only shape TCP, which the fast path is not |
| **`NCCL_IB_*`, `NCCL_MIN_NCHANNELS`, QP counts** | NVIDIA's own playbooks set none of them. Speculative RoCE knobs on hardware you cannot easily re-image are guessing, not tuning ([why](../decisions.md#benchmark-tooling)) |
| **`NCCL_SOCKET_IFNAME` → the ConnectX-7** | Selects the *bootstrap* channel, not the data path. Looks like tuning, does nothing, and moves control traffic onto the cable ([why](../decisions.md#nccl-socket-ifname)) |
| **CPU governor** | Already `performance` |
| **`irqbalance`** | Already inactive. Do not enable it — it would undo any manual affinity |
| **Firmware / driver upgrades "for performance"** | The stack is held deliberately. We measure 22.7 GB/s ≈ 91% of the cable; the community 13 Gbps throttle does not apply here ([why](upgrade-drivers.md)) |

## The bigger lever is not the network

At 22.7 GB/s you are at **~91% of the 200 Gb/s cable**. There is at most ~9%
left, and some of that is protocol overhead you cannot remove. Before spending
more time here:

- **Reclaim host memory.** The desktop session holds ~1.2 GB of unified memory —
  more than the entire monitoring stack would cost. See
  [monitoring](monitoring.md#reclaiming-what-you-already-spend).
- **Check you are not swapping.** On coherent memory that is a cliff, not a
  slope; `gx10-status` flags it red.
- **Reduce what crosses the wire at all** — gradient accumulation, sharding
  strategy, precision. A 2× reduction in traffic beats a 3% link gain.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| Throughput unchanged after a tier-2 change | Expected — the RDMA path bypasses the kernel stack | Revert it; do not stack unmeasured changes |
| Collectives hang after an MTU change | Asymmetric MTU between nodes | `make apply TAGS=cluster` on **both**; never by hand |
| MTU "applied" but `ip link` disagrees | NM does not push profile changes onto an active connection | The role's handler reactivates it ([detail](../decisions.md#jumbo-mtu)) |
| Latency got worse, bandwidth flat | Coalescing or ring buffers pushed the wrong way | `ethtool -C ... adaptive-rx on`; `ethtool -G ... rx 1024 tx 1024` |
| Socket buffer sysctls keep reverting | `nordvpnd` owns them | Expected; leave them alone |
| A change vanished after reboot | Set with `ethtool`/`set_irq_affinity`, which do not persist | Prove it helps first, then put it in the role |

## Verify

```bash
gx10-interconnect --peer     # fabric, MTU, per-partition RDMA round trip
make verify                  # RoCE fabric, both partitions, link active
```

Anything you keep must end up in `roles/cluster`, not in a shell history. If it
is worth having, it is worth having on both nodes after the next reboot.
