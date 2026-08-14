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

## If you want metrics over time

Two tiers, so you can take the cheap half alone.

```bash
make optional TAGS=exporters      # node_exporter + GPU metrics, ~20 MB RSS
make optional TAGS=dashboards     # the above + prometheus + grafana here
```

**Prefer `exporters` and scrape from elsewhere.** Point a Prometheus on your
laptop or the second node at `<node>:9100` and you get history without paying
for it on the box doing the work. The GPU gauges arrive as `gx10_gpu_*` via
node_exporter's textfile collector.

If you do install `dashboards`, both bind to localhost by design:

```bash
ssh -L 3000:localhost:3000 -L 9090:localhost:9090 gx10-a
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
| Prometheus target for node 2 down | Node 2 not provisioned with `exporters` | `make optional TAGS=exporters LIMIT=gx10-b` |

## Reclaiming what you already spend

`gx10-status` will show the desktop holding roughly 1.2 GB of the pool (Xorg,
gnome-shell, a browser). If this box is used over SSH:

```bash
sudo systemctl set-default multi-user.target && sudo reboot
```

That is more memory than the entire monitoring stack would have cost — worth
doing before optimising anything else.
