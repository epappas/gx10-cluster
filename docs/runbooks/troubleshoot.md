# Runbook: troubleshooting

**What** — symptom → cause → fix.
**When** — start here, or with `make verify`, whose every failure names the
runbook that fixes it.

Unlabelled entries were reproduced on our hardware. See
[provenance](../contributing.md#label-provenance).

## PyTorch / CUDA

### `no kernel image is available for execution on the device`

torch came from PyPI instead of the cu130 index, so it has no `sm_121` kernels.
It imports fine and dies at the first kernel launch.

```bash
~/venvs/ml/bin/python -c "import torch; print(torch.__version__)"
# want a +cu130 suffix:  2.13.0+cu130
make apply TAGS=ml
```

### `import torchaudio` fails with an undefined symbol

Deliberately not installed: the cu130 index stops at torchaudio 2.11.0, which
declares no torch pin and so resolves next to torch 2.13.0 into an ABI
mismatch. Add it back only pinned to a matching torch.

### `torch.cuda.is_available()` is False

```bash
nvidia-smi                       # driver alive?
cat /var/run/reboot-required     # pending reboot after a driver change?
```

→ [upgrade-drivers](upgrade-drivers.md#if-you-already-broke-it)

### Everything slows to a crawl and the box feels stuck

The swap cliff. GPU and OS share one 128 GB pool, and `nvidia-smi` reports no
framebuffer — so tools that size themselves from NVML over-allocate against
memory the OS is also using.

```bash
free -h && sysctl vm.swappiness            # want 1
nvidia-smi --query-compute-apps=pid,used_memory --format=csv
```

Lower `OLLAMA_MAX_LOADED_MODELS`, or the model/batch size.
→ [hardware.md](../hardware.md#unified-memory)

## Docker

### `permission denied` on the docker socket

In the docker group but no new login session.

```bash
id -nG | grep docker || make apply TAGS=docker
newgrp docker                    # or log out and back in
```

### `--gpus all` fails

```bash
docker info --format '{{ .DefaultRuntime }}'   # want: nvidia
make apply TAGS=docker
```

If `daemon.json` lost its `runtimes` block, restore the timestamped backup the
role writes beside it.

## Interconnect

### No RDMA devices

`ibv_devices` empty, no `mlx5` interface.

**Expected before cabling** — the CX-7 is not on the PCI bus until a cable
links the boxes. If it *is* cabled:

```bash
lspci | grep -i mellanox                  # did hotplug fire?
journalctl -b | grep -i mtk-hotplug   # it's a udev rule, not a service
dmesg | grep -i mlx5 | tail
```

Reseat the cable; check link LEDs both ends. If the devices appeared and then
vanished ~20 s after boot, see the firmware faults table in
[connect-cluster](connect-cluster.md#known-firmware-faults).

### Bandwidth is wrong

→ [connect-cluster: reading the result](connect-cluster.md#reading-the-result),
which distinguishes half-bandwidth (one subnet), the ~13 Gbps firmware
throttle, and a TCP fallback. They have different fixes and look similar.

## Ansible

### The play won't start / `callback plugin has been removed`

An `ansible.cfg` referencing a plugin that no longer exists. `--syntax-check`
does **not** catch this:

```bash
make smoke      # exercises the real config path
```

### A task reports `changed` on every run

A wrong `changed_when`, or a missing `creates:`.

```bash
make idempotence   # applies twice; the second run must be changed=0
```

### A template breaks only when it runs

```bash
make render        # renders every template against real facts
```

## More detail

```bash
ansible-playbook site.yml -K --check --diff --tags <role>
ansible-playbook site.yml -K --tags <role> -vv
journalctl -u <service> -n50
```
