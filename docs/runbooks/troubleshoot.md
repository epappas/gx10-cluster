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

### The venv does not match its lockfile

`make verify`'s `lockfile applied` check greps the installed torch version as an
exact line in the copy of `requirements-ml.txt` that `roles/ml` leaves inside the
venv. It catches three things at once: a venv left at an older resolution, one
bumped by hand with `uv pip install -U`, and a wheel that came from PyPI rather
than cu130 (the pin carries the `+cu130` local version, so the line will not
match).

```bash
# what moved. uv lives in ~/.local/bin, not in the venv, so point it at one
diff <(~/.local/bin/uv pip freeze --python ~/venvs/ml/bin/python) \
     <(grep -E '^[a-zA-Z0-9]' ~/venvs/ml/requirements-ml.txt)
make apply TAGS=ml                                   # put it back
```

Note the role installs with `pip install -r`, deliberately **not** `pip sync` —
sync would uninstall Ray on the next apply. So extra packages survive; missing
or downgraded ones are restored.

### `uv pip install` fails with `only requests==2.28.1 is available`

You dropped `--index-strategy unsafe-best-match`. The cu130 index shadows PyPI
for torch's transitive dependencies and uv's default `first-index` will not fall
through ([the whole story](../decisions.md#ml-lockfile)). It is on `make lock`
and on the install task; do not remove it from either. Failing loudly here is
the good case — without the flag at **lock** time it resolves silently and
wrongly.

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

### <a name="no-infiniband-visible"></a>The InfiniBand tools show nothing, so the boxes look unconnected

**They are almost certainly connected.** Check with the tool that reports the
fabric actually present, rather than the one that is not:

```bash
gx10-interconnect          # exit 0 healthy, 1 degraded, 2 no NIC
gx10-interconnect --peer   # also proves the RDMA path with a round trip
```

This fabric is **RoCE v2 on an Ethernet link layer**, so `ibhosts`, `ibnodes`,
`iblinkinfo` and `ibnetdiscover` fail with `can't open UMAD port`, `base lid`
and `sm lid` are `0x0`, the devices are named `roce*` rather than `mlx5_*`, and
`opensm` is absent. Every one of those is correct on a healthy cluster — there
is no subnet manager because RoCE does not have one. Do **not** install
`opensm` or try to flip the card into IB mode.

Conversely, NCCL logging `NET/IB` and `Using network IB` is *not* evidence of an
InfiniBand fabric — that is its name for the ibverbs transport, which carries
RoCE too. Seeing it means the fast path is in use, which is the good outcome.

→ [connect-cluster: there is no InfiniBand here](connect-cluster.md#no-infiniband)
· [why](../decisions.md#roce-not-ib)

### No RDMA devices

`ibv_devices` empty, no `mlx5` interface.

**Expected before cabling** — the CX-7 is not on the PCI bus until a cable
links the boxes. If it *is* cabled:

```bash
lspci | grep -i mellanox                          # did hotplug fire?
journalctl -b | grep -i mtk-hotplug               # a udev rule, not a service
dmesg | grep -i mlx5 | tail
```

The hotplug path is a udev rule, not a unit, which is why there is nothing to
`systemctl status`. Verified on this box: the `dgx-spark-mlnx-hotplug` package
ships `/lib/udev/rules.d/90-mtk-hotplug.rules`, matching the `cx7-pcie-hotplug`
platform driver and running
`/opt/nvidia/dgx-spark-mlnx-hotplug/mtk-hotplug-handler.sh`. All three names
turn up in different places; they are the same mechanism.

Reseat the cable; check link LEDs both ends. If the devices appeared and then
vanished ~20 s after boot, see the firmware faults table in
[connect-cluster](connect-cluster.md#known-firmware-faults).

### Bandwidth is wrong

→ [connect-cluster: reading the result](connect-cluster.md#reading-the-result),
which distinguishes half-bandwidth (one subnet), the ~13 Gbps firmware
throttle, and a TCP fallback. They have different fixes and look similar.

### A collective hangs at init and the fabric looks fine

Almost always ufw, not the cable. NCCL's bootstrap uses an ephemeral port on the
management NIC, so there is no port rule that describes it and the peer has to
be trusted by address.
→ [run-distributed](run-distributed.md#hangs-before-the-first-step-in-detail)

## Remote access

### `nordvpn` says `Permission denied` accessing the socket

`/run/nordvpn/nordvpnd.sock` is `root:nordvpn` 0660. The remote role adds you to
the group, but a group added mid-play is not in your current session.

```bash
id -nG | grep nordvpn || make apply TAGS=remote
# then log out and back in, or prefix with sudo
```

### Meshnet is off / the node is only reachable on the LAN

```bash
ip -4 -br addr show nordlynx     # an address here means Meshnet is up
sudo nordvpn account             # "not logged in" is the usual answer
```

→ [recover-ssh-lockout](recover-ssh-lockout.md#f-get-in-over-meshnet), which
also covers the positional-token and token-revoking-`logout` traps.

### A Meshnet peer cannot reach a container here

Meshnet treats `172.17.0.0/16` as a local network and drops peer traffic aimed
at it, so vLLM in a container is invisible to peers by default. Documented
behaviour, not a bug:

```bash
sudo nordvpn meshnet peer local allow all   # what the remote role runs
```

## Ansible

### The play won't start / `callback plugin has been removed`

An `ansible.cfg` referencing a plugin that no longer exists. `--syntax-check`
does **not** catch this:

```bash
make smoke      # exercises the real config path
```

### <a name="optional-installs-nothing"></a>`make optional TAGS=…` reports success and installs nothing

The recap says `ok=1 changed=0` and the role's tasks never appear — just
`included: <role> for <host>`.

Tags on a **dynamic** include select the include, not the tasks inside it. The
role's own tasks carry no tag, so the include matches, runs, and everything it
pulled in is then filtered out. The fix is `apply:`, which pushes the tag down:

```yaml
- name: Ray cluster
  ansible.builtin.include_role:
    name: ray
    apply:
      tags: [ray]        # <- without this the role runs zero tasks
  tags: [ray, never]
```

Do not try to confirm it with `--list-tasks`: that does not expand dynamic
includes, so it prints the include and stops, looking identical either way.
The only proof is a run with a non-zero task count. `make optional-tags`
guards it.

### A task reports `changed` on every run

A wrong `changed_when`, or a missing `creates:`.

```bash
make idempotence   # applies twice; the second run must be changed=0
```

### A template breaks only when it runs

```bash
make render        # renders every template against real facts
```

### `roles/observability has no default entry point`

Working as intended. The role is two tiers and you have to pick one:
`make optional TAGS=exporters` or `TAGS=dashboards`. A no-op `main.yml` would
have read as a successful install
([why](../decisions.md#optional-include-role)).

### A tag installed more than I asked for

Prove what a tag selects before running it:

```bash
ansible-playbook optional.yml --list-tasks --tags exporters
```

If a tag ever pulls in tasks you did not name, the cause is a `roles:` entry
rather than an `include_role` task — role-level tags are additive with task
tags. `optional.yml` is written as tasks for exactly this reason.

### `make docs` fails

A directory index went stale, or a link or `#anchor` does not resolve. Fix the
doc; the check exists because a stale index confidently denies that a role or
runbook exists.

## Disk

### `No space left on device`, and `du ~/.cache` does not explain it

Measured on odysseus at 660 GB used, the HF cache was 175 GB of it. The other
485 GB was in directories nothing weight-aware looks at — 303 GB of checkpoints
in `/var/tmp`, 63 GB of core dumps, 44 GB of docker.

```bash
gx10-storage             # by category, with what is safe to reclaim
gx10-storage --top 20    # biggest directories, wherever they are
```

Full detail: [manage-storage](manage-storage.md).

### Free space did not come back after deleting a large file

A process still holds the descriptor. The space returns when it closes:

```bash
sudo lsof -nP +L1 | head       # NLINK 0 means deleted-but-open
```

### Tens of GB appeared in `/var/lib/apport`

A core dump here is a RAM image, and RAM is 121 GB — one crash wrote 41 GB.
Apport clears them after 3 days on its own. The dumps are a symptom; the cause
is normally the OOM killer. See
[manage-storage](manage-storage.md#core-dumps).

## Serving

### <a name="spec-decode-reports-off"></a>An acceptance probe says "no speculative decoding" on a server that clearly has it

On **SGLang**, `/metrics` does not exist unless the server was started with
`--enable-metrics`, and a probe that finds no counters reports the absence of
the endpoint as the absence of a drafter. Confirm before believing it:

```bash
curl -s localhost:8894/metrics | head -3          # nothing at all -> the flag
curl -s localhost:8894/server_info | head -c 400  # accept length lives here
```

`workspaces/inference/sglang-nemotron35-lightning-nvfp4` passes `--enable-metrics`
for this reason. `/get_server_info` is the deprecated alias if `/server_info`
404s on an older build.

**There is no per-position ladder on SGLang at all**, and that is not a fault
either — the engine publishes no such counter, so
[`spec-decode-accept`](../../workspaces/bench/spec-decode-accept/README.md)
degrades to accept length and says so. Serve the checkpoint under vLLM if you
need the shape that convicts a broken draft mask.

### `--reasoning-parser nemotron_3: invalid choice` (or `nemotron_v3`)

The two engines spell it differently and neither is a typo: **`nemotron_3` in
SGLang, `nemotron_v3` in vLLM**. A flag copied between the two Nemotron
workspaces fails at startup, which is the good outcome.

### A server allocated far less KV cache than the published numbers

Every capacity figure for a hybrid model — pool tokens, KV size,
`max_running_requests` — is derived **at startup** from a fraction of whatever
memory was free at that moment. A desktop session or a resident dashboard is
the usual difference. Read what you actually got rather than what someone else
published:

```bash
workspaces/inference/sglang-nemotron35-lightning-nvfp4/report.sh
gx10-top                                    # what is holding the pool
```

And on a speculative server, check the drafter before the fraction: a draft
model's KV cache is a separate allocation and on Nemotron 3.5 Lightning it is
**~28 GiB** — bigger than the weights. `SPEC_METHOD=none` recovers more than
lowering `mem-fraction-static` by any safe amount
([arithmetic](capacity-planning.md)).

### The model loads as BF16 and then OOMs

On GB10 the NVFP4 execution path is **Marlin** (W4A16) — native FP4 tensor-core
execution is GB200. A MoE backend changed away from `marlin` does not fall back
gracefully; it loads the experts unquantised.

## More detail

```bash
ansible-playbook site.yml -K --check --diff --tags <role>
ansible-playbook site.yml -K --tags <role> -vv
ansible-playbook site.yml --list-tasks --tags <role>
journalctl -u <service> -n50
```
