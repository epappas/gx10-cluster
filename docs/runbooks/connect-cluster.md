# Runbook: connect the two boxes

**What** — bring up the 200 Gb/s RoCE link between two GX10s.
**When** — after both nodes are [provisioned](provision-node.md), once you have a QSFP cable.
**Risk** — low. Nothing here touches the boot path or SSH.

## Why it works the way it does

Three platform facts explain every step below.

1. **The NIC is absent until cabled.** The ConnectX-7 arrives via PCIe hotplug
   (`dgx-spark-mlnx-hotplug`). Before you plug the cable there is no `mlx5`
   device and `ibv_devices` is empty. That is expected, not a fault.
2. **One cabled port = two interfaces.** The cabled QSFP port presents two PCIe
   x4 partitions on separate root complexes (`0000:01:00.0`, `0002:01:00.0`),
   which must sit on **different subnets**. One cable gives full bandwidth; one
   *subnet* gives you half. Easy to misread as two cabled ports — it is not
   ([how to tell](../decisions.md#one-cable-two-partitions)).
3. **The cable is the ceiling, not the bus.** Two Gen5 x4 partitions are
   ~252 Gb/s of PCIe behind a single 200 Gb/s port, so the wire binds first —
   but *one* partition alone is only ~126 Gb/s and cannot carry the port.
4. **It is RoCE, not InfiniBand** — see below, because this is the one that
   costs people an afternoon.

## <a name="no-infiniband"></a>There is no InfiniBand here, and that is correct

The ConnectX-7 runs an **Ethernet link layer** and carries RDMA as **RoCE v2**.
So every InfiniBand-native way of asking "are the boxes connected?" returns
nothing — and nothing is indistinguishable from *not connected*:

| You run | You get | Why |
|---|---|---|
| `ibhosts`, `ibnodes`, `iblinkinfo`, `ibnetdiscover` | `can't open UMAD port` | They send IB SMPs to a subnet manager. RoCE has none |
| `ibstat` / `ibstatus` | `Link layer: Ethernet`, `base lid: 0x0`, `sm lid: 0x0` | LIDs are assigned by a subnet manager; see above |
| `ls /sys/class/infiniband/` | `rocep1s0f0`, … — no `mlx5_*` | This platform names RoCE devices `roce*` |
| `systemctl status opensm` | not found | Deliberate. A subnet manager on an Ethernet link layer manages nothing |

**All four are healthy-cluster behaviour.** Do not install `opensm`, do not try
to flip the card to IB mode, and do not read an empty `ibhosts` as a verdict
([why this got its own tooling](../decisions.md#roce-not-ib)).

Ask the fabric that is actually there instead:

```bash
gx10-interconnect          # passive report; exit 0 healthy, 1 degraded, 2 no NIC
gx10-interconnect --peer   # also proves the RDMA path with a real round trip
```

Measured on this pair — both links carrying real RDMA:

```
Fabric
  RoCE v2 over Ethernet - there is NO InfiniBand subnet here, by design.
  MT4129, firmware 28.45.4028

Links
  rocep1s0f0     enp1s0f0np0      ACTIVE  200 Gb/sec
                                  addr 192.168.100.10/24  mtu 9000 (RoCE 4096)
                                  PCIe 5.0 x4, ~126 Gb/s ceiling
  rocep1s0f1     enp1s0f1np1      DOWN (no cable - expected)
  roceP2p1s0f0   enP2p1s0f0np0    ACTIVE  200 Gb/sec
                                  addr 192.168.101.10/24  mtu 9000 (RoCE 4096)
                                  PCIe 5.0 x4, ~126 Gb/s ceiling
  roceP2p1s0f1   enP2p1s0f1np1    DOWN (no cable - expected)

Peers
  poseidon   192.168.100.11   RDMA ok via enp1s0f0np0 - 1.74 us write latency
  poseidon   192.168.101.11   RDMA ok via enP2p1s0f0np0 - 1.74 us write latency
```

One more trap in the other direction: **NCCL calls this path `NET/IB`** and logs
`Using network IB`. That is NCCL's name for its ibverbs transport, which serves
both IB and RoCE. Seeing `NET/IB` is *not* evidence of an InfiniBand fabric —
it is evidence the fast path is being used, which is what you actually wanted
to know.

Following from (1) and (4): the node names `odysseus` / `poseidon` resolve to the
**management** addresses, not to this cable, and `odysseus.cluster` is the
interconnect. Nothing below breaks before you have cabled, and nothing below
goes slower because you rendezvous on a management name
([the control/data split](../decisions.md#hosts-split)).

## How

**0. Check the management interface first.** NCCL bootstraps over it, and a
dead interface makes every collective hang before it starts. On both nodes:

```bash
ip -br link show "$(ip route show default | awk '/default/{print $5; exit}')"
```

The repo detects this from the default route. If the two nodes reach each other
over something else, set `mgmt_iface_override` in `group_vars/all.yml`.

**1. Cable the boxes** QSFP-to-QSFP. **One cable** into the same cage on each
box is the whole interconnect; the second QSFP port stays empty.

**2. Confirm the NIC appeared** — on both nodes:

```bash
ibdev2netdev
```

Measured on this pair:

```
rocep1s0f0   port 1 ==> enp1s0f0np0   (Up)     <- cabled port, partition 0
rocep1s0f1   port 1 ==> enp1s0f1np1   (Down)   <- empty QSFP port
roceP2p1s0f0 port 1 ==> enP2p1s0f0np0 (Up)     <- cabled port, partition 1
roceP2p1s0f1 port 1 ==> enP2p1s0f1np1 (Down)   <- empty QSFP port
```

Four devices, two `(Up)` — the two partitions of the **one** cabled port. Which
pair comes up depends on which cage you used; NVIDIA's playbook shows the `f1`
pair because theirs was in the other one. Match on `(Up)`, not on the names.
Nothing listed at all → [no RDMA devices](troubleshoot.md#no-rdma-devices).

**3. Address the link:**

```bash
make apply TAGS=cluster
```

Detection filters on carrier, so it configures the cabled pair and ignores the
dead one.

**4. Check addressing** — on both nodes:

```bash
ip -br addr show | grep 192.168.10
```

```
enp1s0f0np0     UP    192.168.100.10/24     <- want BOTH
enP2p1s0f0np0   UP    192.168.101.10/24
```

One line means half bandwidth. Both on the *same* subnet also means half
bandwidth, and looks fine until you measure — `gx10-interconnect` fails on that
case explicitly.

**5. Check reachability** — ICMP first, then the RDMA path, which is the one
that matters and can fail independently:

```bash
ping -c3 192.168.100.11 && ping -c3 192.168.101.11
gx10-interconnect --peer
```

RoCE v2 rides **UDP 4791**. A firewall that passes ICMP and drops that gives
you a link which pings perfectly and a collective that hangs forever. `ufw`
here allows the interconnect subnets wholesale, which covers it.

**6. Benchmark.** Same command on both boxes, changing only `--node_rank`.
torch lives in the shared venv, so use its `torchrun` (or run `ml` first):

```bash
# on node A
~/venvs/ml/bin/torchrun --nnodes 2 --nproc_per_node 1 --node_rank 0 \
  --master_addr odysseus --master_port 29500 ~/cluster/allreduce_test.py

# on node B -- identical except --node_rank 1
~/venvs/ml/bin/torchrun --nnodes 2 --nproc_per_node 1 --node_rank 1 \
  --master_addr odysseus --master_port 29500 ~/cluster/allreduce_test.py
```

## Reading the result

**Measured on this pair**, both partitions addressed and jumbo frames on:

```
correctness: ok
size=1.07 GB  iters=10  algbw=22.7 GB/s
busbw=22.7 GB/s
```

At two ranks `busbw == algbw`, since the ring moves 2(N-1)/N = 1× the buffer.

**~22.7 GB/s is the healthy number here.** That is ~181 Gb/s on the wire, or
**~91% of the 200 Gb/s cable** — close to line rate once protocol overhead is
paid, with one GPU per node. The two x4 partitions behind it total ~252 Gb/s of
PCIe, so the cable is what you are actually filling.

That figure assumes jumbo frames. At the default MTU 1500 the RoCE path MTU
negotiates 1024 and you get ~22.0 GB/s instead — a real 3.3% but not a cliff.
`cluster_mtu: 9000` in `group_vars/all.yml`
([measurements](../decisions.md#jumbo-mtu)).

> Earlier revisions of this file called ~10 GB/s "the healthy number", carried
> over from NVIDIA's playbook and never measured here. That is about what **one**
> partition delivers, so the old table would have scored a half-configured
> cluster as perfect and this one as suspiciously fast.

| busbw | Meaning | Fix |
|---|---|---|
| ~22.7 GB/s | Working, both partitions, jumbo frames | — |
| ~22.0 GB/s | Working, but MTU 1500 (`active_mtu` 1024) | [jumbo](../decisions.md#jumbo-mtu) |
| ~11 GB/s | One partition only — the second subnet is missing | Step 4 |
| **~1.6 GB/s (13 Gbps)** | **CX-7 firmware power throttle** | [below](#the-13-gbps-trap) |
| < 1 GB/s | Fell back to TCP | [below](#tcp-fallback) |
| Hangs at startup | Bootstrap cannot connect — usually ufw, not the cable | [run-distributed](run-distributed.md#hangs-before-the-first-step-in-detail) |

To confirm which transport was actually used rather than inferring it from the
number — measured here, both ports in the rotation:

```
NET/IB: [0] rocep1s0f0:uverbs0:1/RoCE provider=Mlx5 speed=200000
NET/IB: [2] roceP2p1s0f0:uverbs2:1/RoCE provider=Mlx5 speed=200000
NET/IB : Using [0]rocep1s0f0:1/RoCE [1]roceP2p1s0f0:1/RoCE [RO]; OOB enP7s7:192.168.1.70<0>
Using network IB
Channel 00/0 : 0[0] -> 1[0] [send] via NET/IB/0
Channel 01/0 : 0[0] -> 1[0] [send] via NET/IB/1
```

Sixteen channels alternating `NET/IB/0` and `NET/IB/1` is both partitions in use.
`OOB enP7s7` is the bootstrap on the management NIC, which is correct and
[deliberate](../decisions.md#nccl-socket-ifname).

`GPU Direct RDMA Disabled for HCA 0/1` also appears, alongside
`cuMemGdrSupport 0`. Expected on GB10: GPU memory *is* host memory, so there is
no separate BAR to register for peer DMA. It is not a misconfiguration and
`nvidia-peermem` will not change it.

### The 13 Gbps trap

> **Confidence: community-reported, and NOT present on this pair.** Multiple
> independent reports on NVIDIA's developer forums; not in NVIDIA's official
> docs. We measure 22.7 GB/s on firmware 28.45.4028, so whatever the reports
> describe, this hardware is not subject to it — leave the driver holds alone.
> Kept for the case where a replacement card behaves differently. Measure
> before and after rather than assuming it applied to you.

Frequently reported symptom: the link *negotiates* at 200 Gb/s and then
delivers ~13 Gbps over both TCP and RDMA. Reported cause is ConnectX-7 firmware
throttling on a low (27 W) power report — i.e. not a misconfiguration, so no
amount of NCCL tuning fixes it. Reported fix is a firmware update via a full
package upgrade, then a reboot.

This repo holds the driver stack and gates upgrades ([why](upgrade-drivers.md)),
so do it deliberately and check what moves first:

```bash
apt-get full-upgrade -s | grep -iE "mlnx|mlx|connectx|firmware"   # preview
apt-mark showhold                  # holds cover nvidia-modprobe, not CX-7 firmware
sudo apt full-upgrade
sudo reboot
```

Re-run step 6 and compare the number. If it did not change, the throttle was
not your problem — say so here rather than leaving the claim unqualified.

Also reported: ASUS system firmware v0103+ improves link speed and thermals.

### TCP fallback

```bash
NCCL_DEBUG=INFO torchrun ... 2>&1 | grep -E "NET/|via"
```

`NET/IB` is the RoCE path; `NET/Socket` means it fell back to TCP.

**Do not "fix" this by pointing `NCCL_SOCKET_IFNAME` at the ConnectX-7.** That
selects the bootstrap channel, not the data path
([why](../decisions.md#nccl-socket-ifname)).

## Known firmware faults

> **Confidence: community-reported**, as above. Listed because the symptoms are
> distinctive and hard to diagnose from first principles — not because we have
> confirmed the causes.

| Symptom | Reported cause | Action |
|---|---|---|
| All four CX-7 devices vanish ~20 s after boot | `cx7-pcie-hotplug` bug on CX-7 firmware 28.45.4028 | Update CX-7 firmware; check `dmesg \| grep mlx5` |
| Whole box throttles to 30 W "safety mode" | USB-PD negotiation failure | Cold-drain the power brick (unplug, hold power, replug) |

## Verify

```bash
make verify            # the cable-dependent checks should now pass
gx10-interconnect      # or the whole picture in one command, exit-coded
```

Those are the non-required ones: `RDMA link active`, `RoCE fabric`,
`interconnect addressed` and `both interconnect partitions`. They are reported,
never fatal, because an uncabled node is a legitimately healthy node.

`RDMA link active` checks port **state**, not device presence. The earlier
version asked only whether `ibv_devices` listed anything, which the CX-7 does
whether or not a single port links — so it reported green on a box with no
cable in it at all.

Sources: [NVIDIA forums — 13 Gbps / PCIe power throttling](https://forums.developer.nvidia.com/t/connectx-7-inter-spark-link-capped-at-13-gbps-expected-200-gbps-pcie-power-throttling-27w/363461)
· [CX-7 cards disappear after update](https://forums.developer.nvidia.com/t/connectx-7-network-cards-disappear-after-dgx-spark-system-update-due-to-cx7-pcie-hotplug-driver-issue/374275)
· [PD throttle at 30 W](https://forums.developer.nvidia.com/t/asus-ascent-gx10-dgx-spark-permanent-power-throttle-at-30w-safety-mode-pd-firmware-negotiation-failure/355255)
· [NVIDIA connect-two-sparks](https://github.com/NVIDIA/dgx-spark-playbooks/tree/main/nvidia/connect-two-sparks)
