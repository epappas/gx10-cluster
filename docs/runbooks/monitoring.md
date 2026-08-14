# Runbook: monitoring

**What** — reach Grafana and Prometheus, and know which numbers mean anything.
**When** — a job is slow, the box is hot, or you want a baseline before tuning.

## The one thing that surprises people

**`nvidia-smi` cannot tell you GPU memory on this hardware.** `memory.total`
and `memory.used` both report `[N/A]`, because CPU and GPU share one coherent
pool. Verify it yourself:

```bash
nvidia-smi --query-gpu=memory.total,memory.used --format=csv,noheader
# [N/A], [N/A]
```

So **`free -h` is your GPU memory monitor**, and node_exporter's host memory
panels are the GPU memory panels. Any dashboard imported from a discrete-GPU
setup will show blank "GPU memory" tiles and tell you nothing. That is the
dashboard being wrong, not the box.

The GPU metrics that *do* exist here — utilisation, temperature, power, SM
clock — are exported by a textfile collector as `gx10_gpu_*`.

## Reach it

Both bind to localhost by design: an unauthenticated metrics store and
dashboard have no business on the LAN.

```bash
ssh -L 3000:localhost:3000 -L 9090:localhost:9090 gx10-a
```

Then Grafana on <http://localhost:3000> (admin/admin on first login, change it)
and Prometheus on <http://localhost:9090>.

To expose them properly instead, put them behind Tailscale rather than
widening `monitoring_bind`.

## What to watch

| Question | Where |
|---|---|
| Is the GPU actually busy? | `gx10_gpu_utilization_percent` |
| Am I near the memory cliff? | `node_memory_MemAvailable_bytes` — **this is GPU memory too** |
| Am I swapping? | `node_memory_SwapFree_bytes` falling = you are already losing |
| Thermal or power throttling? | `gx10_gpu_temperature_celsius`, `gx10_gpu_power_watts` |
| Are the P-cores loaded, or the E-cores? | `node_cpu_seconds_total` by `cpu` — P-cores are `5-9,15-19` |
| Disk filling with weights? | `node_filesystem_avail_bytes` |

Useful queries:

```promql
# swap in use at all - on coherent memory this is the cliff, not a slope
node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes

# per-core utilisation, to see whether work landed on E-cores
100 - rate(node_cpu_seconds_total{mode="idle"}[1m]) * 100
```

## Check it is working

```bash
make verify                                   # includes prometheus/grafana/GPU-metrics checks
systemctl status prometheus grafana-server gx10-gpu-metrics.timer
curl -s localhost:9090/api/v1/targets | jq '.data.activeTargets[].health'
cat /var/lib/prometheus/node-exporter/gx10_gpu.prom
```

The last file should contain `gx10_gpu_*` gauges and be refreshed every 15s.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| GPU panels empty, host panels fine | Dashboard expects `DCGM_FI_*` | Use `gx10_gpu_*`; DCGM support on GB10 is partial |
| "GPU memory" panel blank | It does not exist here | Use host memory — see above |
| `gx10_gpu.prom` missing | Timer not running | `systemctl status gx10-gpu-metrics.timer` |
| `power.limit` absent from metrics | `nvidia-smi` reports `[N/A]` on GB10 | Expected; the collector skips `[N/A]` rather than emitting a fake 0 |
| Prometheus target for node 2 down | Second node not provisioned or firewalled | `make apply --limit gx10-b TAGS=monitoring` |
| Grafana refuses connections | Bound to localhost | Use the SSH tunnel above |

## Second node

`prometheus.yml` is templated from the inventory, so node 2 becomes a scrape
target as soon as it is in `inventory.yml` and provisioned. Re-run
`make apply TAGS=monitoring` on the node running Prometheus after adding it.
