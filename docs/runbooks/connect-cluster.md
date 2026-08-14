# Runbook: connect the two boxes

**What** — bring up the 200 Gb/s RoCE link between two GX10s.
**When** — after both nodes are [provisioned](provision-node.md), once you have a QSFP cable.
**Risk** — low. Nothing here touches the boot path or SSH.

## Why it works the way it does

Three platform facts explain every step below.

1. **The NIC is absent until cabled.** The ConnectX-7 arrives via PCIe hotplug
   (`dgx-spark-mlnx-hotplug`). Before you plug the cable there is no `mlx5`
   device and `ibv_devices` is empty. That is expected, not a fault.
2. **One port = two interfaces.** Each QSFP port presents two PCIe x4
   partitions of ~100 Gb/s each, which must sit on **different subnets**. One
   cable gives full bandwidth; one *subnet* gives you half.
3. **It is RoCE, not InfiniBand.** Devices are named `roce*`, and the data path
   is ibverbs — which is why `NCCL_SOCKET_IFNAME` is not involved
   ([why](../decisions.md#nccl-socket-ifname)).

## How

**1. Cable the boxes** QSFP-to-QSFP.

**2. Confirm the NIC appeared** — on both nodes:

```bash
ibdev2netdev
```

```
roceP2p1s0f1 port 1 ==> enP2p1s0f1np1 (Up)     <- cabled pair
rocep1s0f1   port 1 ==> enp1s0f1np1   (Up)     <- cabled pair
roceP2p1s0f0 port 1 ==> enP2p1s0f0np0 (Down)
rocep1s0f0   port 1 ==> enp1s0f0np0   (Down)
```

Four devices, two `(Up)`. Nothing listed → [no RDMA devices](troubleshoot.md#no-rdma-devices).

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
enp1s0f1np1     UP    192.168.100.10/24     <- want BOTH
enP2p1s0f1np1   UP    192.168.101.10/24
```

One line means half bandwidth.

**5. Check reachability:**

```bash
ping -c3 192.168.100.11 && ping -c3 192.168.101.11
```

**6. Benchmark.** Same command on both boxes, changing only `--node_rank`:

```bash
# node A                                    # node B
torchrun --nnodes 2 --nproc_per_node 1 \    torchrun --nnodes 2 --nproc_per_node 1 \
  --node_rank 0 --master_addr gx10-a \        --node_rank 1 --master_addr gx10-a \
  --master_port 29500 \                       --master_port 29500 \
  ~/cluster/allreduce_test.py                 ~/cluster/allreduce_test.py
```

## Reading the result

```
correctness: ok
size=1.07 GB  iters=10  algbw=10.4 GB/s
busbw=10.4 GB/s
```

| busbw | Meaning | Fix |
|---|---|---|
| ~10 GB/s | Working | — |
| ~5 GB/s | One partition addressed | Step 4 |
| **~1.6 GB/s (13 Gbps)** | **CX-7 firmware power throttle** | [below](#the-13-gbps-trap) |
| < 1 GB/s | Fell back to TCP | [below](#tcp-fallback) |
| Hangs at startup | Bootstrap cannot connect | check `mgmt_iface` reachable both ways |

### The 13 Gbps trap

> **Confidence: community-reported.** Multiple independent reports on NVIDIA's
> developer forums; not in NVIDIA's official docs, and not reproduced on our
> hardware. Treat as a strong lead, not established fact — measure before and
> after rather than assuming it applied to you.

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
make verify   # the three cable-dependent checks should now pass
```

Sources: [NVIDIA forums — 13 Gbps / PCIe power throttling](https://forums.developer.nvidia.com/t/connectx-7-inter-spark-link-capped-at-13-gbps-expected-200-gbps-pcie-power-throttling-27w/363461)
· [CX-7 cards disappear after update](https://forums.developer.nvidia.com/t/connectx-7-network-cards-disappear-after-dgx-spark-system-update-due-to-cx7-pcie-hotplug-driver-issue/374275)
· [PD throttle at 30 W](https://forums.developer.nvidia.com/t/asus-ascent-gx10-dgx-spark-permanent-power-throttle-at-30w-safety-mode-pd-firmware-negotiation-failure/355255)
· [NVIDIA connect-two-sparks](https://github.com/NVIDIA/dgx-spark-playbooks/tree/main/nvidia/connect-two-sparks)
