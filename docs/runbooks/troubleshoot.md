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

## More detail

```bash
ansible-playbook site.yml -K --check --diff --tags <role>
ansible-playbook site.yml -K --tags <role> -vv
ansible-playbook site.yml --list-tasks --tags <role>
journalctl -u <service> -n50
```
