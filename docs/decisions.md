# Decisions

Why things are the way they are. One entry each, newest last. Add an entry
when you make a non-obvious choice — the point is that nobody re-litigates it
six months later, including you.

## Never install a Docker packaging

DGX OS carries Docker's own `docker-ce` / `containerd.io` from
`repo.download.nvidia.com/baseos`. Asking apt for Ubuntu's `docker.io` is
unsatisfiable (`containerd.io Conflicts: containerd`) and fails the task hard,
aborting the play. The docker role verifies and configures; it never installs.

## `apt upgrade` is opt-in and the driver stack is held

A blanket upgrade wants `nvidia-modprobe` 610 against driver 580 — the setuid
helper that creates `/dev/nvidia*`. DGX's pin file does not cover it and
nothing was held. `unattended-upgrades` is blacklisted for the same packages so
it cannot happen unattended mid-run.

## Password auth is disabled only after a key login is *proven*

The guard runs a real `ssh -o PreferredAuthentications=publickey` probe. A
non-empty `authorized_keys` proves nothing: OpenSSH `StrictModes` ignores every
key in a group-writable file, which is a state a machine can ship in. The role
also forces the file to `0600`.

## `ssh_port` is asserted to be 22

Ubuntu 24.04 socket-activates sshd and `ssh.socket` hardcodes
`ListenStream=0.0.0.0:22`. `Port` in `sshd_config` is ignored, so any other
value produces a config that looks applied while sshd still answers on 22 —
and if you then narrow the firewall to the new port you are locked out of a
live listener. Changing it requires an `ssh.socket` drop-in.

## The interconnect uses `nmcli`, not netplan

`netplan apply` runs `nmcli device disconnect` on every NM-managed device and
then stops NetworkManager — it is in netplan's own `apply.py`. On a box whose
only working link is WiFi, and on a second node provisioned over SSH, that
severs the connection the play is running over. NVIDIA's own playbook uses
netplan because it assumes a wired setup; `nmcli` reaches the same end state
without touching anything else.

## <a name="nccl-socket-ifname"></a>`NCCL_SOCKET_IFNAME` points at the management NIC

It selects NCCL's *bootstrap* channel, not the data path — the data path is
RoCE over ibverbs and is chosen independently. NVIDIA's `connect-two-sparks`
and `nccl` playbooks both point it at the management interface. Pointing it at
the ConnectX-7 looks like tuning and costs you the interconnect.

Related: NCCL is configured **only** in `/etc/nccl.conf`, never in the shell
environment. The environment takes precedence over the file, so exporting
`NCCL_*` from `.bashrc` would override the system config for interactive runs
only — giving a locally-launched rank and an SSH-launched rank different
settings.

## No MTU is set on the interconnect

NVIDIA's two-node playbook sets none, and a mismatch between ends drops packets
silently. Jumbo frames stay off until measured. Set `cluster_mtu` to enable.

## No speculative RoCE tuning

`NCCL_IB_HCA`, `NCCL_IB_GID_INDEX`, `NCCL_IB_TC`, `NCCL_NET_GDR_LEVEL` are
deliberately unset. NVIDIA's two-node playbook sets none of them. Speculative
knobs on hardware you cannot easily re-image is guessing, not tuning.

## `daemon.json` is merged, not templated

`nvidia-ctk` owns the `runtimes` and `default-runtime` keys. A plain template
would silently strip GPU container support. The slurp/merge looks like the most
over-engineered code in the repo and is the least.

## `serial: 1` and `any_errors_fatal`

The point of owning a second GX10 is having a known-good machine to recover
from. Applying an untested change to both simultaneously throws that away.

## No `enable_*` toggles

Tags already skip roles (`--tags`, `--skip-tags`). A parallel mechanism with a
variable per role was pure ceremony. Within-role toggles that tags cannot reach
(`build_llama_cpp`, `install_ollama`) are kept.

## Ollama binds to localhost

It has no authentication, and ufw does not filter Docker-published ports, so
`0.0.0.0` is an open model API on every interface. Reach it over an SSH tunnel
or Tailscale.

## `torchaudio` is not installed

The cu130 index stops at torchaudio 2.11.0, whose wheel declares no torch pin,
so it resolves happily next to torch 2.13.0 and then fails at import with an
ABI error. Add it back only pinned against a matching torch.

## Testing is tiered because the hardware cannot be faked

CI runs lint, syntax, a real-config smoke test and template rendering.
Idempotence and `verify` need the actual GB10, driver and NIC, so they are
`make` targets you run on the box. See [contributing](contributing.md).
