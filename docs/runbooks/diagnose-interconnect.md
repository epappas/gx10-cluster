# Runbook: diagnose the interconnect from first principles

**What** — establish what the fabric physically *is*, and whether it works,
without trusting device names or assuming a topology.
**When** — the link looks absent, looks slow, or a tool reports nothing and you
cannot tell "broken" from "not applicable".
**Risk** — none through step 5; every command is a read. Steps 6–7 put traffic
on the wire, so run them when the cluster is otherwise idle.

For the *conclusions* about this specific pair, see
[connect-cluster](connect-cluster.md). This runbook is the method that produced
them, written out so you can re-derive it on hardware nobody has documented yet
— or check the conclusions when they smell wrong.

`gx10-interconnect` automates steps 1–6 and exits `0` healthy / `1` degraded /
`2` no NIC. Do it by hand when the tool disagrees with reality, or when you are
on a box that does not have it.

## Why in this order

Each question narrows the fault domain, and **question one decides which tools
are even valid**. Running fabric diagnostics before you know the link layer is
how you spend an afternoon interpreting the output of a command that cannot
succeed here.

## 1. What fabric is this, actually?

```bash
ibstatus            # or: ibv_devinfo
```

| Field | Reading |
|---|---|
| `link_layer: Ethernet` | RoCE. Everything IB-native below is inapplicable |
| `link_layer: InfiniBand` | real IB — expect a subnet manager and non-zero LIDs |
| `base lid: 0x0`, `sm lid: 0x0` | no subnet manager assigned one. Normal on RoCE |
| devices named `roce*`, not `mlx5_*` | same hint from udev |

**On RoCE, these fail no matter how healthy you are:**

```bash
ibhosts; ibnodes; iblinkinfo; ibnetdiscover     # can't open UMAD port
```

They send InfiniBand SMPs to a subnet manager over `/dev/infiniband/umad*`, and
RoCE has no subnet manager to answer. Their failure is not evidence of anything.
Do not install `opensm` to "fix" it — on an Ethernet link layer it manages
nothing. See [there is no InfiniBand here](connect-cluster.md#no-infiniband).

## 2. Which RDMA device is which NIC?

```bash
ibdev2netdev
```

Or from sysfs, which also works when `ibdev2netdev` is absent:

```bash
for d in /sys/class/infiniband/*; do
    echo "$(basename "$d") -> $(ls "$d/device/net")"
done
```

## 3. How many *physical* ports is that?

The step most worth doing deliberately, because device naming and PCI topology
both lie about it. Two netdevs at different PCI addresses can be one port.

```bash
cat /sys/class/net/*/phys_port_name     # same value = same physical cage
cat /sys/class/net/*/phys_switch_id     # same value = same ASIC
```

PCI addressing tells you how the hardware is **presented**; `phys_port_name`
tells you what it physically **is**. A single cage whose lanes are split into
two PCIe functions shows up as two netdevs, on two root complexes, with two
MAC addresses and two link states — indistinguishable from two cards until you
ask this question.

> This is the step that caught a wrong conclusion in this very repo: two live
> netdevs on roots `0000:` and `0002:` were read as two cabled ports. Both
> report `phys_port_name=p0`. One cage, two partitions
> ([the whole story](../decisions.md#one-cable-two-partitions)).

## 4. How many cables?

```bash
sudo ethtool -m <iface> | grep -E 'Identifier|Vendor (name|PN|SN)|Length \(Copper'
```

The **serial number** is the identity. Compare it two ways:

- **Same SN on two local interfaces** → they share one cage (confirms step 3).
- **Same SN on both hosts** → one cable, seen from each end. Two cables of the
  same part number have different serials.

Ignore the fibre length rows on a DAC — `Length (OM1 62.5um): 7m` next to
`Length (Copper or Active cable): 1m` is reused EEPROM bytes, not a second
measurement. `Connector: No separable connector` confirms direct-attach.

## 5. What is the theoretical ceiling?

Write this number down. Step 7 is meaningless without it.

```bash
ethtool <iface> | grep Speed                                    # wire rate
cat /sys/bus/pci/devices/<pci-addr>/current_link_speed          # e.g. 32.0 GT/s
cat /sys/bus/pci/devices/<pci-addr>/current_link_width          # e.g. 4
```

PCIe payload rate = `lanes × GT/s × encoding`, where encoding is **128b/130b**
at 8 GT/s and above, **8b/10b** below. Gen5 x4 is
`4 × 32 × 128/130 ≈ 126 Gb/s`.

**Whichever is smaller — wire or bus — is your budget.** And mind what shares
what: two x4 partitions behind a single 200 Gb/s cage total ~252 Gb/s of bus, so
the *cable* binds; but either partition alone is ~126 Gb/s and cannot carry the
cage on its own.

## 6. Does RDMA work end to end?

IP reachability is **not** sufficient. RoCE v2 rides **UDP 4791**; a firewall
that passes ICMP and drops that gives you a link which pings perfectly and hangs
every collective forever.

```bash
ping -c1 <peer-ip>
ip -br neigh show dev <iface>        # a resolved MAC proves L2, not just L3
```

Then the real test — server on the peer, client locally:

```bash
# on the peer
ib_write_lat -R -p 18515

# locally
ib_write_lat -d <rdma-dev> -R -p 18515 <peer-ip>
```

`-R` uses `rdma_cm`, so you address by IP and skip GID-index selection. Omitting
`-d` on the *server* lets `rdma_cm` choose the device from the address the client
dialled — useful when the two ends name their devices differently.

Expect single-digit microseconds on a direct cable (~1.7 µs here). Swap
`ib_write_lat` for `ib_write_bw` when you care about throughput instead.

Run it **once per partition**, against that partition's peer address. One
working partition tells you nothing about the other.

## 7. Does the application actually use it?

A healthy fabric that the framework declines to use looks identical to a broken
one, from the application's side.

```bash
NCCL_DEBUG=INFO NCCL_DEBUG_SUBSYS=INIT,NET torchrun ... 2>&1 \
  | grep -E 'NET/|Using network'
```

| Line | Meaning |
|---|---|
| `Using network IB`, `NET/IB` | ibverbs — **this covers RoCE too** |
| `NET/Socket` | fell back to TCP. The fabric is not being used |
| `via NET/IB/0`, `via NET/IB/1` | count distinct indices — one per partition in use |
| `OOB <iface>:<ip>` | the bootstrap channel. Belongs on the management NIC |

`NET/IB` is NCCL's name for its ibverbs transport, not a claim about the link
layer. Seeing it on a RoCE box is correct and is what you want.

## The check that catches your own mistakes

**Divide the measured throughput by the ceiling from step 5.**

Measured here: 22.7 GB/s busbw = ~181 Gb/s against a 200 Gb/s cable → **91%**,
which is normal after protocol overhead. Under the mistaken "two cables" model
the same number was 45% — and that should have been read as *the model is
wrong*, not as *the hardware is disappointing*.

A ratio that is suspiciously bad usually means your topology is misunderstood,
not that your hardware is underperforming. Recompute the denominator before
tuning anything.

## Failure modes

| Symptom | Likely cause | Next step |
|---|---|---|
| Every `ib*` fabric tool errors | RoCE, not IB — no subnet manager exists | Step 1; this is normal |
| `ibv_devices` empty | CX-7 arrives by PCIe hotplug only once cabled | [no RDMA devices](troubleshoot.md#no-rdma-devices) |
| Ports ACTIVE, no IPv4 address | Addressing never applied | `make apply TAGS=cluster` |
| Both partitions on one subnet | Both flows exit one interface, half the bandwidth unreachable | [step 4 of connect-cluster](connect-cluster.md#how) |
| Pings fine, `ib_write_lat` fails | UDP 4791 blocked, or perftest missing on the peer | Check `ufw`; step 6 |
| `NET/Socket` in NCCL logs | Fell back to TCP | [TCP fallback](connect-cluster.md#tcp-fallback) |
| Throughput ≈ half expected | One partition only | Steps 3 and 5 |
| Throughput a *strange* fraction | Your ceiling is wrong | Recompute step 5 |

## Verify

```bash
gx10-interconnect --peer     # steps 1-6, exit-coded
gx10-interconnect --gids     # which GID index is the routable RoCEv2 IPv4 one
make verify                  # RDMA link active, RoCE fabric, both partitions
```

`--gids` answers a seventh question this runbook does not otherwise reach:
**which GID index addresses a queue pair between these two boxes.** Nothing
here needs it — NCCL is asked to select the GID itself — but published recipes
pin `NCCL_IB_GID_INDEX`, and a wrong pin kills the *remote* rank about a minute
into a launch with `ibv_modify_qp` errno 61 while the local one looks fine.

Measured here: every IPv4 address is published **twice**, at adjacent indices,
once as RoCE v1 and once as v2 — and the commonly-pinned index 3 is a
*link-local* entry on this hardware, populated but not routable. The one that
works is index **5**. Full table and the argument for not pinning it at all:
[two-node-serving](two-node-serving.md#gid-index).
