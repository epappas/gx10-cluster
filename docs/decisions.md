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

## Password auth is disabled only by an explicit human decision

`ssh_disable_passwords` is an assertion *you* make, having checked from another
terminal that your key works. The role refuses the unsafe combination
(`ssh_disable_passwords: true` with an empty `authorized_keys`) and otherwise
takes you at your word.

An earlier version tried to *prove* it with an `ssh -o
PreferredAuthentications=publickey` probe from the node. That was wrong in both
directions and is gone: it cannot test the key that matters, because the
private half is on your laptop, and it passed for any locally-reachable key —
an agent key, the node's own inter-node key — so passwords could be disabled on
the strength of a credential you do not hold. It also inherited the invoking
shell's `SSH_AUTH_SOCK`, so `make apply` over `ssh -A` and the same command at
the console produced different sshd configs.

There is no way to prove from the node that you can get back into it. The role
does not pretend otherwise.

## `authorized_keys` is forced to 0600 as hygiene, not as a fix

The permissions are tightened because 0600/0700 is what every piece of SSH
documentation assumes. They are **not** tightened because anything here is
currently broken by them — an earlier comment claimed OpenSSH `StrictModes` was
ignoring every key in the 0664 file the machines shipped with, and that is
measurably false on this hardware: both nodes have `authorized_keys` at 0664,
the journal shows `Accepted publickey`, and an explicit
`-o PreferredAuthentications=publickey` login succeeds.

Worth keeping anyway: that tolerance is one `usermod -aG` away from changing,
and the failure mode when it does is silent — every key ignored, nothing
logged, and you are back to passwords without being told.

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
or the [mesh VPN](#meshnet).

## `torchaudio` is not installed

The cu130 index stops at torchaudio 2.11.0, whose wheel declares no torch pin,
so it resolves happily next to torch 2.13.0 and then fails at import with an
ABI error. Add it back only pinned against a matching torch.

## Testing is tiered because the hardware cannot be faked

CI runs lint, syntax, a real-config smoke test and template rendering.
Idempotence and `verify` need the actual GB10, driver and NIC, so they are
`make` targets you run on the box. See [contributing](contributing.md).

## <a name="ssh-both-nodes"></a>Both nodes are addressed over SSH, including the one you are sitting at

An `ansible_connection: local` entry for the local box looks like a free
optimisation and is not. It makes the play runnable only *from* that box, the
same command then behaves differently depending on where you type it, and the
local host silently skips the SSH path every other host exercises — so the path
that breaks is the one you never test. Both entries in `inventory.yml` carry an
`ansible_host`.

One real constraint follows: `-K` prompts once per *run*, not once per host, so
both nodes must accept the same sudo password.

## `site.yml` refuses to run as root

`primary_home` is the connecting user's `HOME`. Under `sudo ansible-playbook`
that is `/root`, so every venv, cache, toolchain, model and SSH key lands in
root's home — and `become: true` becomes a no-op that hides it. The run succeeds
and provisions the wrong account. The assert is in `pre_tasks`, before anything
is installed.

## <a name="optional-include-role"></a>`optional.yml` is tasks with `include_role`, not a `roles:` list

Tags on a `roles:` entry apply to every task inside the role, and task tags are
**additive**, not restrictive. So
`- { role: observability, tags: [exporters, dashboards, never] }` gave every
task in that role all three tags, and `--tags exporters` installed prometheus
and grafana — the exact opposite of what the role's own header promised. A
dynamic `include_role` propagates only the tags on the include itself, so the
split is real and `--list-tasks --tags exporters` proves it.

`roles/observability` is split into `tasks/exporters.yml` and
`tasks/dashboards.yml` for the same reason: the tier boundary is a file, not a
tag, and no task in either file carries a `tags:` line. Its `tasks/main.yml`
fails with a pointer rather than quietly including both — a silent success there
would read as an install.

`dev_node` moved out of `site.yml` at the same time, to `--tags node`. Nothing
in the ML path needs Node.

## <a name="hosts-split"></a>Node names resolve to management, `<node>.cluster` to the interconnect

`/etc/hosts` and the generated `~/.ssh/config` point `poseidon` at the management
address and `poseidon.cluster` at `192.168.100.11`. It used to be the reverse,
which was wrong twice over:

- The ConnectX-7 is not on the PCI bus until a cable links the boxes, so on an
  uncabled pair the interconnect addresses exist nowhere. `ssh poseidon`,
  torchrun's rendezvous and every health check failed — during exactly the
  period you are setting the cluster up.
- It bought nothing. The rendezvous address does **not** decide the collective
  transport. NCCL picks that independently: RoCE over ibverbs for the data path,
  `NCCL_SOCKET_IFNAME` (the management NIC) for
  [bootstrap](#nccl-socket-ifname). Control traffic rode the interconnect and
  the fast path was unaffected either way.

Control plane on the always-up link, data plane on the cable. Ask for
`<node>.cluster` when you explicitly want the 200G path.

## <a name="ufw-peers"></a>ufw trusts the peer nodes wholesale on the management path

NCCL's bootstrap listener on rank 0 binds an **ephemeral** port on the
management NIC, so no port-scoped rule can describe it. With only
`allow 22/tcp` plus a default deny, the peer's bootstrap connection is silently
dropped and every collective hangs at init. That is indistinguishable from a
broken fabric and gets debugged as one, for hours, on a cable you just seated
correctly. torchrun's rendezvous and Ray's ports sit in the same position.

Scoped to the peers' own addresses — `cluster_peer_mgmt_addrs`, derived from
inventory — not to the LAN.

## `ufw_ssh_sources` is the LAN and nothing else

`10.0.0.0/8` and `172.16.0.0/12` were breadth without meaning: no traffic from
those ranges can reach a box on `192.168.4.0/22`. Worse, 172.16/12 covers
docker0's `172.17.0.0/16`, which handed every container on the host a route to
the host's own sshd. The mesh VPN is allowed by **interface** instead, which
survives its address range changing; the peers are allowed by address, above.

## <a name="meshnet"></a>NordVPN Meshnet is the out-of-LAN path, not Tailscale

Meshnet is peer-to-peer WireGuard (libtelio) between your own devices. This box
never runs `nordvpn connect` — it is not a VPN client wanting an exit node, it
is a compute node you need to reach. Installed from NordVPN's signed apt repo
rather than their install script, for the same reason as `gh`.

Three behaviours the CLI does not warn you about, each of which fails in a way
that does not point at itself:

- `nordvpn login --token <TOKEN>` takes the token **positionally**. `--token` is
  a boolean flag, so `--token=<TOKEN>` fails with `invalid boolean value`.
- Plain `nordvpn logout` **revokes** the token. Pass `--persist-token` to keep
  it usable.
- Meshnet treats `172.17.0.0/16` as a local network and drops peer traffic aimed
  at it, so a peer cannot reach anything running in a container here — vLLM
  included — without `nordvpn meshnet peer local allow`.

The client's own packet filter is turned off. ufw is the authority on this box
and two uncoordinated netfilter writers is already one too many with Docker in
the picture. That does *not* remove NordVPN's fwmark rules from the mangle
table; those are policy routing and have no CLI switch, so nordvpn stays a
partial third writer regardless.

`nordvpnd-killswitch.service` is disabled. A kill switch for a tunnel this box
never establishes protects nothing, while running a netfilter-manipulating unit
`Before=network-pre.target` on a host whose entire inference story is Docker
containers is real downside. **Confidence: community-reported** that it sets a
DROP policy on FORWARD — the rules are built programmatically and cannot be read
out of the binary. Disabled on the grounds that it has no upside here, not on a
confirmed diagnosis.

## <a name="ml-lockfile"></a>The ML stack is a committed lockfile, and `--index-strategy` is load-bearing

A package list in `group_vars` (`ml_packages`, now gone) did not deliver this
repo's whole claim: provision node A today and node B in three months and you
get different transformers, different numpy, different everything.
`roles/ml/files/requirements-ml.in` holds the top-level wants and
`requirements-ml.txt` the fully pinned resolution the role actually installs.
`make lock` regenerates it and **must run on aarch64** — uv resolves for the
platform it runs on, so a laptop produces a lockfile pinning x86_64 wheels and
an `nvidia-*` stack this box cannot use.

`--index-strategy unsafe-best-match` is not tuning. uv's default is
`first-index`: for a given package name, only the first index that has it is
consulted at all. `download.pytorch.org/whl/cu130` is not a torch-only index —
it carries frozen copies of torch's runtime dependencies and, being the priority
index, shadows PyPI for every one of them. Resolved with the default, the same
`.in` produces `certifi==2022.12.7`, `requests==2.28.1` and `datasets==1.1.1`:
a four-year-old CA bundle and a `datasets` that cannot work with transformers
5.x, with nothing warning you. Version floors do not fix it — `first-index`
refuses to fall through to PyPI at all. uv reads the flag only from the command
line, so it is on `make lock` *and* on the install in `roles/ml`.

"unsafe" warns about dependency confusion: a public index shadowing a private
one. There is no private index here — both are pypi.org and download.pytorch.org
— and the resolution is reviewed once and then frozen, so nothing floats.

`jupyterlab` was dropped along the way: headless box, reached over SSH, nobody
runs a notebook server on it. Restoring it is one line in the `.in` plus
`make lock`.

## Ollama comes from a pinned release tarball, not `curl | sh`

The install script is unpinned, so two boxes built a month apart run different
servers. Worse, its back half installs CUDA **drivers** from apt —
`cuda-drivers`, dkms, `modprobe nvidia` — which on DGX OS is the one thing that
must never happen. It short-circuits when `nvidia-smi` answers, so it looks
harmless right up until the run where it does not.

`roles/ml/tasks/ollama.yml` does the useful third of that script declaratively:
a version-pinned `.tar.zst` asset, checksummed against the release's own
`sha256sum.txt` rather than a digest pasted into this repo, our own systemd
unit, and a version-stamped file that makes "is this release already unpacked" a
`stat` with nothing to parse.

## Rust is pinned to a toolchain, and three CLIs are not built from source

`rustup update stable` on every apply mutates the toolchain on a schedule set by
upstream releases — two boxes provisioned six weeks apart compile with different
rustc, and neither matches what the other had yesterday. `rust_toolchain` names
the version.

`cargo install --locked eza tokei hyperfine` went at the same time. It compiled
three Rust CLIs from source on aarch64 — minutes of every provision, and a build
toolchain in the dependency path of a fresh box — to get a prettier `ls`. `bat`,
`fd-find` and `zoxide` come from apt instead. Starship went for the same class of
reason: an unpinned root-level `curl | sh` from a third-party domain, in exchange
for a prompt theme.

## The model disk guard subtracts the whole plan

`model_catalog` entries are `{ id: "org/repo", size_gb: N }` dicts because the
size is data, not a comment. The guard asserts
`free - sum(size_gb) >= model_min_free_gb`. A static floor checked once in front
of a 134 GB download is not a guard, it is a formality: it passes at 130 GB free
and the box still runs out somewhere around the third model.

## Metrics listeners bind `monitoring_bind`

node_exporter was the only listener here that defaulted to `0.0.0.0`, and
prometheus bound it too while grafana right beside it was already pinned. All
three take `monitoring_bind` (`127.0.0.1`) now, the same posture as ollama and
vLLM.

The consequence is deliberate: a prometheus running elsewhere cannot scrape this
node directly, and the `dashboards` tier's job for the peer shows **down**. Come
in over an SSH tunnel or the mesh VPN address, or widen `monitoring_bind`
knowing it puts an unauthenticated metrics endpoint on every interface. The
target for the peer stays in the scrape config — a peer reported down is a fact
you can act on, and omitting it would hide half the cluster. See
[monitoring](runbooks/monitoring.md).

`prometheus_retention` and `prometheus_port` were wired up in the same change.
They were presented in `group_vars` as working knobs and were not: retention was
read by nothing, and the port only ever reached the self-scrape target, so
changing it broke the self-scrape instead of moving the server.

## The inventory name is the hostname

`node_hostname` defaults to `inventory_hostname` and `roles/base` applies it, so
one string is the machine's hostname, its `/etc/hosts` entry, its `Host` block
in `~/.ssh/config`, its Slurm `NodeName` and its Prometheus `instance` label.
Renaming a node is renaming it in `inventory.yml`.

The alternative — an inventory alias that differs from the system hostname — is
two names for one machine, and every log line, `sinfo` row and dashboard panel
then has to be mentally translated. Nothing here needed that.

Two consequences worth knowing. `roles/base` rewrites Ubuntu's
`127.0.1.1 <hostname>` line to point at the node's **routable** address instead
of loopback: `ansible.builtin.hostname` does not touch `/etc/hosts`, so after a
rename that line names a machine that no longer exists and `sudo` pays a DNS
timeout on every call. More importantly, torchrun is launched as
`--master_addr <controller>` and rank 0 resolves that name *itself* — pointing
it at `127.0.1.1` binds the rendezvous socket to loopback, the peer connects to
a port nothing is listening on, and the job hangs at init with no error.

## Passwordless sudo, deliberately

`sudo_passwordless` installs `/etc/sudoers.d/90-gx10-<user>` with
`NOPASSWD:ALL`. This is a real privilege decision and it is a variable rather
than a silent side-effect: anything that can execute as this user can become
root without a secret.

It is on because the honest alternative is worse. This is a two-node cluster
driven entirely by Ansible over key-only SSH, and `-K` prompts once per *run*,
so the password has to be typed into `make apply`, `make models`, `make
optional` and anything scheduled. In practice that means it ends up in shell
history, a script, or a CI secret — all strictly worse than a sudoers file whose
contents are visible and version-controlled.

The write is `validate: visudo -cf %s`, and that is not decoration: a malformed
file in `sudoers.d` breaks `sudo` for every user, and on a box with no BMC and
`PermitRootLogin no` that needs physical access to fix. The filename carries no
dot or tilde, because `sudo` silently ignores files in `sudoers.d` that have
either.

The first run still needs `-K` — the drop-in does not exist yet. Afterwards
`ASKPASS=` drops the prompt (`make diff ASKPASS=`), which is not only
convenience: `-K` uses `getpass` and needs a tty, so from a non-interactive
shell it fails with `Can not control echo on the terminal` followed by
`Missing sudo password`.

## A dedicated cluster admin key, not a reused personal one

`authorized_keys` ships one entry: an ed25519 pair generated once for this
cluster and used for nothing else. Revoking cluster access is then one line in
`group_vars/all.yml` with no effect on any other machine you log into, and the
key's presence in a repo tells you exactly what it is for.

Its private half does not belong on a node, so provisioning does not put it
there — it is generated once, by hand, and moved off. See
[provision-node](runbooks/provision-node.md#the-cluster-admin-key).

The list is additive on purpose. `ansible.posix.authorized_key` with
`state: present` never removes what it did not add, which is what keeps the
per-node `id_gx10_cluster` keys that `trust.yml` cross-authorizes from being
wiped on the next run. The cost is that revoking a key means deleting the line
*and* removing the stale entry from the node.

## <a name="nordvpn-sysctl"></a>nordvpnd owns the socket buffer ceilings, so the repo stopped claiming them

`roles/base` used to set `net.core.rmem_max` and `net.core.wmem_max` to
134217728. It never had them: `nordvpnd` sets both to 7500000 itself on every
start, and it is `Type=simple` with `Restart=always`, so nothing the play can
schedule reliably runs after the daemon has finished initialising —
`ExecStartPost` fires at fork, long before. On a booted node the repo's value
was never in effect, and because it was still written to
`/etc/sysctl.d/90-gx10.conf`, `ansible.posix.sysctl` compared the file against
the live value and reported `changed` on every run: `make idempotence` could
never pass, with no obvious culprit.

Conceding is cheap. These are ceilings for large TCP transfers — checkpoint
copies, model downloads — and explicitly **not** for NCCL, which runs over RDMA
and bypasses the socket layer entirely. nordvpn's 7500000 is already ~35× the
212992 kernel default.

The two keys are removed with `state: absent` rather than just deleted from the
loop, because a deleted loop entry leaves the line in `90-gx10.conf` on every
already-provisioned box, still asserting a value nothing applies. If the VPN
ever goes away, this is worth revisiting.

## <a name="benchmark-tooling"></a>Benchmarks are upstream tools, and thresholds must cite a source

`roles/benchmark` installs perftest, fio, OpenMPI, DCGM and a pinned
`nccl-tests`, and `benchmark.yml` runs them. It computes nothing itself. The
reason is comparability: `busbw` from `all_reduce_perf` can be held next to
NVIDIA's published figures and next to every NCCL bug report ever filed, and a
number this repo derived on its own cannot. The repo's `allreduce_test.py`
stays as a fast smoke test — it is not what you quote.

The harder rule is on thresholds. Every entry in `vars/benchmark_checks.yml`
carries a mandatory `provenance` string, and where no defensible source exists
the entry is `RECORD ONLY`: measured, reported, never asserted on. A threshold
with no stated basis is indistinguishable from one picked to make the suite go
green, and it is worse than no threshold at all, because it looks like
engineering.

The floors that do exist are set an order of magnitude below measured values,
not just under them. They exist to catch the two failures
[connect-cluster](runbooks/connect-cluster.md#reading-the-result) documents —
TCP fallback and the reported ConnectX-7 firmware throttle — both of which
present as a healthy cluster running an order of magnitude slow. A floor set
near the measured value fails on ordinary variance instead, and a check people
learn to ignore protects nothing. Drift is tracked by diffing successive result
files.

HPL is deliberately absent. `Rmax` is the most quoted number in HPC, but the
only route to it here is a container whose GB10 support this repo has not
verified, and an unverified FLOP number is worse than no FLOP number.

## <a name="optional-apply-tags"></a>`apply:` on every optional `include_role`, or the component silently installs nothing

A companion to [the entry above](#optional-include-role), and the failure it
describes is worse than the one it fixed.

Tags on a dynamic include select the **include**, not the tasks inside it. The
role's own tasks carry no tag, so `--tags ray` matched the include, ran it, and
then filtered out every task it pulled in. `make optional TAGS=ray` reported
`ok=1 changed=0` having installed nothing — and it read as success. This
affected all five opt-in entries at once, and was found only when a sixth was
added and its packages never appeared on the box.

`apply: tags:` is the documented mechanism that pushes the tag onto the
included tasks. Each entry applies only the tag that selects it, so the
exporters/dashboards split the entry above exists to protect is preserved:
`--tags exporters` still cannot drag in grafana.

The reason this survived is worth keeping. The comment here claimed
`--list-tasks --tags exporters` proved the split — it proves nothing, because
it does not expand dynamic includes. It prints the include task and stops,
identical whether the role runs or not. A verification that cannot distinguish
the working case from the broken one is not a weak check, it is a false one.
`tests/check_optional_tags.py` now asserts the `apply` block is present, since
neither ansible-lint nor `--syntax-check` nor a dry run can see its absence.

## <a name="history-timer"></a>History comes from a timer, not an agent, and `SW Power Cap` is not a throttle

Two decisions from the same measurements.

**A timer, not an agent.** `gx10-status` could only ever answer "what is
happening now", which leaves the two failures that actually ruin an overnight
run — a thermal cap and a swap excursion — invisible by morning. The fix is
`gx10-sample`, a script a systemd timer runs every 10 s: it appends one CSV row
and exits, so nothing is resident between samples. Measured: 0.08 s wall,
21 MB peak RSS per sample, all transient; ~1 MB of CSV per day.

node_exporter was the obvious alternative and is rejected on the right grounds.
It is ~20 MB resident, which is 0.016% of 121 GB — the memory objection people
raise about it is real about Prometheus, whose TSDB lives in RAM, and
essentially imaginary about the exporter itself. What rules it out is that it
is a *listener*: its data exists only while something external scrapes it, so
closing a laptop stops the history. The exporter tier stays available for when
you want dashboards and have somewhere else to run them.

**`SW Power Cap` is excluded from every throttle warning.** Measured on an idle
GX10 with no compute process — 0% utilisation, ~5.3 W, 208 MHz — it was Active
in 7 of 15 consecutive one-second samples, and 46% of uptime by its own counter
(26149 s of 55870 s). It flaps second to second: ordinary DVFS on this SoC.

`gx10-status` previously warned on it, which meant a red throttle warning on
roughly every other invocation, uncorrelated with anything being wrong. A
coin-flip alarm is worse than a constant one — you stop reading it, and it
buries the `HW Thermal Slowdown` printed on the same line. Both tools now warn
only on genuine fault reasons and record the cumulative counter instead,
because the rate is meaningful even where the state is not.

## <a name="roce-not-ib"></a>The fabric is RoCE, and a tool says so, because absence of InfiniBand reads as absence of a link

The ConnectX-7 here runs an **Ethernet link layer** and carries RDMA as RoCE v2.
Every InfiniBand-native way of asking "are the two boxes connected?" therefore
returns nothing on a completely healthy cluster: `ibhosts`, `ibnodes`,
`iblinkinfo` and `ibnetdiscover` all fail with `can't open UMAD port` because
they speak IB SMPs to a subnet manager and RoCE has none; `base lid` and
`sm lid` are `0x0` for the same reason; the devices are named `roce*`, not
`mlx5_*`; and `opensm` is not installed, deliberately, because a subnet manager
on an Ethernet link layer manages nothing.

Nothing is indistinguishable from *not connected*. That is not a hypothetical:
it is the failure that prompted this entry, with 21.6 GB/s of NCCL traffic
crossing the link at the time.

Two fixes, because the problem had two halves.

**A tool that reports the fabric that is there.** `gx10-interconnect` prints the
link layer, per-port state, address, MTU and PCIe ceiling, and peer
reachability, and exits 0 healthy / 1 degraded / 2 no NIC so it can be gated on.
`--peer` adds a real RDMA round trip, which matters because RoCE v2 rides
UDP 4791 and a firewall can pass ICMP while dropping it — a link that pings
perfectly and hangs every collective. It lives in `/usr/local/bin`, not
`~/.local/bin` beside `gx10-status`, so that `ssh <node> gx10-interconnect`
works: that is a non-login shell and never gets `~/.local/bin` on PATH.

**Checks that ask the right question.** `RDMA devices` tested only whether
`ibv_devices` listed anything, which the CX-7 does whether or not a single port
links — green on a box with no cable in it. It is now `RDMA link active`,
against port state in sysfs. A new `RoCE fabric` check asserts the Ethernet link
layer, guarding the assumption the whole role rests on: address these ports as
IP subnets and a card flipped to IB mode would leave every other check passing
while nothing could talk.

Note the trap in the other direction: **NCCL calls this transport `NET/IB`** and
logs `Using network IB`. That is its name for ibverbs, which serves IB and RoCE
alike. `NET/IB` is evidence the fast path is in use, not evidence of an
InfiniBand fabric.

## <a name="one-cable-two-partitions"></a>One cable, two PCIe partitions — and how to tell that from two cabled ports

A revision of this repo "corrected" the interconnect description from *one port
presenting two partitions* to *two separately cabled ports*, citing the two PCIe
root complexes as evidence. That was wrong, and the way it was wrong is worth
keeping, because the misreading is natural.

Four netdevs exist. Two are up, on different PCIe roots (`0000:01:00.0` and
`0002:01:00.0`), which looks exactly like two cards behind two cages. It is not.
Three measurements settle it:

```bash
cat /sys/class/net/*/phys_switch_id     # all four identical -> one ConnectX-7 ASIC
cat /sys/class/net/*/phys_port_name     # enp1s0f0np0 and enP2p1s0f0np0 are BOTH p0
sudo ethtool -m <iface> | grep 'Vendor SN'
```

`phys_port_name` is the decisive one: the two live netdevs are two partitions of
the **same physical cage**, `p0`. The `f1` pair is the second QSFP port, `p1`,
which is empty. And both nodes read the *same* module serial
(`01130300258K0747`, Amphenol NJAAKK-AU06 1 m DAC) — one cable, seen from each
end, not two cables that happen to be the same model.

The PCIe root split is real but is a packaging detail: the cage's lanes are
presented as two x4 functions. They must still be on **different subnets**, or
both flows leave by one interface and half the bandwidth is unreachable while
every per-interface view looks correct.

**The ceiling is the cable, not the bus.** Two Gen5 x4 partitions are ~126 Gb/s
each, ~252 Gb/s together, behind a single 200 Gb/s port — so the wire binds
first. One partition alone, though, is ~126 Gb/s and cannot carry the port,
which is why addressing only one costs roughly half.

Measured two-node NCCL all-reduce is 21.6 GB/s busbw ≈ 173 Gb/s ≈ **86% of the
200 Gb/s cable**. That figure is itself the cross-check: against two 200 Gb/s
cables it would be a dismal 43%, and the "two ports" reading never explained it.

It did correctly recalibrate one thing. The runbook called ~10 GB/s "the healthy
number", carried from NVIDIA's playbook and never measured here — about what a
single partition delivers. The old table scored a half-configured cluster as
perfect and a correct one as anomalous.

One finding recorded rather than acted on: NCCL reports `GPU Direct RDMA
Disabled` with `cuMemGdrSupport 0`, which is expected on GB10 — GPU memory *is*
host memory, so there is no separate BAR to register for peer DMA, and
`nvidia-peermem` will not change it.

## <a name="jumbo-mtu"></a>Jumbo frames on the interconnect, and why the number that matters is 4096

`cluster_mtu` was unset for a documented reason — a mismatch between ends drops
packets silently, so it wanted measuring rather than guessing. It has now been
measured and is set to 9000.

**"Jumbo" names the wrong target.** The RoCE path MTU is quantised to powers of
two at or below the netdev MTU, and the card's `max_mtu` is 4096. So a 1500-byte
netdev negotiates `active_mtu 1024`; crossing ~4200 unlocks 4096; and everything
above 4096 is inert for RDMA. 9000 is set because it is the conventional jumbo
value and costs nothing, not because RDMA uses it.

Per-packet wire overhead is ~82 bytes, so the predicted efficiency move is
1024/(1024+82) = 92.6% → 4096/(4096+82) = 98.0%, or +5.9%.

Measured, two-node NCCL all-reduce busbw, four runs each:

| | runs | mean |
|---|---|---|
| MTU 1500 / `active_mtu` 1024 | 21.9, 22.0, 21.9, 22.0 | 21.95 GB/s |
| MTU 9000 / `active_mtu` 4096 | 22.6, 22.5, 22.8, 22.8 | **22.68 GB/s** |

**+3.3%**, with non-overlapping ranges, landing under the 5.9% ceiling as
expected since MTU is not the only overhead. ~181 Gb/s ≈ **91% of the 200 Gb/s
cable**. Write latency is unchanged at ~1.7 µs, so small messages did not pay
for it.

A first single pre-change sample read 21.6 GB/s and suggested +4.6%. It was a
low outlier; four paired runs each way corrected it. One sample either side of a
few-percent effect is not a measurement.

**Per-partition `ib_write_bw` did not move at all** — 13334.7 → 13334.6 MB/s.
That is the expected shape, not a contradiction: one x4 partition is PCIe-bound
at ~107 Gb/s of a ~126 Gb/s bus, where wire overhead is not the binding
constraint. Both partitions together are cable-bound at 200 Gb/s, which is
exactly where shaving per-packet overhead pays. A single-partition benchmark
would have concluded jumbo does nothing.

### The trap that nearly hid it

NetworkManager writes an MTU change into the connection **profile** and does not
apply it to a connection that is already active. After the first apply,
`nmcli -g 802-3-ethernet.mtu connection show gx10-cluster-0` reported `9000` and
the connection reported `activated`, while `ip link` still said `mtu 1500` and
`active_mtu` was still 1024. The nmcli task reports `changed` either way.

So the role now notifies a handler that runs `nmcli connection up` on each
partition. Same shape as the missing `daemon_reload` in `roles/monitoring`, and
worse in consequence: a half-applied MTU is asymmetric, and asymmetric MTU drops
packets silently rather than failing loudly. Bouncing the interconnect is safe
only because ansible reaches both boxes over the management NIC — never over the
cable — and it is not safe during a distributed job.
