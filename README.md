# gx10-cluster

Ansible provisioning for ASUS Ascent GX10 (NVIDIA GB10 Grace Blackwell) nodes,
written so the second box comes up identical to the first.

## The hardware

| | |
|---|---|
| GPU | NVIDIA GB10, compute capability 12.1 (`sm_121`) |
| CPU | 20-core ARM — 10x Cortex-X925 + 10x Cortex-A725, `aarch64` |
| Memory | 128 GB **unified** (CPU and GPU share it coherently) |
| Storage | 1 TB NVMe |
| Interconnect | 2x ConnectX-7 QSFP, for direct-attaching two nodes |
| OS | DGX OS 7.5 (Ubuntu 24.04), driver 580.173, CUDA 13.0 |

Four properties of that table drive most decisions here.

**Everything must be `aarch64`.** A lot of ML tooling still ships x86-only
wheels. Where no arm64 build exists, this builds from source rather than
pretending.

**`sm_121` is new enough that generic CUDA wheels miss it.** PyTorch from PyPI
installs and then fails at the first kernel launch with `no kernel image is
available for execution on the device`. The `cu130` index is not optional.

**Memory is unified, so "GPU memory" and "host memory" are one pool.**
`nvidia-smi` reports no framebuffer at all. Tools that size themselves from
NVML over-allocate against a pool the OS also lives in, and the failure mode
is swapping — which on coherent memory is a cliff, not a slope.

**DGX OS already manages a lot.** CPU governor, `vm.max_map_count`, `nofile`,
persistence mode, NVMe scheduler and the driver pin set are all handled. This
repo deliberately does *not* re-tune them; a list of what it leaves alone is
as much a part of the design as what it sets.

## Quick start

```bash
./bootstrap.sh                  # installs ansible via uv, no sudo
ansible-playbook site.yml -K    # apply (-K prompts for sudo)
ansible-playbook verify.yml     # health check
```

Run it under `tmux` — the play touches sshd and networking.

## Provisioning the second node

1. Cable the two boxes together via the QSFP ports.
2. Get node 2 on the LAN, note its address, `ssh-copy-id` to it.
3. Uncomment `gx10-b` in `inventory.yml`, set `ansible_host`.
4. Run the **full** play — not `--limit`:

```bash
ansible-playbook site.yml -K
```

`serial: 1` provisions them one at a time. The full play matters because the
nodes exchange interconnect SSH keys with each other during the run; a
`--limit` run establishes trust in one direction only, and the cluster role
now says so out loud rather than skipping silently.

## Layout

```
site.yml            main playbook (serial: 1, any_errors_fatal)
verify.yml          read-only health check
bootstrap.sh        the one thing you run by hand
inventory.yml       both nodes; interconnect index and rank
group_vars/all.yml  every tunable
roles/
  base              apt safety, build toolchain, CLI tools, sysctl, limits
  docker            group membership, NVIDIA runtime, daemon defaults
  shell             zsh + starship, shared env fragment, tmux
  dev_python        uv and standalone tools
  dev_rust          rustup + CLI tools
  dev_node          nvm + Node 22
  ml                NCCL, cuDNN, PyTorch cu130, ollama, llama.cpp
  remote            sshd, ufw, tailscale
  cluster           RDMA, interconnect addressing, inter-node SSH, NCCL
```

Run one role with `--tags ml`; skip one with `--skip-tags ml`. There are no
`enable_*` variables — tags already do that job.

## Decisions worth knowing about

These are the ones that cost real time to rediscover.

**Never install a Docker packaging on this box.** DGX OS carries Docker's own
`docker-ce` / `containerd.io` from `repo.download.nvidia.com/baseos`. Asking
apt for Ubuntu's `docker.io` is unsatisfiable (`containerd.io Conflicts:
containerd`) and fails the task hard. The docker role verifies and configures;
it never installs.

**`apt upgrade` is opt-in, and the driver stack is held.** A blanket upgrade
here wants to install `nvidia-modprobe` 610 against driver 580 — that is the
setuid helper that creates `/dev/nvidia*`, and DGX's pin file does not cover
it. Set `allow_apt_upgrade=true` deliberately, or better, use DGX's own OTA
path. `unattended-upgrades` is blacklisted for the same packages so it cannot
happen unattended mid-training-run.

**Password SSH auth is disabled only after a key login is *proven*.** The
guard runs an actual `ssh -o PreferredAuthentications=publickey` probe. A
non-empty `authorized_keys` proves nothing: this machine shipped with mode
`0664`, which OpenSSH's `StrictModes` rejects outright, so all five keys in it
were ignored and every login was by password. The role now also forces
`0600` on that file.

**`Port` in `sshd_config` does nothing here.** Ubuntu 24.04 socket-activates
sshd and `ssh.socket` hardcodes `ListenStream=0.0.0.0:22`. Changing
`ssh_port` would produce a config that looks applied while sshd still answers
on 22 — so the role asserts rather than lying to you.

**The interconnect uses `nmcli`, not netplan.** `netplan apply` runs `nmcli
device disconnect` on every NM-managed device and then stops NetworkManager
(it is right there in netplan's `apply.py`). On a box whose only working link
is WiFi — and on node 2, provisioned over SSH — that severs the connection the
play is running over.

**`daemon.json` is merged, not overwritten.** `nvidia-ctk` owns the `runtimes`
block; a plain template would silently remove GPU container support.

**`/dev/shm` is 8 GB for containers.** PyTorch `DataLoader` workers talk
through shared memory and Docker's 64 MB default kills multi-worker loading.

## Performance notes

**The performance cores are `5-9,15-19`.** P-cores (Cortex-X925, 3.90 GHz) and
E-cores (A725, 2.81 GHz) interleave, so `taskset -c 0-9` straddles both. The
shell provides `pcore` for the correct mask, and sets `OMP_NUM_THREADS=10`
so barrier-synchronous work does not wait on E-cores.

**Keep `pin_memory=True`.** The intuitive unified-memory conclusion — no PCIe
transfer, so pinning is a wasted copy — is backwards on GB10. Measured on this
platform, pinned host-to-device copies are several times faster than pageable,
and dramatically so for many small copies. Same reason `--no-mmap` is right
for llama.cpp here.

**`vm.swappiness=1`.** Stock is 60, with 16 GB of swap on the same NVMe as
your checkpoints. Swapping on coherent memory is a cliff; failing fast is the
better outcome.

**What this repo deliberately does *not* set**, because DGX OS owns it or the
setting is wrong here: CPU governor, `vm.max_map_count`, `nofile`, persistence
mode, NVMe scheduler, ECC, power limits and clocks (`nvidia-smi -pl` / `-ac`
are unavailable on GB10 — a playbook that tried would fail), `NCCL_P2P_LEVEL`
(one GPU per node), and NUMA pinning (one NUMA node).

## The interconnect

On GX10 the ConnectX-7 **is not on the PCI bus until a cable links the two
boxes** — it arrives via PCIe hotplug (`dgx-spark-mlnx-hotplug`). On an
uncabled machine there is no `mlx5` device and nothing in `ibv_devices`. That
is expected, not a fault.

**Each QSFP port presents two logical interfaces**, two PCIe x4 partitions of
~100 Gb/s each, which must be on **different subnets**. Configuring only one
silently caps you at half the bandwidth. Addressing follows NVIDIA's
`connect-two-sparks` playbook: `192.168.100.x` and `192.168.101.x`.

Detection filters on carrier, because all four RoCE devices exist but only the
pair belonging to the cabled port comes up.

MTU is left at the default. NVIDIA's own playbook sets none, and a mismatch
between ends drops packets silently — so jumbo frames stay off until measured.
Set `cluster_mtu` if you want them.

**`NCCL_SOCKET_IFNAME` points at the management NIC, not the interconnect.**
It selects NCCL's bootstrap channel; the data path is RoCE over ibverbs and is
chosen separately. Pointing it at the ConnectX-7 looks like tuning and costs
you the interconnect. NCCL is configured only in `/etc/nccl.conf` — never in
the shell environment, which would take precedence and give a locally-launched
rank and an SSH-launched rank different settings.

### Testing it

```bash
ibv_devices     # lists devices once cabled

# same command on both boxes, changing only --node_rank
torchrun --nnodes 2 --nproc_per_node 1 --node_rank 0 \
         --master_addr gx10-a --master_port 29500 ~/cluster/allreduce_test.py
```

Published two-node GB10 figures are around 10 GB/s bus bandwidth. Well below
that means the collective fell back to TCP — re-run with `NCCL_DEBUG=INFO`,
which prints the transport and interface it chose.

## After a run

- **Log out and back in** — docker group, zsh, shell environment.
- `sudo tailscale up` to reach the box from outside the LAN.
- `ml` activates the shared ML venv; `gpuw` watches the GPU; `pcore` pins to
  performance cores.
- Ollama binds to localhost by design. Reach it with
  `ssh -L 11434:localhost:11434 gx10-a`, or set `ollama_host` if you accept an
  unauthenticated model API on every interface.

## Modifying this repo

Change `group_vars/all.yml`, not the roles. Then:

```bash
ansible-lint                       # must pass at the production profile
ansible-playbook site.yml --syntax-check
./bootstrap.sh                     # also proves a real play can run
```

That last point is not pedantry. `--syntax-check` does not load stdout
callbacks, so it passed for a config that aborted every actual run.
