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
