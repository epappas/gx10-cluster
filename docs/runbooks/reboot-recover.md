# Runbook: after a reboot or a power loss

**What** — what comes back on its own, what does not, and the order to bring the
rest back.
**When** — after any reboot, a kernel update, or an unclean power loss.
**Risk** — low. The danger here is not knowing something restarted itself: a
container with `restart: unless-stopped` can be holding 100 GB before you have
logged in.

```bash
make verify            # the fastest honest answer, on every node
gx10-top               # what is actually running, right now
docker ps              # what came back by itself
```

## What survives, and what does not

| | Survives a reboot | Why |
|---|---|---|
| Management address | **yes** | `mgmt_addr_static` pins it via a NetworkManager profile, so a DHCP lease cannot move a node's identity out from under `inventory.yml` |
| Interconnect addressing | **yes** | `nmcli` connection profiles (`gx10-cluster-N`), not a boot script |
| `/etc/hosts`, `/etc/nccl.conf`, the peer list | **yes** | Files on disk |
| sshd, ufw, nordvpnd | **yes** | systemd, enabled |
| The history sampler | **yes** | A systemd **timer** — nothing resident between samples |
| `roles/ray`'s standing Ray | **yes** | systemd, enabled and started |
| Slurm (`slurmctld`/`slurmd`/`munge`) | **yes** | systemd, enabled and started |
| `vllm@.service` | **no, unless you enabled it** | The unit is installed as a template; nothing enables an instance for you |
| **Containers with `restart: unless-stopped`** | **yes — this is the surprising one** | See below |
| llama.cpp workspaces | **no** | `nohup`ed background processes. The `.pid` file survives and is now stale |
| The bench TUI / quality gate | **no** | Foreground clients, by design |
| `ray-verl` | **no** | `docker run --rm -it` — interactive by design |

### The one that surprises people

Most containerised workspaces here use `restart: unless-stopped`. That means
**after a reboot they come back on their own**, weights and all — including the
two-node ranks, on both nodes, independently.

```bash
docker ps                                    # here
ssh <peer> docker ps                         # and there
```

That is usually what you want for a server you left running deliberately. It is
**not** what you want if you rebooted to free the memory pool. Stop them
properly rather than killing them:

```bash
ws status                # what ws knows about (compose workspaces)
ws down <name>           # the correct teardown — reaches the peer too
```

`ws status` only reports **compose** workspaces. The two-node ones are plain
`docker run`, so check `docker ps` for `ws-vllm-2node` and `ws-vllm-ds-v4-flash`
as well.

## Steps

### 1. Confirm the node is itself again

```bash
make verify                    # no --limit: it also compares nodes to each other
```

`verify.yml` checks the GPU, the held driver stack, docker, NCCL, the lockfile,
sshd, the mesh VPN, the clock, RDMA and the tools — and it compares **driver,
kernel and torch across nodes**, because ranks that disagree fail in ways that
read like a fabric problem.

Every failure it reports names the runbook that fixes it.

**After a kernel or driver change specifically**, that cross-node comparison is
the check that matters — see
[upgrade-drivers](upgrade-drivers.md#after-any-driver-or-kernel-change).

### 2. Confirm the fabric

```bash
gx10-interconnect                    # exit 0 healthy · 1 degraded · 2 no NIC
gx10-interconnect --peer <peer>      # proves RDMA end to end
```

Expected: `ACTIVE`, `200 Gb/sec`, `mtu 9000 (RoCE 4096)`, and a peer line with a
sub-2 µs write latency.

If `ibhosts` or `iblinkinfo` say nothing, that is **not** a fault: this fabric is
RoCE v2 over Ethernet and there is no InfiniBand subnet manager to answer them
([why](../decisions.md#roce-not-ib)).

### 3. Find out what restarted itself

```bash
docker ps --format '{{.Names}}\t{{.Status}}'
ssh <peer> "docker ps --format '{{.Names}}\t{{.Status}}'"
gx10-top                              # who holds the memory, on every node
```

`gx10-top` marks container-owned GPU processes with `@` — `nvidia-smi` only ever
sees a host pid, so "which container is using the GPU" has no answer without it.

### 4. Clear stale state from the non-surviving workspaces

llama.cpp workspaces leave a `.pid` behind. `down.sh` handles this correctly —
it checks the pid is still `llama-server` before signalling, because pids are
recycled and a stale file pointing at whatever now owns that number is how a
cleanup script kills someone's training run.

```bash
ws down llamacpp-qwen3.8-27b-gguf     # safe even if it is not running
```

Expected on a stale file: `pid N is not llama-server (stale file); not
signalling`.

### 5. Bring back what you actually want

**Order matters** — servers before clients, and one serving workspace at a time.

```bash
ws check <name>          # the pool is empty now; confirm it before claiming it
ws up    <name>
```

For two-node serving, run `ws check` on **both** nodes first: `ws check` can only
measure the node you typed on
([the full procedure](two-node-serving.md)).

### 6. If it was an unclean power loss

Extra checks, in this order:

```bash
sudo dmesg -T | grep -iE 'error|fail|xfs|ext4|nvme|reset' | tail -40
df -h                                  # a download interrupted mid-flight
sudo journalctl -b -1 -p err           # the boot that died
```

An interrupted model download leaves partial blobs in the HF cache. They are
resumable — the `models` role and every engine here re-fetch what is missing —
but if you are short on disk, that is the first place to look:

```bash
du -sh ~/.cache/huggingface/hub/* | sort -h | tail
```

See [manage-models](manage-models.md).

## After a kernel update specifically

The driver stack is **held** (`driver_stack_holds`), and `allow_apt_upgrade` is
`false`, precisely so a blanket upgrade cannot pull `nvidia-modprobe` 610 onto a
580 driver. If a kernel did move:

```bash
make verify                                    # will report the drift
nvidia-smi                                     # "Failed to initialize NVML" is the tell
```

Do **not** improvise. [upgrade-drivers](upgrade-drivers.md#if-you-already-broke-it)
is the recovery path, and it exists because this is the failure mode that
actually takes a node out.

## If the node did not come back at all

In escalation order:

1. **Is it on the LAN?** `ping`, then `ssh`. If SSH refuses or closes instantly,
   go to [recover-ssh-lockout](recover-ssh-lockout.md).
2. **Reachable on the LAN but not from elsewhere?** The mesh VPN needs a login
   token that no playbook can supply — the client is installed and the firewall
   is open, but the join is manual
   ([how](provision-node.md#join-the-meshnet)).
3. **Not on the LAN?** Console access. This is the case the second GX10 exists
   for: a known-good machine to recover from is the whole reason `site.yml` runs
   `serial: 1` with `any_errors_fatal`.

## A reboot is also the cheapest way to reclaim the pool

On unified memory, memory is the resource. If you are about to run the largest
thing this cluster can hold:

```bash
sudo systemctl set-default multi-user.target   # returns ~1.2 GB of Xorg + gnome-shell
sudo reboot
```

That returns more than most tuning will. See
[capacity-planning](capacity-planning.md).

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| Memory is gone right after boot, nothing in your shell | A container with `restart: unless-stopped` came back | `docker ps`; `ws down <name>` |
| A two-node server is half up | One rank's container restarted, the other did not | `ws down` then `ws up` — never restart one rank by hand |
| `ws down` says "not running (no .pid)" but something is | A llama.cpp server started outside `ws` | `pkill -f llama-server`, deliberately |
| `pid N is not llama-server (stale file)` | Correct behaviour after a reboot | Nothing. The guard is doing its job |
| `Failed to initialize NVML` / no `/dev/nvidia*` | Kernel moved out from under the driver | [upgrade-drivers](upgrade-drivers.md#if-you-already-broke-it) |
| `make verify` reports version drift between nodes | One node updated and the other did not | Bring them level before running anything distributed |
| `ibv_devices` is empty | No RDMA devices — link down, or the module did not load | `gx10-interconnect`; [connect-cluster](connect-cluster.md) |
| Interconnect back at ~13 Gbps | CX-7 firmware power throttle | [connect-cluster](connect-cluster.md#the-13-gbps-trap) |
| Ray is up but you did not start it | `roles/ray`'s systemd service is enabled | Expected. `sudo systemctl stop ray` if you want the workspace version |
| Slurm nodes marked down after a reboot | The controller came back after the workers | `sudo scontrol update nodename=<node> state=resume` |
| `docker: permission denied` | Fresh login has not picked up the group — but a **reboot** should have | Check `id`; `make apply TAGS=docker` |
| The clock is wrong after a long power loss | Time sync not yet converged | `make verify` checks this; wait, or `timedatectl` |

## See also

- [troubleshoot](troubleshoot.md) — anything not covered here
- [upgrade-drivers](upgrade-drivers.md) — the change most likely to cause this
- [recover-ssh-lockout](recover-ssh-lockout.md) — if it did not come back
- [monitoring](monitoring.md#cluster-wide) — `gx10-top`, and what happened at 03:00
