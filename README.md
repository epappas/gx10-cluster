# gx10-cluster

Ansible provisioning for ASUS Ascent GX10 (NVIDIA GB10 Grace Blackwell) nodes.
Written so the second box comes up identical to the first without anyone
remembering what they typed the first time.

## The hardware

| | |
|---|---|
| GPU | NVIDIA GB10, compute capability 12.1 (`sm_121`) |
| CPU | 20-core ARM — 10x Cortex-X925 + 10x Cortex-A725, `aarch64` |
| Memory | 128 GB unified (CPU and GPU share it coherently) |
| Storage | 1 TB NVMe |
| Interconnect | 2x ConnectX-7 QSFP, for direct-attaching two nodes |
| OS | DGX OS 7.5 (Ubuntu 24.04), driver 580.173, CUDA 13.0 |

Two consequences of that table drive most decisions in this repo:

**Everything must be `aarch64`.** A surprising amount of ML tooling still
ships x86-only wheels or containers. Where an arm64 build does not exist,
the repo builds from source rather than pretending.

**`sm_121` is new enough that generic CUDA wheels miss it.** PyTorch from
PyPI is built for x86 CUDA 12 and will either refuse to install or install
and then fail at the first kernel launch with `no kernel image is available
for execution on the device`. The `cu130` index is not optional here.

## Quick start

```bash
./bootstrap.sh                              # installs ansible via uv, no sudo
ansible-playbook site.yml -K                # apply (-K prompts for sudo)
ansible-playbook verify.yml                 # health check
```

`-K` is required: the roles use `become` for anything touching the system,
and this box has a sudo password.

## Provisioning the second node

1. Cable the two boxes together via the QSFP ports.
2. Get node 2 on the LAN and note its address.
3. Uncomment the `gx10-b` block in `inventory.yml` and set `ansible_host`.
4. Copy your key over: `ssh-copy-id <your-user>@<ip>`
5. From node 1: `ansible-playbook site.yml --limit gx10-b -K`
6. Re-run the cluster role on both so each node learns the other's keys and
   interconnect address: `ansible-playbook site.yml --tags cluster -K`

## Layout

```
site.yml            main playbook
verify.yml          read-only health check
bootstrap.sh        the one thing you run by hand
inventory.yml       both nodes; cluster IPs and ranks
group_vars/all.yml  every tunable — versions, toggles, network
roles/
  base              apt upgrades, build toolchain, CLI tools, sysctl, limits
  docker            group membership, NVIDIA runtime, daemon defaults
  shell             zsh + starship, shared env fragment, tmux
  dev_python        uv, standalone tools (ruff, ipython, pre-commit)
  dev_rust          rustup + CLI tools
  dev_node          nvm + Node 22 + global packages
  ml                NCCL, cuDNN, PyTorch cu130, ollama, llama.cpp
  remote            sshd hardening, ufw, tailscale
  cluster           RDMA, interconnect addressing, inter-node SSH, NCCL
```

Run a single role with tags: `ansible-playbook site.yml --tags ml -K`.
Skip a role permanently by flipping its `enable_*` toggle in
`group_vars/all.yml`, or for one run with `-e enable_ml=false`.

## Decisions worth knowing about

**Docker group membership is the fix that matters on a fresh box.** DGX OS
installs Docker and the NVIDIA Container Toolkit but leaves your user out of
the `docker` group, so every call needs sudo. The role fixes this; you must
log out and back in (or `newgrp docker`) for it to take effect.

**`daemon.json` is merged, not overwritten.** `nvidia-ctk` owns the
`runtimes` block. Writing the file wholesale would silently remove the NVIDIA
runtime registration and GPU containers would stop working.

**`/dev/shm` is raised to 8 GB for containers.** PyTorch `DataLoader` workers
talk through shared memory and Docker's 64 MB default kills multi-worker
loading immediately — a confusing failure the first time you meet it.

**Password SSH auth is only disabled once a key is actually present.** The
role checks for a non-empty `authorized_keys` first. On a remote second node,
getting this wrong means a trip to the machine with a keyboard.

**`memlock` is unlimited.** RDMA pins pages; the default limit makes the
ConnectX-7 path fail in ways that look like NCCL bugs.

## The interconnect

On GX10 the ConnectX-7 **is not on the PCI bus until a cable links the two
boxes** — it arrives via PCIe hotplug, handled by `dgx-spark-mlnx-hotplug`.
So on an uncabled machine there is no `mlx5` device, nothing in
`ibv_devices`, and nothing to give an address to. This is expected, not a
fault.

The `cluster` role splits accordingly. Package installs, `/etc/hosts`,
inter-node SSH keys and `/etc/nccl.conf` always apply. IP addressing, MTU and
link verification detect the NIC first and skip cleanly when it is absent,
printing a note telling you to cable up and re-run `--tags cluster`.

Addressing is static on `10.10.10.0/24` with no gateway and no DNS: it is a
point-to-point cable, not a route to anywhere. Default routing stays on
WiFi/LAN. MTU is 9000 — at 200 Gb/s, 1500-byte frames leave most of the link
unused.

### Testing it

```bash
ibv_devices                 # should list a device once cabled
cluster-run ~/cluster/allreduce_test.py
```

`cluster-run` starts the peer rank over SSH and runs the local rank in the
foreground, so Ctrl-C tears down both sides. Expect a bus bandwidth in the
tens of GB/s. Single-digit GB/s means the collective fell back to TCP over
the LAN — check `NCCL_SOCKET_IFNAME` and that `ibv_devices` is non-empty.

## After a run

- **Log out and back in.** Needed for the docker group, the zsh login shell
  and the shared environment fragment.
- `sudo tailscale up` if you want to reach the box from outside the LAN.
- `ml` activates the shared ML virtualenv; `gpuw` watches the GPU.

## Modifying this repo

Change `group_vars/all.yml`, not the roles — versions, package lists,
network addressing and feature toggles all live there. Then:

```bash
ansible-lint            # must pass at the production profile
ansible-playbook site.yml --syntax-check
```
