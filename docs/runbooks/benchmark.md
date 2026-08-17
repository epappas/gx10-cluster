# Benchmark the cluster

**What:** measures GPU health, fabric bandwidth and latency, storage and NCCL
collectives with the standard upstream tools, and fails if the interconnect is
silently degraded.

**When:** after cabling, after a driver or firmware change, before trusting the
cluster with a long distributed run, and whenever a job is inexplicably slow.

**Why not `make verify`:** verify answers *is this node configured correctly* —
seconds, read-only, safe any time. Bench answers *does it actually perform* —
minutes, and it saturates the GPUs, the fabric and the disk. Do not run it
against a box that is serving.

```bash
make optional TAGS=bench     # once: installs the tooling
make bench                   # every time after that
```

> **Status: reviewed and statically checked, not yet proven by a run.** The
> whole offline suite passes and the tool invocations follow each tool's
> documented usage, but no part of this has executed against the hardware —
> the parsing of `perftest` and `all_reduce_perf` output in particular is
> unverified. Expect to fix something the first time you run it.
>
> The figures below that *are* first-hand, measured on this cluster: PCIe
> Gen5 x4 per ConnectX-7 function and 200 Gb/s per port, both read off the
> hardware on 2026-08-15. A two-node all-reduce on the same day reported
> 22.2 GB/s busbw — but that came from the repo's own `allreduce_test.py`,
> not from `nccl-tests`, so treat it as a sanity reference and not as a
> baseline to compare `make bench` against.

## What it runs, and where the numbers come from

Nothing in this repo computes a performance metric of its own. Every figure is
the unmodified output of the tool the industry already quotes.

| Layer | Tool | Provenance | Metric reported |
|---|---|---|---|
| GPU health | **DCGM** `dcgmi diag` | NVIDIA, official | pass/fail per test |
| GPU state | `nvidia-smi` | NVIDIA, official | throttle reasons, uncorrected ECC |
| RDMA bandwidth | **perftest** `ib_write_bw` | linux-rdma, in Ubuntu | `BW average` Gb/sec, per partition |
| RDMA latency | **perftest** `ib_write_lat` | linux-rdma, in Ubuntu | `t_typical`, `t_99%` usec |
| Collectives | **nccl-tests** `all_reduce_perf` | NVIDIA, official, pinned tag | `algbw` / `busbw` GB/s, `#wrong` |
| TCP (mgmt) | **iperf3** | ESnet | Gbit/s, retransmits |
| Storage | **fio** | axboe, the block standard | MB/s, 4K random IOPS |

`roles/benchmark` installs them. Only `nccl-tests` is built from source, pinned
to a release tag — see `bench_nccl_tests_version`.

### Deliberately not included

- **OSU Micro-Benchmarks** — the standard MPI benchmark, but not packaged for
  Ubuntu, so it is a second source build. `perftest` already measures the same
  fabric one layer lower. Add it when you actually run MPI application codes.
- **HPL / HPCG** — `Rmax` in GFLOP/s is the most quoted HPC number there is,
  and NVIDIA ships both in `nvcr.io/nvidia/hpc-benchmarks`. Not wired up
  because that container's GB10 / sm_121 support is not something this repo has
  verified, and an unverified FLOP number is worse than no FLOP number.

## Thresholds, and why they are loose

Two kinds of entry, and the distinction is the point:

- **Gauges** are measured and reported. Most carry **no floor at all**, because
  no published figure for this hardware has been verified — and a threshold
  with no source is just a number that makes the suite go green.
- **Floors**, where they exist, are set an order of magnitude below what the
  hardware measures. They exist to catch the two failures
  [connect-cluster](connect-cluster.md#reading-the-result) documents — a fall
  back to TCP (< 1 GB/s) and the reported ConnectX-7 firmware power throttle
  (~1.6 GB/s / 13 Gbps) — both of which look like a healthy cluster while
  costing an order of magnitude.

A floor set just under the measured value would fail on ordinary run-to-run
variance, and a check you learn to ignore protects nothing. Track drift by
comparing runs, not by tightening floors.

Every entry in `vars/benchmark_checks.yml` carries a mandatory `provenance`
string. A floor without one is a bug.

### The one number that is not about speed

`all_reduce_perf` prints a `#wrong` column. Anything but `0` means the
collective returned **incorrect data**, and the run fails on it regardless of
bandwidth. Investigate before running any distributed job.

## <a name="recording-a-baseline"></a>Recording a baseline

Each run writes `~/.cache/gx10-bench/results-<timestamp>.json`. That file, not
a tightened floor, is how you detect drift:

```bash
ls -t ~/.cache/gx10-bench/results-*.json | head -2 | xargs diff
```

Record one when the cluster is known good — after cabling, after a clean
`make verify` — and compare against it after any driver, firmware or kernel
change. A 10% move is noise; a 2x move is a fault.

## Reading the fabric numbers

The per-partition RDMA figure is the one people misread. The NIC advertises
**200 Gb/s Ethernet per port**, but each ConnectX-7 function sits behind
**PCIe Gen5 x4** — 4 lanes x 32 GT/s x 128b/130b = **126.03 Gb/s**. PCIe, not
Ethernet, is the per-partition ceiling, which is why
[hardware.md](../hardware.md) says ~100 Gb/s each and why both partitions must
be up to reach the full width.

So: two partitions, each bounded near 100 Gb/s, and a cluster-wide NCCL figure
bounded by their sum. A single partition at full speed with the other dead
looks fine in `nvidia-smi` and costs you half the fabric — which is what the
`roce partitions active` gate and the per-partition assertion exist to catch.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `mpirun cannot launch` | tooling not installed | `make optional TAGS=bench` |
| `dcgmi diag failed` | DCGM absent, or a real GPU fault | run `dcgmi diag -r 1` by hand for per-test detail |
| Fewer than two ACTIVE RoCE links | a partition is down | [connect-cluster](connect-cluster.md) |
| A partition under the floor | cable, or PCIe renegotiated narrow | check the `connectx pcie gen5 x4` gate |
| NCCL busbw under the floor | fell back to TCP, or firmware throttle | [connect-cluster](connect-cluster.md#reading-the-result) |
| `#wrong` non-zero | collective returning bad data | stop; do not run distributed jobs |
| Cross-node tests skipped | you passed `--limit` | run `make bench` with no limit |
| Numbers lower than last month | thermals, or a driver change | compare result files; check the throttle gate |

## Cost

`make bench` writes fio scratch files under `~/.cache/gx10-bench` and removes
them afterwards. Everything else is read-only. Nothing here changes cluster
configuration — but it does load the hardware, so treat a run as taking the
cluster out of service for its duration.
