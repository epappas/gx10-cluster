# Runbook: observe the machine

**What** — see what the box is doing, without spending memory to find out.
**When** — a job is slow, the box is hot, or you want a baseline.

## Why the default is a script, not a stack

On this hardware host memory **is** GPU memory. A resident monitoring stack is
therefore paid for in model capacity: prometheus is 105 MB on disk plus a TSDB
in RAM, grafana adds a Go server, DCGM another 48 MB. Watching the machine
should not meaningfully shrink what the machine can hold.

So `gx10-status` is the default: a script, zero daemons, zero resident cost.
The full stack still exists — it is just opt-in, and better run elsewhere.

## gx10-status

```bash
gx10-status        # once
gx10-status -w     # watch, 2s
```

It shows the things that actually matter here:

- **GPU** — utilisation, temperature, power, SM clock
- **Throttling** — which reasons are active *now*, and how many minutes of
  software power capping have accumulated since boot. CPU and GPU share a
  power budget, so a compile can quietly steal headroom from a job
- **Unified memory** — total/used/available, labelled as what it is. There is
  no separate VRAM number to look for
- **Swap** — flagged in red if non-zero. On coherent memory that is a cliff,
  not a slope
- **Top memory consumers** — since every one of them competes with the model
- **Disk** — weights and swap share the NVMe

## The one thing that surprises people

`nvidia-smi` **cannot report GPU memory on GB10**:

```bash
nvidia-smi --query-gpu=memory.total,memory.used --format=csv,noheader
# [N/A], [N/A]
```

CPU and GPU share one coherent pool, so there is no framebuffer to report.
`free -h` is your GPU memory monitor. Any dashboard imported from a
discrete-GPU setup shows blank "GPU memory" tiles — that is the dashboard being
wrong, not the box.

## <a name="sw-power-cap"></a>The second thing that surprises people

**`SW Power Cap` is Active about half the time on an idle box.** Measured here
with no compute process running at all — 0% utilisation, ~5.3 W, 208 MHz:

```
Active in 7 of 15 consecutive one-second samples
46% of uptime by its own counter (26149 s of 55870 s)
```

It flaps second to second. That is ordinary DVFS on this SoC, not a fault, and
it is why neither `gx10-status` nor the sampler treats it as a throttle: an
alarm that fires on every other glance, unrelated to anything being wrong, is
one you stop reading — and it would bury a genuine `HW Thermal Slowdown`
printed beside it.

The **rate** is still meaningful even though the state is not. Both tools
report the cumulative counter instead: if the seconds-power-capped climb fast
while a job runs, that job is genuinely power-limited.

The reasons that *are* faults: `HW Thermal Slowdown`, `SW Thermal Slowdown`,
`HW Power Brake Slowdown`, `Sync Boost`.

## <a name="cluster-wide"></a>All nodes at once — `gx10-top`

`gx10-status` answers *this box*. `gx10-top` answers *the cluster*, in one
screen, and it is the only view that can show you the thing neither node's own
dashboard can: **where the two disagree**.

```bash
gx10-top             # all nodes, 2 s refresh
gx10-top -i 5        # slower
gx10-top -1          # one frame and exit (scriptable)
gx10-top -H a,b      # explicit hosts
q  or  Ctrl-C        # quit
```

```
 gx10-top  2 node(s) · 2s · q quits · inet 1.1.1.1  11:04:33
   OK    nodes agree · nothing throttled · no swap growth

                                     odysseus                poseidon
  GPU   util                [#########-]  96%       [----------]   0%
        trend                              ▇▇                      ▁▁
        temp/power                71C  89.26W             51C  10.88W
        clock                        2249 MHz                2405 MHz
        throttle                         none                    none
        pwr-capped                   1146 min                1059 min
        on-GPU       41642M @ar-fleet-9a43381f  431M @latent-cloud-d64
                                415M @gputest  507M @latent-cloud-d16
  ---------------------------------------------------------------------
  CPU   total               [#---------]  11%       [----------]   1%
        P-cores             [##--------]  21%       [----------]   1%
        trend                              .▁                      .▁
        load1/up                  0.61  1d17h             0.41  1d17h
  BUSY  top by cpu       103.0% python   737.7M      1.1% bash     4.2M
                           8.9% VLLM     4.0G      0.7% python3  1.3G
                         0.7% claude   784.3M    0.6% nordvpnd 126.4M
  ---------------------------------------------------------------------
  MEM   used(=GPU)          [####------]  45%       [#---------]  10%
        unified                   55 / 121 GB             13 / 121 GB
        swap                           636 kB                   11 MB
  DISK  used                [###-------]  32%       [###-------]  31%
        free/nvme            599.4G free  45C        600.8G free  45C
  ---------------------------------------------------------------------
  NET   wan enP7s7               v8.8K ^24.3K             v7.0K ^5.7K
        vpn nordlynx              v1.3K ^2.7K             v1.5K ^3.7K
        RoCE p1s0f0                   v0B ^0B                 v0B ^0B
        RoCE mtu                     mtu 9000                mtu 9000
        reach            gw 0.6ms  net 14.5ms    gw 0.8ms  net 14.1ms
  DOCK  containers                2/2 running             2/3 running
```

**Read the top two lines and stop.** The banner is either a green `OK` or a red
`ALERT` naming what is wrong, so the common case needs no reading at all. Below
it, bars give you magnitude at a glance and sparklines give you the last ~12
samples of trend, so you can see a climb without watching for it.

Colour means one thing consistently: **green fine, amber >60%, red >85% or
broken**. GPU utilisation is the deliberate exception — it is cyan and never
red, because a busy GPU is the goal here, not an alarm.

### <a name="who-is-on-the-gpu"></a>Which container is keeping the GPU busy

The `on-GPU` rows answer this, and nothing else on the box does:

```
on-GPU   41642M @ar-fleet-9a43381f     <- @ prefix = container
              415M @gputest
              767M python              <- no @ = host process
```

`nvidia-smi` only ever sees the **host** pid, and reports a containerised
process as a bare `python` with no hint of which container it belongs to. The
attribution comes from reading that pid's cgroup and matching the 12-hex id
against `docker ps`. Verified against a `--gpus all` container: pid 244850 →
`docker-<64hex>.scope` → `gputest`.

Worth knowing: `--query-compute-apps` **does** report per-process GPU memory on
GB10 (measured 767 MiB for a torch process) even though the *device-level*
memory query returns `[N/A]`. There is no framebuffer to total up, but
per-process accounting still works.

`BUSY  top by cpu` is the other half of the same question — the top 5 processes
by CPU with their RSS, per node. Percentages are summed across cores, so >100%
is normal and expected for a threaded job.

Covers the `nvtop` half (GPU util/temp/power/clock/throttle, plus who is on the
GPU), the `glances` half (CPU with a **P-core** split, top processes, memory,
swap, disk, load, uptime), every network role (WAN, VPN, WiFi, Docker bridge,
RoCE), reachability, and Docker.

**Cost:** nothing resident. It forks a collector per node, renders one frame and
sleeps — the same bargain as `gx10-status`. Nodes come from
`/etc/gx10/interconnect.peers`, so it needs no inventory of its own. SSH
connections are multiplexed (`ControlPersist`), because at a 2 s refresh a fresh
handshake per node per frame would cost more than all the collection.

A node that is off or unreachable degrades to one red column; it does not take
the view down, and its numbers are cleared rather than left stale.

### <a name="roce-counters"></a>Why the RoCE rows are not netdev counters

**RDMA bypasses the kernel network stack, so `/sys/class/net/*/statistics/` never
sees it.** Measured: pushing 66 GiB across the cable moved `tx_bytes` by
**exactly 0**.

The only source that sees RDMA is the RDMA port counter, in **4-octet words**:

```bash
# x4, because the unit is words and not bytes
cat /sys/class/infiniband/rocep1s0f0/ports/1/counters/port_xmit_data
```

`port_xmit_data * 4` came to 68291 MiB over 5 s = 13.3 GB/s, matching what
`ib_write_bw` reported to the byte. A netdev-based RoCE panel reads a flat zero
on a link running at full speed — which on this cluster is a familiar shape of
mistake ([the other one](connect-cluster.md#no-infiniband)).

### The divergence line

The bottom line is the point of a cluster view. It flags:

- **clock skew > 2 s** — munge rejects Slurm credentials once clocks drift, with
  errors that never mention time
- **asymmetric RoCE MTU** — drops packets silently instead of failing loudly
- a node **throttling** (genuine reasons only, not SW Power Cap)
- a node **swapping** — on coherent memory that is a cliff
- a node **unreachable**

### Two live views side by side instead

If you would rather have two independent full `gx10-status` panes, tmux does it
with nothing new installed. Note the **full path**: `ssh <host> gx10-status`
runs a non-login shell, which never picks up `~/.local/bin`.

```bash
tmux new-session -s gx10 "gx10-status -w" \; \
  split-window -h "ssh -t poseidon '~/.local/bin/gx10-status -w'" \; \
  select-layout even-horizontal
```

### On nvtop, and why it is half-blind here

`nvtop` is installed and works, but on GB10 it reports:

```
MEM N/A MHz   FAN N/A%   MEM [N/A]   PCIe GEN 1@1x RX: N/A TX: N/A
```

No memory, no fan, no PCIe counters — there is no framebuffer to report, because
host memory *is* GPU memory. The "GPU0 mem%" graph stays flat forever. It is a
fine per-node process viewer; it is not a memory monitor here, and it only ever
shows one host.

`glances` genuinely does multi-node (`glances -s` per node, then
`glances --browser`), at the cost of a resident Python process on every box —
which is the thing this whole role exists to avoid.

## <a name="history-without-a-daemon"></a>History, without a daemon

`gx10-status` answers *what is happening now*. Nothing answered *what happened
at 03:00* — and the two failures that quietly ruin an overnight run, a thermal
cap and a swap excursion, are both invisible by morning. The job is just
mysteriously slow.

A systemd timer fills that gap without a daemon. It forks a script, the script
appends one CSV row and exits, and **between samples nothing is resident**.

```bash
gx10-sample -r        # last 20 samples
gx10-sample -r 200    # last 200
```

Recorded per row: GPU utilisation, temperature, power, SM clock, fault-only
throttle reasons, cumulative power-cap microseconds, available memory (which
here *is* available GPU memory), swap used, NVMe temperature, hottest
ConnectX-7 temperature, and 1-minute load.

Measured cost on a GX10 — one sample: **0.08 s wall, 21 MB peak RSS, all of it
transient**. At the default 10 s that is ~0.3% of one core of 20 and ~1 MB of
CSV per day, rotated weekly, four weeks kept. Everything except the two
`nvidia-smi` calls comes from `/proc` and `/sys` and forks nothing.

Knobs live in `group_vars/all.yml`: `monitoring_history` (off switch),
`monitoring_history_interval`, `monitoring_history_dir`,
`monitoring_history_keep_weeks`.

Plot it anywhere — it is a CSV:

```bash
scp odysseus:/var/log/gx10/metrics.csv .     # then whatever you like
```

### Why not just node_exporter

Because it is a *listener*, and its data only exists while something external
scrapes it. Close your laptop and the history stops.

Note the honest arithmetic though: node_exporter is ~20 MB resident, which is
**0.016% of 121 GB**. The memory objection people raise about it is real about
Prometheus — a TSDB in RAM — and essentially imaginary about the exporter. Pick
the exporter when you want dashboards and have somewhere to run Prometheus;
pick the sampler when you want history that keeps itself.

## If you want metrics over time

Two tiers, so you can take the cheap half alone.

```bash
make optional TAGS=exporters      # node_exporter + GPU metrics, ~20 MB RSS
make optional TAGS=dashboards     # the above + prometheus + grafana here
```

**Prefer `exporters` and scrape from elsewhere.** You get history without
paying for it on the box doing the work. The GPU gauges arrive as `gx10_gpu_*`
via node_exporter's textfile collector.

One wrinkle: node_exporter binds `monitoring_bind` (`127.0.0.1:9100`), the same
posture as every other service here, so a remote Prometheus **cannot** reach it
directly. Pick one:

```bash
# tunnel it (nothing to change on the node)
ssh -L 9100:localhost:9100 odysseus

# or reach it over the mesh VPN / LAN by widening the bind, deliberately
make optional TAGS=exporters EXTRA='-e monitoring_bind=0.0.0.0'
```

Widening it puts an unauthenticated metrics endpoint on every interface the
firewall lets through — `ufw` allows the mesh interface and the peer nodes, so
that is a real exposure decision, not a formality. The tunnel is the default
for a reason.

The `dashboards` tier scrapes the *other* node too, and at the default bind
that peer job will show **down** — its exporter is only answering on its own
loopback. A peer reported down is honest; omitting it would hide half the
cluster.

If you do install `dashboards`, all three bind to localhost by design:

```bash
ssh -L 3000:localhost:3000 -L 9090:localhost:9090 odysseus
```

Grafana on <http://localhost:3000> (admin/admin first login — change it),
Prometheus on <http://localhost:9090>.

### Queries worth knowing

```promql
# available memory - on this box, that IS available GPU memory
node_memory_MemAvailable_bytes

# swap in use at all: the cliff
node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes

# per-core utilisation, to see if work landed on E-cores (P-cores are 5-9,15-19)
100 - rate(node_cpu_seconds_total{mode="idle"}[1m]) * 100
```

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `gx10-status: command not found` | Not provisioned, or no new login | `make apply TAGS=monitoring`; re-login for PATH |
| `gx10-top` shows one node only | No peers file — the cluster role writes it | `make apply TAGS=cluster`, or pass `-H a,b` |
| `gx10-top` RoCE rows all `0B/0B` | Genuinely idle, or you are reading netdev counters by hand | [RDMA is invisible to netdev](#roce-counters) |
| `gx10-top` column reads `DOWN` | That node is unreachable over SSH | Its numbers are cleared, not stale; check the node |
| `gx10-top` will not quit | Fixed — press `q` or Ctrl-C | Earlier builds trapped INT to clean up but never exited |
| `on-GPU` shows `python` with no `@` | It is a host process, not a container | Expected; the `@name` prefix marks containers |
| Bars misaligned in your terminal | Terminal is narrower than the table needs | Widen it, or use `-H` with fewer hosts |
| GPU panels empty, host panels fine | Dashboard expects `DCGM_FI_*` | Use `gx10_gpu_*`; DCGM support on GB10 is partial |
| "GPU memory" panel blank | It does not exist here | Use host memory — see above |
| `power.limit` missing from metrics | `nvidia-smi` reports `[N/A]` on GB10 | Expected; the collector skips `[N/A]` rather than emitting a fake 0 |
| `gx10_gpu.prom` missing | Timer not running | `systemctl status gx10-gpu-metrics.timer` |
| Prometheus target for node 2 down | Node 2 not provisioned with `exporters` | `make optional TAGS=exporters LIMIT=poseidon` |

## Reclaiming what you already spend

`gx10-status` will show the desktop holding roughly 1.2 GB of the pool (Xorg,
gnome-shell, a browser). If this box is used over SSH:

```bash
sudo systemctl set-default multi-user.target && sudo reboot
```

That is more memory than the entire monitoring stack would have cost — worth
doing before optimising anything else.
