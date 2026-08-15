# GX10 hardware notes

Facts that drive the design. Verified on the machine, not copied from a spec
sheet.

| | |
|---|---|
| GPU | NVIDIA GB10, compute capability 12.1 (`sm_121`) |
| CPU | 20-core ARM: 10x Cortex-X925 + 10x Cortex-A725, `aarch64` |
| Memory | 128 GB **unified**, coherent between CPU and GPU |
| Storage | 1 TB NVMe |
| Interconnect | ConnectX-7, 2x QSFP ports (4 RoCE devices) |
| OS | DGX OS on Ubuntu 24.04.4, driver 580.173.02, CUDA 13.0 (`nvcc` 13.0.88) |

`/etc/dgx-release` reports two versions and they are not the same number:
`DGX_SWBUILD_VERSION="7.2.3"` is the installed build, `DGX_OTA_VERSION="7.5.0"`
the OTA channel. Quote whichever you mean.

```bash
cat /etc/dgx-release
nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader
```

## Everything must be aarch64

A lot of ML tooling still ships x86-only wheels. Where no arm64 build exists,
this repo builds from source rather than pretending.

## sm_121 is newer than most wheels

PyTorch from PyPI installs and then fails at the first kernel launch with
`no kernel image is available for execution on the device`. The `cu130` index
is the only one publishing aarch64 wheels with `sm_121` kernels.

llama.cpp only needs `-DCMAKE_CUDA_ARCHITECTURES=121`; its own CMake rewrites
`12X` → `12Xa`, because Blackwell's FP4 instructions are not forward-compatible.

## Unified memory

"GPU memory" and "host memory" are one pool. `nvidia-smi` reports **no
framebuffer** (`FB Memory Total: N/A`), which has consequences:

- Tools that size themselves from NVML see the whole 128 GB as free GPU
  memory and over-allocate against a pool the OS also lives in. The failure
  mode is swapping, and on coherent memory swapping is a cliff, not a slope.
  Hence `vm.swappiness=1` and a conservative `OLLAMA_MAX_LOADED_MODELS`.
- **Keep `pin_memory=True`.** *(Confidence: community-reported.)* The intuitive
  conclusion — no PCIe transfer, so pinning is a wasted copy — is reportedly
  backwards here: pinned host-to-device copies measure several times faster
  than pageable, dramatically so for many small copies. Same claim underlies
  `--no-mmap` for llama.cpp. **Measure it yourself before designing around it**
  — copy a GB with and without `pin_memory` and compare.
- ECC, power limits and clock control are all `N/A`. `nvidia-smi -pl` / `-ac`
  do not work on GB10; a playbook that tried would fail.

## The CPU cores interleave

| Type | Part ID | CPUs | Max freq |
|---|---|---|---|
| Cortex-X925 (P) | `0xd85` | **5-9, 15-19** | 3.90 GHz |
| Cortex-A725 (E) | `0xd87` | 0-4, 10-14 | 2.81 GHz |

`taskset -c 0-9` — the obvious thing to type — straddles both. Use the `pcore`
alias, which pins to `5-9,15-19`.

`OMP_NUM_THREADS` is set to 10 for the same reason: barrier-synchronous work
runs at the pace of its slowest thread, so spreading across E-cores makes every
barrier wait on them.

## The ConnectX-7 is not there until you cable it

> **Confidence: NVIDIA docs** for the bandwidth and subnet claims below — from
> NVIDIA's `connect-two-sparks` playbook, not measured here, because our NIC is
> not on the bus. Upgrade this note once the boxes are cabled.

The hotplug mechanism itself *is* verified here:

```bash
dpkg -S /lib/udev/rules.d/90-mtk-hotplug.rules
# dgx-spark-mlnx-hotplug: /lib/udev/rules.d/90-mtk-hotplug.rules
```

That rule matches the `cx7-pcie-hotplug` platform driver on `MTKP0001:00` and
runs `/opt/nvidia/dgx-spark-mlnx-hotplug/mtk-hotplug-handler.sh`. It is a **udev
rule, not a systemd unit**, so there is nothing to `systemctl status` — the
three names (`dgx-spark-mlnx-hotplug`, `90-mtk-hotplug.rules`,
`cx7-pcie-hotplug`) all refer to this one path. Before cabling there is no
`mlx5` device and `ibv_devices` is empty.

Each QSFP port presents **two** logical interfaces (two PCIe x4 partitions,
~100 Gb/s each) which must be on **different subnets**. All four RoCE devices
exist; only the pair belonging to the cabled port comes up, which is why
detection filters on carrier.

The link is **RoCE, not InfiniBand** — devices are named `roce*`.

## What DGX OS already manages

Do not re-tune these. Re-setting them is noise at best and a regression at
worst; several were removed from this repo for exactly that reason.

| Thing | Owner | Value |
|---|---|---|
| CPU governor | `nv-cpu-governor` | `performance` on all 20 cores |
| `vm.max_map_count` | `10-map-count.conf` | 1048576 |
| `nofile` | `nv-limits.conf` | 500000 (and it sorts *after* ours, so it wins) |
| GPU persistence mode | `nv-persistence-mode` pkg → `nvidia-persistenced.service` | enabled |
| NVMe scheduler | kernel | `none`, already optimal |
| ARP for multi-NIC | `20-nvidia-defaults.conf` | `arp_ignore=1`, `arp_announce=2` |
| Driver pinning | `cuda-compute-repo-lowpri2` | pins `nvidia-*580`, **not** `nvidia-modprobe` |

That last row is the gap this repo fills — see
[upgrade-drivers](runbooks/upgrade-drivers.md).

Also not applicable here: NUMA pinning (one NUMA node), `NCCL_P2P_LEVEL` (one
GPU per node), GPUDirect RDMA tuning (ATS-coherent memory reaches the NIC
directly).
