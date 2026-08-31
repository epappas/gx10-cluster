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
which is empty. And both nodes read the *same*
module serial off an Amphenol NJAAKK-AU06 1 m DAC — one cable, seen from each
end, not two cables that happen to be the same model. (Compare the serials
yourself; the equality is the evidence, so this repo does not print the value.)

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

## <a name="gx10-top"></a>`gx10-top` ships its collector, reads RDMA counters, and judges swap on growth

A cluster-wide live view, because `gx10-status` can only ever answer "this box"
and the interesting failures on a two-node cluster are *disagreements* between
nodes. Same bargain as the rest of the role: fork a collector per node, render
one frame, sleep. Nothing resident.

Four decisions worth keeping.

**The collector is shipped over stdin, not installed.** One file to deploy, and
more importantly a renderer can never be fed a payload by a stale collector left
on some node by an older provision. It costs a few KB per node per frame over a
connection that is already multiplexed.

**SSH is multiplexed** (`ControlMaster`/`ControlPersist`). At a 2 s refresh a
fresh TCP handshake and key exchange per node per frame costs more than
everything the collector actually does.

**RoCE rows come from the RDMA port counters, never netdev.** RDMA bypasses the
kernel network stack: measured, pushing 66 GiB across the cable moved
`/sys/class/net/<if>/statistics/tx_bytes` by **exactly 0**. The RDMA counter, in
4-octet words, gave `port_xmit_data * 4` = 68291 MiB over 5 s = 13.3 GB/s,
matching `ib_write_bw` to the byte. A netdev-based panel would show a flat zero
on a saturated link — the same class of mistake as reading an empty `ibhosts` as
a missing fabric ([that one](#roce-not-ib)).

**Swap warns on growth, not presence.** Both nodes carry a few hundred kB of
long-idle pages, so a `> 0` alarm lit the divergence line red permanently. That
is the identical coin-flip alarm removed from the `SW Power Cap` warning
([why](#history-timer)), and it would bury a real excursion the same way. The
level is always displayed; only an increase between frames warns.

**It has to be readable at a glance, not parsed.** A monitoring tool you must
read line by line is one you stop opening. So the top two lines are a green `OK`
or a red `ALERT` naming the fault, and the common case needs no reading at all;
below that, bars carry magnitude and sparklines carry ~12 samples of trend.
Colour is consistent - green fine, amber >60%, red >85% or broken - with GPU
utilisation the deliberate exception, cyan and never red, because a busy GPU is
the goal rather than an alarm.

**GPU processes are attributed to their container.** `nvidia-smi` only ever sees
the host pid and reports a containerised process as a bare `python`, so "which
container is keeping the GPU busy" had no answer anywhere on the box. The tool
reads the pid's cgroup and matches the 12-hex id against `docker ps`, printing
`@name`. Verified against a `--gpus all` container: pid 244850 ->
`docker-<64hex>.scope` -> `gputest`. Note also that `--query-compute-apps` does
report per-process GPU memory on GB10 (measured 767 MiB for a torch process) even
though the device-level memory query returns `[N/A]` - no framebuffer to total,
but per-process accounting works.

Three implementation traps, recorded because each is silent.

The rate and percentage helpers mutate the delta baseline, so calling them inside
`$( )` ran them in a subshell and discarded every write. Every rate rendered as
`-` forever, on every frame, with no error. They return through a global now.

`printf %*s` pads by **bytes**, not display columns, so a bar drawn with U+2588
(3 bytes, 1 column) destroys the grid. Bars are therefore ASCII; sparklines,
which have no ASCII equivalent worth having, are padded by hand from a known
sample count.

The first version trapped `INT` to clean up but never exited, so Ctrl-C ran the
handler and the loop carried straight on - the view could not be quit at all.
Cleanup is now on `EXIT` and `INT`/`TERM` just `exit 130`; the refresh wait is a
`read -t` rather than `sleep`, so `q` works too without a second thread. Testing
that needs a real pty: launched with `&` from a non-interactive shell, bash
inherits SIGINT as ignored and refuses to trap it at all, which looks exactly
like the bug that was just fixed.

## <a name="private-vars"></a>Three tiers for configuration, and site identity is not a secret

Values here fall into three groups, and conflating them is how a public repo
ends up carrying someone's username or a token ends up in git.

| Tier | Where | Tracked | For |
|---|---|---|---|
| Default | `group_vars/all.yml` | **yes** | What the repo does out of the box |
| Private | `group_vars/<group>/local.yml`, `host_vars/<host>/local.yml` | no | Private but not secret — your username, a local override |
| Secret | `group_vars/<group>/vault.yml` | no, and encrypted | `hf_token`, the NordVPN token |

Ansible loads them in that order and each outranks the last, so a private
override wins without editing a tracked file — which is the point. Both private
tiers use the **directory** form, because `group_vars/<group>/*` is auto-loaded
while `group_vars/<group>.local.yml` parses as a group named `<group>.local` and
is silently never read.

The middle tier was missing, and its absence is what put `ansible_user: epappas`
into a committed inventory. Encrypting a username with vault would be theatre —
it is not a secret, it just is not the public's business — so the requirement is
"untracked", not "encrypted", and a plain gitignored file is the honest fit.

**Defaults still live in the tracked file.** A private-only value breaks a fresh
clone: `ansible_user: "{{ gx10_user }}"` with `gx10_user` defined nowhere is an
undefined-variable error before the first connection. So `gx10_user` defaults to
the invoking local user in `group_vars/all.yml` and the private file overrides
it. Verified in both directions: with `gx10_user` set in
`group_vars/gx10/local.yml` the connection uses it; with the file removed it
falls back to the committed default.

**The management addresses moved too, via a gitignored inventory.** The earlier
version of this entry argued they should stay: `ansible_host` is the documented
single source for a node's address, and an overlay would create a second copy.
That reasoning was right about overlays and wrong about the conclusion - the
answer that keeps one source of truth is to gitignore `inventory.yml` and track
`inventory.example.yml` instead. There is still exactly one place a node's
address is written; it just is not a tracked file.

The example ships RFC 5737 documentation addresses (`192.0.2.0/24`) rather than
plausible RFC1918 ones, deliberately: they are guaranteed not to route, so
forgetting to edit fails fast with an unreachable host instead of quietly
reaching some other device on your LAN.

`bootstrap.sh` seeds `inventory.yml` if it is missing, CI seeds it before
running checks, and every Makefile target that reads the inventory depends on a
guard that prints the `cp` command. Without that guard a missing inventory
surfaces as "provided hosts list is empty" followed by "skipping: no hosts
matched", which reads like a tag typo rather than a missing file.

## <a name="ci-was-red"></a>CI was red on every run, because a gitignored file is a hard dependency

Found while testing the gitignored-inventory change, by cloning the repo and
running `make check` the way a stranger would: **every CI run had been failing**,
and the badge added to the README on the assumption it was green was advertising
a red build.

`ansible.cfg` sets `vault_password_file = .vault_pass`. That file is gitignored,
and a **missing** vault password file is a hard error on every ansible command -
not a fallback to prompting. So no checkout could run a single ansible command,
and `make check` failed at the first one. The file's own comment predicted this
exactly ("if you clone this repo without one, either create it or comment this
line out"); what was missing was anyone acting on it for CI.

The fix is to create the file rather than to remove the setting: a checkout
contains no `vault.yml` either, so nothing is ever decrypted and the password is
irrelevant - but the file has to exist. CI writes a placeholder; `bootstrap.sh`
writes one for humans, at `umask 077`.

The general lesson, which is why this is written down: **a gitignored file that
every command depends on is a hard dependency with no declaration.** Local
machines have it and forget it exists, and the only way to see the failure is to
run from a tree that never had it. `git archive $(git write-tree) | tar -x` into
a temp directory reproduces a clone including uncommitted work, and is now the
cheapest way to check this class of bug before publishing.

## <a name="workspaces"></a>Workspaces are not Ansible, and the seam is a `requires:` block

`roles/` and `workspaces/` do two different jobs on two different clocks:

| | `roles/` | `workspaces/` |
|---|---|---|
| Converges | a **machine** to a state | nothing — it **runs** things |
| Frequency | rare, privileged, slow | constant, unprivileged, fast |
| Failure means | the node is broken | today's experiment is broken |

What you run changes far more often than the machine does. Expressing recipes
as roles means every experiment needs a playbook run, every recipe is
reproducible only through Ansible, and a serving flag change becomes a
converge. So Ansible stops at *ready* and workspaces take it from there.

**The only coupling is the `requires:` block**, checked by `ws check`: a
workspace declares what it needs (compute capability, unified memory, docker,
an ACTIVE RDMA port, reachable peers) and the runner tests that against the
machine Ansible produced. No workspace reads anything from `roles/`, and no
role knows a workspace exists. When `ws check` fails it names an Ansible fix;
when a workspace fails after checks pass, the machine is fine.

Every recipe is plain `docker`/`compose` or a plain command, so it can be read,
copied and run without `ws` at all. A recipe only a runner can execute is a
worse recipe.

**Manifests are a flat YAML subset**, parsed with awk. `yq` is not installed by
this repo and adding a dependency to read six files is not worth it — but that
choice has a sharp edge: awk silently returns nothing for structure it cannot
read, so a typo'd requirement key means the check never runs and preflight
reports ready. `tests/check_workspaces.py` exists for exactly that failure and
rejects unknown `requires:` keys, name/directory mismatches, and manifests with
no `sources:`.

**`workspaces/` is excluded from ansible-lint.** It parses every YAML it finds,
reported the compose files as malformed playbooks, and — worse — dropped the
whole run from the `production` profile to `min`, which would have hidden real
findings in `roles/`.

**Ray exists twice, deliberately.** `roles/ray` installs a standing systemd
service; `workspaces/cluster/ray` starts an ephemeral containerised cluster for
one experiment. They will fight over ports, so pick one — but for RL the
ephemeral one is usually right, because verl pins a Ray version and you want
that one rather than whatever the host was provisioned with.

**Slurm deliberately lands on the other side of the line.** Its daemons stay in
Ansible: a scheduler is infrastructure — munge keys, controller state, a daemon
per node, a shared clock — and a containerised `slurmd` that cannot see host
processes cannot account for them. The workspace ships only what changes per
experiment, the job scripts.

**The engine/quant matrix is the expensive thing to learn late.** SGLang cannot
serve `unsloth/Qwen3.8-27B-NVFP4`: the checkpoint has a quantised `lm_head`,
which SGLang does not support. This is recorded in `workspaces/README.md`, in
the runbook and in the SGLang manifest itself, because it is discoverable only
by trying and failing.

*Later correction:* this section originally generalised that into "SGLang is
the one engine that cannot use NVFP4 on Blackwell". It is a fact about **that
checkpoint** — SGLang serves NVIDIA's Nemotron 3.5 Lightning NVFP4 on day 0 on
this hardware ([#nemotron35-lightning](#nemotron35-lightning)). Left visible
rather than quietly edited, because the shape of the mistake is the lesson: a
negative result measured on one checkpoint is not a capability claim about an
engine.

**Every workspace ships `provenance: unverified`.** They are written from
vendor documentation and the sources cited in each manifest, not from a
completed run on this hardware — `ws list` renders that in yellow. Publishing
them unverified but labelled is the same trade the runbooks make; publishing
them as if they were tested would not be.

## <a name="two-node-vllm"></a>What was ported from MiaAI-Lab's 2x DGX Spark recipe, and what was not

[MiaAI-Lab/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark](https://github.com/MiaAI-Lab/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark)
is the only published **two-node GB10** serving configuration we have found, and
it runs the topology this cluster has. Most of it is DeepSeek-v4 plumbing. A
small part of it is the generic answer to "how do you run one model across two
Sparks", and that part is easy to get wrong in ways that fail quietly.

### Taken

| From them | Why it matters |
|---|---|
| `--device /dev/infiniband` and `ulimit memlock=-1` on the container | **The two most consequential lines.** Without the device nodes, ibverbs finds no adapter inside the container and NCCL falls back to **TCP** — which works, just slowly, so it presents as a disappointing model rather than a misconfiguration. Without unlimited memlock, queue-pair registration fails outright |
| `TP_SOCKET_IFNAME` and `GLOO_SOCKET_IFNAME` | vLLM's distributed init is `torch.distributed`, and **gloo does not read `NCCL_SOCKET_IFNAME`**. Unset, it picks an interface by its own heuristic — on this box that can be `docker0` or the VPN — and the ranks never meet. This repo set only the NCCL variable |
| `--nnodes/--node-rank/--master-addr/--master-port`, `--headless` on rank 1, `--distributed-executor-backend mp` | The two-node vLLM topology itself |
| `NCCL_IB_ROCE_VERSION_NUM=2`, `NCCL_IB_ADDR_FAMILY=AF_INET` | The GID table here carries both RoCE v1 and v2 for every port; only v2 routes |
| `NCCL_NVLS_ENABLE=0` | No NVLink between two Sparks, so NVLS has nothing to accelerate |
| **Disable `earlyoom`** | Their first documented gotcha. On unified memory the largest-RSS process is *always* the model server and "tight" is its normal operating point, so earlyoom kills precisely the workload the cluster exists for. Now a `make verify` check — it is not installed here, and this stops a distro update turning it on silently |

### Not taken

- **The DeepSeek-v4 hotfix stack.** Nine-plus patch scripts against their vLLM
  fork, addressing numbered upstream issues. Model- and fork-specific.
- **`--kv-cache-dtype nvfp4_ds_mla`, `--tokenizer-mode deepseek_v4`, the
  deepseek reasoning/tool parsers.** Model-specific.
- **The Anemll fork image** `ghcr.io/anemll/dspark-vllm-gx10`. Taking a fork
  means inheriting its release cadence for every model; upstream
  `nightly-aarch64` is the same bet this repo already makes elsewhere.
- **`--moe-backend flashinfer_b12x` and the `VLLM_B12X_*` tuning.** MoE- and
  fork-specific.
- **Their fabric addressing.** They point the rendezvous at the interconnect
  subnet. This repo keeps bootstrap on management and lets NCCL choose RoCE
  independently through ibverbs — measured, and documented at
  [#nccl-socket-ifname](#nccl-socket-ifname) and [#hosts-split](#hosts-split).
- **`NCCL_IB_HCA`.** The interesting one, because it is a *measured*
  disagreement rather than a preference. They pin the device list; we do not,
  because our own NCCL run shows discovery already getting it right:
  `NET/IB : Using [0]rocep1s0f0:1/RoCE [1]roceP2p1s0f0:1/RoCE` — both ACTIVE
  ports, both permanently-DOWN partitions correctly skipped. Pinning a device
  list by hand is how you silently end up on one rail after a cable moves. It
  remains available as `IB_HCA=` in the workspace's `.env`, for the case where
  a log actually shows the wrong device.

### Improved on

Their operational model keeps a `.env` on each node, and the README warns you
to sync it to the worker before restarting, with both ranks needing an
identical image digest. That is a real hazard with a silent failure mode:
mismatched ranks hang at init rather than erroring. `workspaces/inference/vllm-2node-tp2`
launches **both** ranks from one script, so the class of bug does not exist
rather than being documented.

### Recorded, not acted on

They compile kernels for **`sm_121a` / `TORCH_CUDA_ARCH_LIST=12.1a`** — note the
`a` suffix, the architecture-specific variant — while this repo builds
llama.cpp for `sm_121` and checks `compute_cap` against `12.1`. These are not in
conflict (`nvidia-smi` reports `12.1`; the `a` form is a compilation target),
but if a FlashInfer or CUTE-DSL kernel ever misbehaves here, the arch suffix is
the first thing to check.

Their published throughput, for calibration rather than as our target: ~62–83
decode tok/s single-stream and ~160–190 tok/s aggregate across six streams, for
a much larger model than anything measured here.

## <a name="serving-bench"></a>"Bench" means two different things here, and the new one needed a live view

`make bench` already existed and measures the **hardware**: nccl-tests,
perftest, iperf3, fio, DCGM. It answers *is this cluster fit to run work*.

`ws up vllm-bench-serve` measures a **model server**: `vllm bench serve`
against a running endpoint, swept across a concurrency ladder. It answers *how
many concurrent streams does this model hold on this box before latency falls
over*. Same word, no overlap in what they run, and
[#benchmark-tooling](#benchmark-tooling)'s rule still applies to both — the
numbers come out of an upstream tool, not out of something invented here.

### Why a TUI, when `vllm bench serve` already has `--plot-timeline`

The timeline is good and the workspace turns it on. It is also a **post-mortem**
— an HTML file you open once the run is over.

On unified memory that is not enough, for a specific reason. The numbers that
decide whether a benchmark result is *valid at all* are transient:

| Signal | Where it comes from | What it means if you miss it |
|---|---|---|
| KV cache occupancy | `vllm:kv_cache_usage_perc` | Pegged at 100% → you measured **preemption**, not throughput |
| Queue depth | `vllm:num_requests_waiting` | Deep → the server never got to steady state |
| Swap growth | `/proc/meminfo` | Growing → you measured **paging**. On coherent memory this is a cliff |

A run that swapped and a run that did not produce the *same shaped summary
table*. Nothing in the JSON says which one you have. So the sweep is driven by
a view that reads the server's own `/metrics` while the run is in flight, and
the honest conclusion — *this point is not a measurement* — is visible at the
time rather than inferred later.

Both `vllm:kv_cache_usage_perc` and the older `vllm:gpu_cache_usage_perc` are
accepted. V1 renamed it, and which one a given nightly emits is not something a
benchmark should have an opinion about.

### It watches every node, because a two-node server has one endpoint

A tensor-parallel vLLM server exposes **one** endpoint: rank 0 serves, rank 1 is
`--headless`. So two of the three signal sources already describe the whole
deployment without doing anything special:

| Source | Scope | Why |
|---|---|---|
| Load generation | whole cluster | One endpoint. The client does not need to be distributed |
| `/metrics` | whole cluster | Rank 0 exposes the *engine's* counters, and the engine spans both nodes |
| Host telemetry | **one node** ← the gap | `nvidia-smi` and `/proc/meminfo` are per-machine |

That third row mattered more than it looks. **Rank 1 swapping invalidates a
benchmark exactly as much as rank 0 swapping does**, and watching only the node
you happened to type on is how you publish a number the cluster did not produce.

So the host pane samples every node — this host plus everything in
`/etc/gx10/interconnect.peers` — which means it picks up a third and fourth
Spark with no configuration. Three details are load-bearing:

- **The sampler is shipped over stdin**, not installed on each node. One file to
  deploy, and a local row can never disagree with a stale copy an older run left
  on a peer. Same bargain [#gx10-top](#gx10-top) makes.
- **Collection never blocks the render loop.** Collectors are fire-and-forget,
  at most one in flight per node; a node that is rebooting shows its previous
  sample and then `no sample`, rather than freezing the view mid-benchmark —
  the moment you least want to lose it.
- **`ssh -n` is wrong here** and cost an hour of "the peer is unreachable". It
  redirects stdin from `/dev/null`, which silently eats the here-string carrying
  the sampler; the peer then runs an empty program, exits 0 and prints nothing.
  A healthy node reads as dead. The connection is multiplexed
  (`ControlMaster`/`ControlPersist`) because this runs per node *per frame*.

**Swap is judged on growth, not on presence** — again as [#gx10-top](#gx10-top)
does, and the first real run proved why: a peer held 120 MB of swap from days
earlier. Flagging that trains you to ignore the one row that matters. The
watermark re-baselines per sweep point, so growth during point 1 does not keep
condemning points 2..N — each rung is its own measurement.

### The one methodological choice worth defending

`num_prompts` scales with concurrency (`concurrency * PROMPTS_PER_STREAM`)
rather than being fixed. A fixed count measures a different thing at each rung:
64 prompts at concurrency 1 is 64 sequential requests; at concurrency 32 it is
two batches, most of which is ramp. Ramp is exactly what a steady-state
throughput number must not contain.

## <a name="twonode-lib"></a>The two-node launcher is a library, and it is the only recipe here that is not standalone

Every workspace is deliberately readable, copyable and runnable by hand
([#workspaces](#workspaces)). `workspaces/lib/twonode.sh` breaks that, once, on
purpose.

The argument is the one `vllm-2node-tp2` already made about its two *ranks*:
the failure mode of a mismatch is **silent**. Ranks that disagree hang at init
with no error. A container missing `/dev/infiniband` runs at TCP speed and
looks like a slow model. A `GLOO_SOCKET_IFNAME` set in one place and forgotten
in another gives you a cluster that works on Tuesday and not on Wednesday.

That argument does not stop at two ranks of one workspace. Two *workspaces*
each carrying their own copy of the wiring drift the same way — just slower,
and with nobody watching. Adding `vllm-2node-deepseek-v4-flash` would have
meant a second copy of the RDMA device nodes, the memlock ulimit, the gloo
variables and the rendezvous split.

So the wiring lives once and each workspace supplies only `MODEL_ARGS`. The
test of the split: **anything whose value depends on the model stays in the
workspace; anything whose value depends on the topology moves to the library.**

## <a name="deepseek-v4"></a>DeepSeek-V4 on GB10: the quant is chosen by the memory budget, and for V4-Pro by the node count

DeepSeek-V4 ships two models and this cluster's relationship to them is not
symmetric. Every size below is the sum of a repo's shards, from its own file
listing — not an estimate, and not a vendor's round number.

### V4-Flash (284B, 13B active) — fits, and the ladder is the whole decision

| Build | Size | Left of a ~112 GB budget |
|---|---|---|
| UD-IQ1_S | 82.5 GB | ~29 GB |
| UD-IQ1_M | 86.9 GB | ~25 GB |
| UD-IQ2_XXS | 90.9 GB | ~21 GB |
| **UD-IQ2_M** | **90.9 GB** | **~21 GB** ← single-node default |
| UD-Q2_K_XL | 96.8 GB | ~15 GB |
| UD-IQ3_XXS | 104.2 GB | ~8 GB |
| UD-IQ3_S and up | ≥116.1 GB | does not fit |
| *dspark draft (Q8_0)* | *10.9 GB* | *needs one of the top four* |
| *FP8 checkpoint* | *~149 GiB* | *two nodes, TP=2* |

**UD-IQ2_M is the default for what it leaves behind, not for what it costs.**
~21 GB of headroom fits the DSpark draft model *and* a desktop session;
UD-IQ3_XXS leaves ~8 GB, which fits neither. Speculative decoding is worth more
than one rung of quantisation on a memory-bound box, and IQ2_M is the largest
build where weights and draft both fit at once (90.9 + 10.9 = 101.8 GB).

UD-IQ2_M and UD-IQ2_XXS are the same size to a tenth of a gigabyte, so IQ2_M is
strictly the better of those two.

### V4-Pro (1.57T, 48B active) — the binding constraint is node count

| Build | Size | Source |
|---|---|---|
| **IQ1_S** | **337 GB** | 6block ← default |
| IQ1_M | 372 GB | 6block |
| Q2_K | 569 GB | DevQuasar |
| Q2_K-XL | 574 GB | teamblobfish |
| IQ3_XXS | 620 GB | 6block |
| Q3_K_M | 652 GB | 6block |
| UD-Q4_K_XL | 850 GB | unsloth — their *smallest*; they publish no 2-bit |
| NVFP4 | 913 GB | nvidia — for vLLM, not llama.cpp |
| Q8_0 | 1672 GB | teamblobfish |
| native (I8 + FP8) | ~1650 GB | deepseek-ai, per the safetensors index |

Against unified memory:

| Nodes | Unified | Smallest V4-Pro that fits in RAM |
|---|---|---|
| 2 | 242 GB | **none** |
| 3 | 363 GB | IQ1_S (337), with nothing left for KV |
| 4 | 484 GB | IQ1_S / IQ1_M — the first sane configuration |
| 5 | 605 GB | Q2_K (569), tight |

**No quantisation makes V4-Pro fit two GB10s.** Even 1-bit is 337 GB against
242 GB. Adding nodes moves that line; picking a different quant does not. And
llama.cpp's multi-node path is RPC over TCP, which does not use the RoCE fabric
this cluster is built around — so more nodes changes the *memory* answer without
changing the "this is not how you serve V4-Pro" answer.

### So the V4-Pro workspace runs it from NVMe, and the quant choice is the disk

337 GB fits a stock 1 TB node with ~175 GB to spare; 569 GB does not fit at all
(~515 GB free once the usual HF cache is accounted for). That single fact is
why the default is 1-bit rather than the more comfortable quantisation you would
pick anywhere else — the alternative is a workspace that cannot be stored.

It also sets the performance ceiling, since mmap means the disk is read per
token: **~48B active params × ~1.63 bits / 8 ≈ 10 GB touched per token** against
an NVMe that reads a few GB/s. Seconds per token. That is *arithmetic, not a
measurement* — nobody has run it, and `provenance: unverified` means what it
says.

`min_unified_gb` is deliberately **32** there, not 337. It is the working set —
shared weights, KV cache, enough page cache for mmap to be worth anything — not
the model size. Writing 337 would be a lie about what the number means.

The cost is stated where it is chosen: this is a 1-bit quantisation of a 1.65T
model, the most aggressive trade in this repo, and unmeasured. **If output
quality matters more than running it at all, the answer is not a different quant
— it is V4-Flash**, which beats V4-Pro on every published agentic benchmark
despite 13B active parameters against 48B.

### Two flags that are load-bearing in opposite directions

- **`--no-mmap`.** [hardware.md](hardware.md) records the community claim that
  it is faster on unified memory, and for every other model here that is worth
  testing. In the V4-Pro workspace it is **fatal**: it means "read all the
  weights into memory", and there are 337 GB of them. mmap is not a tuning
  choice there, it is the entire mechanism.
- **`--n-cpu-moe` / `-ot ".ffn_.*_exps.=CPU"`.** Every x86 MoE guide recommends
  these. They do nothing here. They exist to keep experts in system RAM when
  VRAM is scarce; on GB10 both sides of that split are the same 121 GB.

### Where the fork question landed, again

[#two-node-vllm](#two-node-vllm) declined the Anemll/Stage-C fork because taking
it means inheriting one project's release cadence for every model. That still
holds, and `vllm-2node-deepseek-v4-flash` defaults to upstream — vLLM gained a
dedicated `deepseek_v4` package with NVFP4 fused MoE in 0.22.0 and DSpark
speculative decoding in 0.25.0, so the model no longer *needs* a fork.

What upstream does not have is **`nvfp4_ds_mla`**, the sparse-MLA KV dtype whose
584-byte per-token envelope is the only thing that makes 1M context fit on two
nodes. So the default is 128K on `fp8`, and the 1M path is documented in
`.env.example` as a switch with a stated cost. Asking for 1M on `fp8` does not
fail at startup — it fails later, as preemption, which reads as "the model got
slow" rather than "the context was a lie".

## <a name="glm53-flash"></a>GLM-5.3-Flash: the one model this repo runs on an image it did not choose

[MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks)
is the only published configuration for this model on this hardware, and like
their DeepSeek recipe before it ([#two-node-vllm](#two-node-vllm)) most of it is
model plumbing wrapped around a small amount of genuinely transferable
knowledge. Same treatment: take the part that is knowledge, leave the part that
is one project's operational model.

### The fork question, answered the other way — and why that is not a reversal

[#two-node-vllm](#two-node-vllm) declined `ghcr.io/anemll/dspark-vllm-gx10`
because taking a fork means inheriting one project's release cadence for every
future model. `workspaces/inference/vllm-2node-glm53-flash-exl3` takes
`ghcr.io/miaai-lab/glm-5.3-flash-2x-dgx-sparks:exl3`. The rule did not change;
the question is a different one:

| | DeepSeek-V4 | GLM-5.3-Flash |
|---|---|---|
| Upstream vLLM | **can** serve it | **cannot** serve it |
| What declining costs | ~8–9% decode | the model |
| What the image adds | tuning | two things no flag can express |

Those two things:

- **There is no `exl3` quantisation method upstream.** Registering the name is
  not enough either — the routed experts have to stay packed trellis + `suh` +
  `svh` + `mcg` and run Trellis/MCG kernels, or they expand to BF16 and 164 GiB
  becomes ~640 GiB.
- **GLM-5.3-Flash is NoPE MLA** (`qk_rope_head_dim=0`, `kv_lora_rank=512`) and
  the only sparse-MLA backend on SM12x packs a 656-byte record with a 128-byte
  RoPE section. Stock loads the checkpoint and dies on the first forward with
  `pe_dim must be 64 for fp8_ds_mla`. The overlay zero-pads the 512-d latent
  into that geometry; the QK dot is unchanged.

So the blast radius is one workspace, and the cost of the image going stale is
that one model stops updating — not that every model in the repo is pinned to
someone else's calendar. That is the distinction the original decision was
protecting, and it survives intact.

### EXL3 over NVFP4, which contradicts every other recommendation here

Everywhere else this repo says *prefer NVFP4* — it is native to GB10's
Blackwell FP4 tensor cores, it is smaller **and** faster, and that is the whole
reason llama.cpp is compiled for `121a`. Here it is the wrong choice, on
published numbers rather than on principle. An independent teacher-logit panel,
five cold runs over 25 sealed windows (51,175 positions), KLD(teacher ‖ model):

| Checkpoint | Mean KLD (nats) | Size |
|---|---:|---:|
| TR3 K6 (6bpw) | 0.013723 | 254 GB |
| Official FP8 | 0.020615 | 328 GB |
| **EXL3 4bpw — what we serve** | **0.024555** | **176 GB** |
| NVFP4 | 0.060535 | ~180 GB |

**NVFP4 is ~2.5× the divergence at the same size.** 4bpw matches official FP8 at
54% of the bytes, and it is the only row that leaves two nodes with enough free
memory to hold a KV cache at all. *(Confidence: published panel, not measured
here.)* This does not generalise — it is one checkpoint, one quantiser, one
panel — which is exactly why it is recorded as an exception rather than folded
into the general advice.

### The KV arithmetic is hybrid, and that inverts the usual tuning move

~164 GiB of weights split TP=2 leaves roughly **19 GB of KV per node**, the
smallest budget in this repo — and 1M context allocates on it. The reason is
that this is a hybrid model:

| Piece | Cost | Scales with context? |
|---|---|---|
| Target MLA, 12 layers | packed `fp8_ds_mla`, 656 B/token/layer | **yes** |
| Mamba, 33 layers | window / state | **no** |
| DFlash2 drafter, 5 SWA layers | bf16, ~2 KB/token | window-bounded |

A large fixed floor plus a small slope. So the reflex that is right on a dense
model — *lower `--max-model-len` to free KV* — is wrong here and actively
harmful: the logged pool is roughly concurrency × the cap, so a smaller cap
shrinks the pool while the floor stays put. Reported occupancy on the source
kit: 36k → 16%, 256k → ~25%, 300k → 26%.

### Taken

| From them | Why it matters |
|---|---|
| **`--kv-cache-dtype fp8`, and that it has no alternative** | The SM12x sparse-MLA kernel accepts only packed `fp8_ds_mla`. bf16 KV has **no sparse kernel on this arch**; NVFP4 KV exists on SM12x and is a **dense MHA** kernel. Reading a working NVFP4-KV recipe for another model as evidence it applies here is the trap |
| **A ceiling on `--max-num-batched-tokens`** | 8192-token prefill chunks oversubscribe the GB10 indexer top-k's shared memory and crash a long prompt around 300k. A hardware limit on that kernel, not a throughput preference. The *value* under that ceiling was 1024 here until it was measured — see [#glm53-second-pass](#glm53-second-pass) |
| **`--skip-mm-profiling` with vision on** | vLLM's max-size multimodal dummy profile allocates a worst-case image+video batch at init and OOMs this unified pool before the server answers once |
| **`TORCH_CUDA_ARCH_LIST=12.1a`** | [#two-node-vllm](#two-node-vllm) recorded the `a` suffix as "the first thing to check if a kernel misbehaves" and acted on nothing. This is the workspace where it stops being a note: the EXL3 trellis kernels are built for `sm_121a`, and Blackwell's FP4 instructions are not forward-compatible |
| **Persisting the Triton and TileLang JIT caches on the host** | They live under `/root` on an overlay filesystem and do not survive `docker rm`. Recreating the container re-JITs mid-collective on TP=2 while the other rank waits — for long enough to trip NCCL's 600 s watchdog, which reports a **hang**, not a slow compile |
| **`VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS=1800`** | Same failure from the other side: EngineCore's stock 300 s is shorter than a cold JIT on two ranks, so the stock value turns a slow compile into a reported hang |
| **`VLLM_NO_USAGE_STATS=1` / `DO_NOT_TRACK=1`** | Not a privacy gesture — a crash. The usage reporter shells out to py-cpuinfo, which returns **empty** output on Grace/aarch64 and is then JSON-parsed; the stats thread dies with `JSONDecodeError` in the middle of a healthy boot. Promoted to the shared launcher, because it is a property of aarch64 rather than of this model |
| **`GLM53_SUPPRESS_STOPS_IN_REASONING`, `GLM53_MIXED_PREFILL_CHUNK=skip`** | Their image reads both. The first stops a client `stop` string truncating the server inside the reasoning block and returning `""` with a normal `finish_reason`; the second keeps a peer's prefill out of a step where another sequence is decoding. The second has a visible cost — concurrent cold prefills serialise — and that is the better trade than one long prefill stalling every stream |
| **Not pinning `attention_backend` in the speculative config** | Their strongest single finding. `TRITON_ATTN` is copied from an SM120 recipe and is causal *inside* the draft block on this image: draft position 0 stays healthy, the rest collapse, structured decode goes ~62 → ~29 tok/s and acceptance 0.92 → 0.31, and nothing reports an error |

### Not taken

- **Their launcher's operational model.** It keeps a `.env` on each node and
  ships inner scripts by `scp` before every start. This repo's whole argument
  about two-node serving is that both ranks must be generated from one place
  ([#twonode-lib](#twonode-lib)), so the flags were ported and the launcher was
  not.
- **`NCCL_IB_GID_INDEX=3`.** The interesting one, and the only place where
  reading their recipe produced a **measurement on this cluster** that
  contradicts it. They pin 3, and had to build a preflight to make the pin
  safe, because index 3 is an all-zero entry on one card of some GB10 pairs:
  the launch then survives every check and kills the **worker** rank about a
  minute in with `ibv_modify_qp` errno 61.

  Checked here with the `--gids` mode this prompted (`rocep1s0f0`, ACTIVE):
  **index 3 is populated — and wrong.** It carries the *link-local* RoCE v2
  GID. The routable one, `::ffff:192.168.100.10` with type `RoCE v2`, is
  **index 5**. Their preflight asks only whether the entry is non-empty, so on
  this hardware it would pass and hand NCCL a GID that cannot route between the
  boxes.

  Every IPv4 address is published **twice**, at adjacent indices, once as v1
  and once as v2 — so choosing on the address alone picks the non-routing copy
  half the time. That is three ways to get one integer wrong, which is the
  argument for not choosing it by hand at all: this repo sets
  `NCCL_IB_ROCE_VERSION_NUM=2` and `NCCL_IB_ADDR_FAMILY=AF_INET` and lets NCCL
  select per card. `IB_GID_INDEX=` remains available for the case where a log
  actually shows it choosing wrong, and `gx10-interconnect --gids` flags the
  one combination that works rather than printing a table to squint at.
- **Their CX7 interface and HCA pins**, and pointing NCCL's sockets at the
  fabric. Same reasoning as [#nccl-socket-ifname](#nccl-socket-ifname) and
  [#hosts-split](#hosts-split): rendezvous on the always-up management link,
  data path chosen independently by NCCL over ibverbs. Their own "running on a
  different kit" section is the argument for it — three of their four
  kit-specific fixes are NIC names that this split never has to know.
- **`NCCL_NET_PLUGIN=none`, `NCCL_CUMEM_ENABLE=0`, `NCCL_IB_MERGE_NICS=0`,
  `NCCL_CROSS_NIC=0`, `NCCL_IGNORE_CPU_AFFINITY=1`.** Kit-specific hardening
  with no stated measurement. [#no-speculative-roce-tuning](#no-speculative-roce-tuning)
  applies: a knob without a number behind it is folklore we would then have to
  maintain.
- **`--cap-add IPC_LOCK`.** `--ulimit memlock=-1` is already the mechanism that
  lets the queue pairs pin memory; the capability is the alternative to it, not
  an addition. Two ways of granting the same thing is one more to reason about.
- **`HF_HUB_OFFLINE=1`.** Correct for a launcher that guarantees the download
  first. Ours lets the engine fetch on a cold cache like every other workspace
  here, and `./stage-weights.sh` is the fast path rather than a precondition.
- **Rebuilding the image.** `BUILD=1` on their side compiles ExLlamaV3 for
  `sm_121a`. The published image is public and arm64; building it ourselves
  would mean owning a CUDA toolchain pin for one model.

### Improved on

**Weight staging goes over the cable, and it is a library function.** Each rank
loads from its own disk, so a two-node model has to land twice — and for the
~40–100 GiB checkpoints the other workspaces run, letting each node fetch its
own copy from the Hub is fine, which is why none of them mention it. At 164 GiB
it stops being fine: the second copy is hours of WAN for bytes already sitting
on a machine at the end of a link this repo has measured at 22.7 GB/s. So
`twonode_stage_model` rsyncs `<peer>.cluster` — deliberately the interconnect
address rather than the management NIC every other SSH in that library uses,
because this is bulk transfer and not control traffic
([#hosts-split](#hosts-split)).

**Per-position draft acceptance became a workspace.** Their README quotes
per-position ladders as the evidence for the `TRITON_ATTN` finding, and it is
the only view that distinguishes a weak drafter from a broken mask. This repo
already asserted, in three separate workspace READMEs, that a broken draft path
"costs acceptance and nothing else" — and shipped no way to look.
`workspaces/bench/spec-decode-accept` is that, reading `k` from the metrics so
it covers DFlash2 (k=7) and DSpark (k=5) without configuration.

**And their two ladders are why the verdict is class-aware**, which is the part
that is easy to get wrong from a quick read of their README. Both of these are
medians from the *same healthy server*:

| Class | pos 0 → 6 | aggregate |
|---|---|---:|
| Structured | 0.98 0.98 0.94 0.94 0.91 0.83 0.83 | 0.92 |
| Prose | 0.75 0.58 0.41 0.28 0.16 0.09 0.06 | 0.33 |

**A healthy prose ladder collapses to 0.06 — the same shape a broken mask
makes.** A tool that convicted on shape alone would flag every prose run on a
working server, and a check with false positives gets muted, at which point it
catches nothing. So a mask verdict is returned for the **structured class
only**, and `tests/check_spec_accept.py` asserts that the published healthy
prose ladder comes back clean — the same discipline
[#quality-gate](#quality-gate) applies to the detectors, for the same reason.

### The library grew two hooks, and they are meant to stay narrow

`PRE_EXEC` and `EXTRA_MOUNTS` in `workspaces/lib/twonode.sh` exist because this
image ships one patch it does **not** apply at build time — the video
placeholder alignment — and a patch that must run inside the container before
`vllm serve` cannot be expressed as an argument *to* `vllm serve`.

The narrow form matters. `PRE_EXEC` does not hand the workspace the container's
argv: the library still assembles the serve line, still generates it identically
for both ranks, and splices the snippet in front with
`bash -c "<PRE_EXEC>; exec vllm serve \"$@\""`. The property that stops the
silent mismatched-rank hang is preserved, and a reader still has exactly one
place to look for what the ranks were told. Anything reachable through
`EXTRA_ENV` or `MODEL_ARGS` should go there instead.

### The licence is not this repo's usual one

The recipe is ours. The **weights are not MIT**: the EXL3/TR3 checkpoint is
under ShapleyMCG License 1.0, and the DFlash2 drafter is **CC BY-NC-ND 4.0 —
non-commercial, research and evaluation only**. That is a real constraint on
what the fastest configuration here may be used for, so it is in the workspace
README rather than only in a link, and `SPEC_METHOD=mtp` drops the drafter
entirely at roughly 40% of the decode speed.

### Recorded, not acted on

Their published decode figures, for calibration rather than as a target:
**62.9 tok/s** single-stream and **146.5 tok/s** aggregate across four streams,
structured output, DFlash2 k=7 — against **26.9** on prose on the same server.
That spread is the point: a single "how fast is this model" number is not
meaningful under speculative decoding, because acceptance is a property of the
text being generated.

They also report a boot-time shape warmup (burning the DFlash2 block, sampler
and kpool shapes after `/health` so the first client is not the first JIT on
TP=2). Worth having if the first request turns out to be pathologically slow
here; not ported without measuring that it is.

**Everything from here down is the recipe as it stood at the first pass.** A
second pass over the same upstream — after they spent a fortnight measuring it —
moved two of these defaults and added a correctness fix:
[#glm53-second-pass](#glm53-second-pass).

## <a name="glm53-second-pass"></a>The second pass over the GLM recipe: the flags moved, and one of them was a correctness bug

[#glm53-flash](#glm53-flash) ported that recipe as it stood. Upstream then spent
a fortnight measuring it, and the result is unusually worth re-reading: most
recipe repositories accrete knobs, and this one accreted *receipts* — a P0
profile, four A/B rungs with keep/revert verdicts on each, and two of its own
proposals reverted after they lost. A recipe that publishes its failed
experiments is a better source than one that publishes only its settings, and
three of the changes below exist because somebody measured a thing this repo
had assumed.

The pass also changed two of our defaults and added the only third-party file
this repo vendors.

### `--max-num-batched-tokens` was 1024 here for the wrong reason

The original port carried 1024 across with the note that 8192 crashes a long
prefill — which is true, and is a hardware limit on the GB10 indexer top-k's
shared memory. What it did not say, because upstream had not said it either, is
that 1024 was never *chosen*. It was the value on the far side of a ceiling
nobody had walked up to.

The published ladder, cold prefill, one request at a time, `prompt_tokens` from
the server's own usage block, unique salt so the prefix cache cannot cheat:

| MNBT | 8k | 16k | 100k | verdict |
|---|---:|---:|---:|---|
| 1024 | 772 | 893 | 947 | baseline |
| **2048** | **895** (+16%) | **953** (+7%) | **975** (+3%) | **keep** |
| 3584 | 777 (−13%) | 950 | 929 (−2%) | revert |
| 4096 | 755 (−16%) | 948 | 987 (+4%) | revert |

`2048` is now this workspace's default. The interesting row is **3584**, and it
is interesting because it is the one a reasoning-from-first-principles argument
picks: 3584 is the hybrid page (4×896), so chunk boundaries land exactly on
prefix-cache page boundaries instead of straddling them. It lost anyway. The
reason is on the other side of the model — at a 1024-token chunk the hottest
routed expert is already in top-8 for ~90% of the tokens in it, so a larger
chunk makes the fat-expert fallback hotter, and the `LinearEXL3` reconstruct
loop it falls into costs more than the saved chunks are worth.

The alignment argument was not wrong; it was outweighed, and there is no way to
know that without running it. Which is the general point worth keeping: **an
alignment argument is a hypothesis, not a result.**

The cost of 2048 is real and it is not throughput. With
`GLM53_MIXED_PREFILL_CHUNK=skip` a prefill chunk is a step no decoder gets, so
doubling the chunk doubles the worst-case stall a streaming client sees while
somebody else's prompt goes in. That is the trade, stated so it can be taken the
other way; `ws up vllm-prefill-ladder` is how you re-take the table.

### The K-pool tail overrun, and the first file this repo vendors

Upstream landed a patch that clamps the slot-mapping index to the request's
block-table row. The mechanism:

`KpoolTailSpec` is a **one-block circular scratch** cache — its block-table row
is a single entry. Slot mapping still runs the generic paged Triton kernel,
which computes `block_indices = pos // block_size` and loads
`block_table[req, block_indices]`. The mask guards token validity and nothing
bounds the index against the row width, so for the tail group every token at
`pos >= block_size` reads past that one entry and the kpool seed/update kernels
then write through whatever block id came back.

The symptom is the part that matters here. Most overruns land **inside the
shared pool**, so nothing faults: another layer's indexer is corrupted instead,
on generations of roughly 2k tokens and up. A request that finished is not
evidence its writes were in bounds.

Everything else this workspace needs is already applied inside the overlay
image, so `up.sh` re-runs the image's patches only as a cheap repair and skips
any the image has dropped. This one postdates the published `:exl3` tag, which
makes `[ -f /opt/glm53/… ] || true` exactly the wrong shape: an image without
the file would skip a correctness fix **silently**, which is the failure the fix
exists to prevent.

So `patch_kpool_tail_slotmap.py` is vendored into the workspace (MIT, upstream
`overlay/`), staged to a fixed path on both nodes so the mount string is
identical on both ranks, and run inside the container as a **mandatory** step —
if it does not apply, the container exits. `--restart unless-stopped` then loops
it, which is noisy on purpose: `docker logs` names the reason on every attempt,
and a loud restart loop is cheaper than a server quietly corrupting its own
indexer. `up.sh` also refuses to start at all if the peer copy fails, because
half the ranks clamped and half not is worse than neither.

This repo vendors nothing else, and the bar for the next one should stay here:
a correctness fix, fail-closed, idempotent, that the upstream artefact does not
carry.

### The drafter shards now, and that is a memory decision

`draft_tensor_parallel_size` went 1 → 2. Upstream's own evidence is weak on its
face — idle prefill and both decode classes *held* against rank-0-only, which is
a no-regression result rather than a win — and on most workspaces that would not
be enough to change a default. Here it is, for a reason their note does not
give:

**vLLM sizes one KV pool for the whole server.** A ~2.3 GiB drafter parked
entirely on rank 0 does not cost rank 0 2.3 GiB; it costs *both* nodes 2.3 GiB,
because the pool is bounded by the tighter rank. Sharding it hands ~1.15 GiB
back to a KV budget of about 19 GiB — the smallest in this repo, on the
workspace where memory is the binding constraint and everything else is
downstream of it.

So the memory argument carries it and the latency evidence only has to show no
harm — which it does: their A/B has idle cold prefill going 895 → 938 tok/s at
8k and 975 → 997 at 100k with both decode classes unchanged, and they still
describe the result as *held* rather than as a win. Reading it as a speed
finding would be over-reading one boot; reading it as "no harm, and ~1.15 GiB
of KV back" is what the numbers support. `DRAFT_TP=1` rolls it back if a draft
step ever shows up as latency on a cable that is busy with something else.

### Bearer auth belongs to the library, and it goes in the environment

vLLM reads `VLLM_API_KEY` natively as the fallback for `--api-key`. That is not
a stylistic preference between two ways of passing a secret: `--api-key <token>`
puts it in argv, which means `ps`, the container's command line, and the
`non-default args` line vLLM logs at every boot. The environment variable puts
it in none of them.

It went into `workspaces/lib/twonode.sh` rather than the GLM workspace, on the
same reasoning as `VLLM_NO_USAGE_STATS` before it ([#glm53-flash](#glm53-flash)):
it is a property of vLLM, not of this model. Empty stays the default — these
servers listen on a private cluster and every workspace here assumes that — and
the bench workspaces read the same value from `API_KEY`.

### Two knobs recorded as knobs, not as advice

- **`CG_ESTIMATE`** (`VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS`). vLLM subtracts
  a *predicted* CUDA-graph footprint from the KV pool before capturing; where
  the prediction overshoots, `0` hands that memory back with graphs still on.
  Upstream ships it defaulted to the upstream value and publishes no delta. It
  is exposed here at that same default and named in `.env.example`, because on
  the workspace with the least headroom in the repo a knob that returns KV is
  worth knowing about — and because guessing at an under-estimate on *this*
  workspace is how you turn a served model into a startup memory failure.
- **`EXL3_MOE_ROW_TILE` and `EXL3_TEMP_ROWS_FUSED`** are *not* exposed, and that
  is the finding rather than an omission. Upstream proposed both as the fix for
  the fat-expert fallback, implemented both, measured both, and reverted both:
  GPU row-tiling cost −61% at 8k, and raising the fused temp rows to 1024 cost
  −13% to −24% across the ladder. Recording a negative result is worth more here
  than shipping the knob, because the knob's name makes it sound like a free win.

### The boot-shape warmup got ported, default off — which is the earlier decision resolved, not reversed

[#glm53-flash](#glm53-flash) recorded the warmup as "worth having if the first
request turns out to be pathologically slow here; not ported without measuring
that it is." That is still the right test and it still has not been taken, so
`warmup.sh` ships as a separate script that nothing calls automatically. What
changed is that the script stopped being plumbing and became three pieces of
knowledge worth having on disk even unused:

- **The BLOCK ladder is model-specific arithmetic.** This image sizes the draft
  block as `min(256, next_pow2(scheduled_tokens + 1 + k))`. At k=7 that is +8, so
  **BLOCK 8 is unreachable** — the smallest schedule is one token, which is 9,
  which rounds to 16. A DSpark recipe's ladder is built on `next_pow2(s + 6)`;
  copying it warms shapes this server never asks for and misses the ones it does.
- **The sampler compiles three variants and the obvious warmup hits one.** The
  top-k/top-p kernel specialises on which tensors are `None`. This checkpoint's
  `generation_config.json` stamps `top_p=0.95`, so a request that sets only
  `top_k` still arrives with a p tensor and compiles `k+p` — the `k-only`
  variant is unreachable by any natural request. `top_p=1.0` and `top_k=0` are
  the only way to ask for the other two on purpose.
- **A rung that is not tokenize-verified warms the wrong block and reports
  success.** One token of tokenizer drift pushes `s` past a power of two.

And the postcondition is the part that makes it a check rather than a hope:
every warmup request can return 200 while a variant was never compiled, because
the arm took a path that already had a cache entry. The only direct evidence is
the Triton cache itself — one `.ttir` per compilation, and which of `%K` / `%P`
it references says which combination it was built for.

What would flip it on: a measured first-request latency here that a second
identical request does not have.

### The cold-prefill protocol became a workspace, and the reason is one number

`workspaces/bench/vllm-prefill-ladder`. Every bench in this repo measured
**decode** — `vllm-bench-serve` throughput, `spec-decode-accept` the drafter —
and on a long-context server that is not where the time goes. A 100k-token
prompt spends ~100 s in prefill before emitting a character.

The reason it is a *check* and not a stopwatch is a failure upstream documented
against itself: rerunning a "cold" ladder without changing the prompt took TTFT
from **10.3 s to 1.9 s**. Every serving workspace here runs with
`--enable-prefix-caching`, so the second send of a prompt is not a prefill at
all — and a 5× improvement produced by nothing looks exactly like an
optimisation that worked. This is the most efficient way there is to convince
yourself a flag helped.

Two things port from their protocol and one is a detail people get wrong:

- **The salt goes first.** Prefix caching hashes a *prefix*, so a salt appended
  at the end shares every preceding block with the last run and the request is
  cold in name only. Ahead of the shared text, the first block differs and
  nothing after it can match.
- **The counters decide, not faith.** `vllm:prefix_cache_hits_total` is read
  before and after every request; a cold rung reporting any hits is `INVALID`,
  not fast. `prompt_tokens` comes from the server's `usage` object rather than
  an estimate, so two runs of "the same" ladder are the same amount of work.

**And reuse is reported against a page model rather than as a percentage**,
which is where this repo added something. Hits are block-aligned: a 7.7k-token
conversation reuses `floor(7717/3584) × 3584 = 7168` tokens and computes the
remainder on every turn. Their published follow-up rows are **7168 / 10752 /
14336** hits at 8k / 12k / 16k — exactly two, three and four whole pages, which
is the strongest available evidence that the page model is the right model at
all, and it is the fixture the offline test asserts against. "93% hit" reads as though 7% is being lost and sends
somebody looking for it; `hit_efficiency` — measured over what the page model
*allows* — reads 1.00 and says the true thing. When it is not 1.00 the tool
prints the page sizes **consistent with the observation, as a set**, because one
sample genuinely cannot separate 3584 from 896 and naming one would be a guess
wearing a measurement's clothes.

`tests/check_prefill_ladder.py` holds the published healthy ladder as a fixture
that must come back clean, for the same reason [#quality-gate](#quality-gate)
and [#glm53-flash](#glm53-flash) do: a check that fires on a working server gets
muted, and a muted check catches nothing.

### Their GID handling moved toward ours, and the earlier finding stands

[#glm53-flash](#glm53-flash) declined `NCCL_IB_GID_INDEX=3` and recorded a
measurement that contradicted it: on this hardware index 3 is *populated and
wrong* — it carries the link-local RoCE v2 GID, while the routable
`::ffff:192.168.100.10` is index 5. Their preflight asked only whether the entry
was non-empty, so it would have passed here and handed NCCL an unroutable GID.

They have since split the pin per rank (`HEAD_GID` / `WORKER_GID`), which fixes
the case where two cards need different indices. It does not change the reading
above: the preflight still only tests non-empty, so it still passes on an entry
that cannot route. Every IPv4 address is published twice at adjacent indices,
once as v1 and once as v2, and there is no way to distinguish them by emptiness.

So the decision holds — `NCCL_IB_ROCE_VERSION_NUM=2` plus
`NCCL_IB_ADDR_FAMILY=AF_INET`, and NCCL selects per card — and
`gx10-interconnect --gids` remains the tool that names the working combination
rather than printing a table to squint at. Worth recording that upstream moved
in the same direction, from a different starting point.

### Not taken, second pass

- **The ABLIT overlay.** Upstream restored an opt-in load-time hook that edits
  `self_attn.o_proj` at weight load along a published refusal direction — an
  abliteration, defaulted off on their side. Not ported. It is not a serving
  capability and it is not what this repo is for: everything else in
  `workspaces/` makes a model run on this hardware, and none of it changes what
  the model will say. Somebody who wants it can run their image with `ABLIT=1`;
  it does not need to be a flag in a cluster recipe.
- **`MODEL_FALLBACK` and `HF_HUB_OFFLINE=1`.** Both are correct for a launcher
  that guarantees the download itself. Ours lets the engine fetch on a cold
  cache like every other workspace here, with `./stage-weights.sh` as the fast
  path rather than a precondition — unchanged from the first pass.
- **The P3–P8 improvement plan** (KDA autotune, a dense short-context MLA path,
  fp8 for the non-routed GEMMs, a second CX7 rail, UMA KV offload). Upstream
  stopped after P2 and says so. Every one of those is a change to the image or
  the hardware rather than to a recipe, and this repo does not build the image.

### Recorded, not acted on

Their P0 profile, because it changes what a slow prefill *means* here and would
otherwise have to be re-derived:

| Where a 1.08 s prefill chunk goes | Share |
|---|---:|
| MoE forward (fused `exl3_moe` + fat-expert `LinearEXL3` loop + scatter) | **63%** |
| `aten::mm` — shared experts, dense, lm_head | 10% |
| NCCL all-reduce over the cable | 7% |
| KDA / GDN scan, 34 layers | ~6% |
| Sparse MLA prefill + indexer, 11 layers | 4% |

The instinct on a two-node server is that the cable is the problem. It is 7%.
The MoE is nearly two thirds, of which a large part is a **host sync** —
`.nonzero().tolist()` in the fat-expert fallback, 29% of CPU time in one capture
— and that combination is memory-bound rather than compute-bound: ~34 TFLOPS
combined, about **14% of the two GB10s' BF16 peak**. There is headroom in this
model on this hardware, and it is not on the interconnect.

Also recorded: their aggregate prefill figures at the ladder's winning setting
(~895 tok/s at 8k, ~975 at 100k, ~941 at 300k), for calibration when
`ws up vllm-prefill-ladder` is first run on this cluster.

## <a name="quality-gate"></a>"Is it up" and "is it fast" are not "is it right", so there is a third check

`make bench` measures the hardware. `ws up vllm-bench-serve` measures a model
server's throughput ([#serving-bench](#serving-bench)). Both can be green on a
server that is returning garbage, because the failures that produce garbage are
in the *serving* layer — the scheduler, the speculative decoder, the reasoning
parser — and none of them moves a tok/s number:

| Symptom | Layer |
|---|---|
| Reply opens mid-word, or reproduces prompt/tool text | Spec-decode placeholders attached to the last chunk of a cold chunked prefill |
| `""` returned, the whole token budget billed | Reasoning outran `max_tokens` before `</think>`; the parser emits neither field |
| Output drifts into another script, or recycles a phrase forever | A reasoning runaway |
| `<｜begin▁of▁sentence｜>` in the content | Detokenizer or template fault |

Everything below follows from one observation, which is the reason this is a
workspace and not a `curl` in a runbook.

### A smoke test cannot find any of them, and the reason is structural

Both conditions that produce these failures are ones a smoke test does not
create:

- **Cold prefill.** The corruption attaches to the final chunk of a long
  *first* prefill. **A prefix-cache hit never fails.** So asking the same
  question twice makes the problem look self-healing — and the clean second
  answer is the one you believe.
- **Concurrency.** Several appear only with more than one sequence in flight,
  because that is when the scheduler does the thing that breaks.

So the gate manufactures both. A unique nonce goes at the **front** of every
prompt, which invalidates the whole prefix-cache block chain behind it; the
filler is long enough to be genuinely chunk-prefilled rather than swallowed in
one pass; and the whole thing runs a concurrency ladder.

Order is the entire trick, and the natural way to write it is wrong: the same
nonce appended at the *end* shares every block but the last, which is a warm
request wearing a disguise. The nonce doubles as the prompt-echo sentinel,
which is one fewer string to keep in step.

**And then it checks.** The run reads `vllm:prefix_cache_hits` and says so if
the hit rate was not near zero, because a gate whose central claim — *these
were cold* — is never verified is a comment. The same pass reports
`vllm:num_preemptions` (the timings describe a server under memory pressure)
and speculative acceptance.

### Two directions of failure, and the second one is why the detectors are tested

A detector that stops catching things turns the gate green forever, which is
worse than not having a gate, because a green gate is trusted. A detector that
starts flagging clean output gets the gate muted, and a muted gate catches
nothing. `tests/check_detectors.py` asserts both directions — including that an
ordinary lowercase opening is *not* reported as a truncated word.

That test is in `make check` and CI. It fits the existing tier
([#testing-is-tiered-because-the-hardware-cannot-be-faked](#testing-is-tiered-because-the-hardware-cannot-be-faked))
exactly: the serving half needs a GB10 and a loaded model, the detectors are
pure functions over text and need neither.

### The empty reply is checked first and separately

Empty text contains no special tokens, no non-Latin script and no leaked
markup, so it passes every other detector *trivially*. A gate without an
explicit check reports success on a server that answers nothing.

It is also not usually an empty generation. With reasoning enabled and a budget
that runs out before `</think>` arrives, the reasoning parser emits neither
content nor reasoning, and the caller is billed for the lot. The rate is a
function of the budget — reported at temperature 0.5 with thinking on: 256
tokens → 83% empty, 512 → 50%, 768 → 17%, 1024 → 0 of 18. So `MAX_TOKENS`
here is a **detector setting**: below ~1024 the gate is measuring its own cap.

### Loop or heavy tail — same symptom, opposite fixes

`finish_reason=length` with nothing useful in `content` has two causes:

| | What it is | Fix |
|---|---|---|
| heavy tail | still saying new things, just a lot of them | raise `max_tokens` |
| loop | recycling what it already said, forever | raising `max_tokens` changes the bill and nothing else |

They are indistinguishable to the caller, so the verdict is computed: the
fraction of word 8-grams in each window that have not appeared earlier in the
same trace, judged over the reasoning stream where a runaway actually lives.

**Not block uniqueness**, which is the instrument everyone reaches for first
and which reports these loops as healthy text. The loops that matter are
*templated* rather than verbatim — a small set of stock phrases recombined with
one element varying each pass. On the traces this method comes from, unique
120-character blocks read 22% / 92% / 66% while unique word 8-grams read 3.4% /
4.0% / 2.8% on the same text. Recycled phrases are the signal; recycled bytes
are not.

Two calibration details are load-bearing and both are in the test fixture. The
verdict requires novelty to collapse **and stay collapsed to the end** — a
single low window is a long verbatim quote, and calling that a loop teaches
people to ignore the verdict. And the varying element must come from a small
pool: a fixture with a monotonically increasing counter mints a genuinely novel
8-gram every pass and never converges, which is also the correct answer, since
a model still producing values it has never produced before is not looping.

## <a name="dspark-1m-recipe"></a>What was ported from the 1M/NVFP4 DSpark recipe, and what was not

[tonyd2wild/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark](https://github.com/tonyd2wild/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark)
is the second published two-node GB10 serving configuration this repo has taken
from, after [#two-node-vllm](#two-node-vllm). The split is different this time.
Its *configuration* is a fork-pinned, model-specific stack this repo already
declined once. Its **operational findings** are not model-specific at all —
they are about what a serving benchmark fails to notice, and they are the most
valuable thing in it.

### Taken

| From them | Why it matters |
|---|---|
| **The cold-prefill reproducer method** — bust the prefix cache with a per-request nonce, then score the output | The whole basis of `vllm-quality-gate`. Their measurement is the argument: 11 of 12 cold prefills failed on a config where **0 of 19 warm requests** did. A gate that does not force cold is testing the case that never fails |
| **The failure taxonomy** — special-token leak, mid-word start, prompt echo, script drift, empty-with-tokens-billed, templated loop | Each is a named, cheap, textual check. Together they are the difference between "the server is up" and "the server is right" |
| **Loop vs heavy tail from novelty**, and the warning that block uniqueness gets it backwards | Recorded in full at [#quality-gate](#quality-gate). The trap is the valuable half: their first instrument said the runaways were not loops, and it was wrong |
| **`empty` is a separate check**, with the max-tokens ladder behind it | It passes every other detector trivially. 256 → 83% empty, 1024 → 0 of 18 |
| **Read `usage.completion_tokens` from a non-streamed reply** | Under spec decode a server emits at most one SSE chunk per decode *step*. Counting streamed deltas measures steps/s and under-reports by the acceptance length — they measured 14.7 vs 60.1 tok/s on the identical request |
| **Draft acceptance as the first diagnostic**, now live in `bench-tui` | A broken draft path costs acceptance and *nothing else* — the target still verifies every token, so output stays correct at half speed. They spent the investigation proving it was not the weights, not the config, not contention: 25.7% → 60.2% acceptance, 32.7 → 55.4 tok/s, from twelve draft tensors a loader silently skipped |
| **Cross-node clock asymmetry**, now flagged by `gx10-top` and `bench-tui` | A rebooted node sat at 22 W / 2086 MHz beside a healthy one at 42 W / 2502 MHz; TP is lockstep, so the pair ran at 42 tok/s instead of 83 with *acceptance and config unchanged*. Detection is ported; the `nvidia-smi -lgc` remedy is not, because `-pl`/`-ac` are `N/A` on GB10 ([hardware](hardware.md)) and this repo has not measured whether `-lgc` differs |
| **`reasoning` vs `reasoning_content`** | The runtime emits the first, OpenAI-compatible clients read the second. A client that knows only one renders "Thinking…" forever and reports zero reasoning |
| **The `num_speculative_tokens` traps** | On the fork lineage, omitting it yields `k=1` rather than the checkpoint's 5 — a server that boots, speculates one token per step and says nothing. And `k=7` from the model card is rejected at boot on one image and crashes on first generation once that guard is patched out |
| **Speculative buffers are allocated on the first real request**, not at boot | So a `--gpu-memory-utilization` slightly too high boots, passes a smoke test, serves a few requests and then dies under traffic. Every quick check says it is fine. Noted at the flag in `vllm-2node-deepseek-v4-flash` |

### Not taken

- **The patch stack** (five numbered patches, a three-stage NVFP4 image, a vLLM
  overlay tree). Fork- and version-specific, against a vLLM this repo does not
  run. [#two-node-vllm](#two-node-vllm) already declined that trade and nothing
  here changes it.
- **The bind-mount patching pattern** — injecting a patched `.py` over the
  container's site-packages. It has a failure mode their own README documents:
  the launcher syncs the compose and env files to the worker but *not* the
  mounted file, so the worker silently runs unpatched and you debug a
  half-fixed cluster. This repo's launcher builds both ranks' argv in one place
  ([#twonode-lib](#twonode-lib)) precisely to avoid that class of bug; adding a
  host path that must exist identically on both nodes puts it straight back.
- **`draft_sample_method`.** Carried in the flags because the published recipes
  carry it, documented as doing nothing. Their own correction: the DSpark
  proposer only populates draft probabilities under
  `VLLM_DSPARK_EXPORT_DRAFT_PROBS=1`, so greedy and probabilistic take the same
  rejection-sampler path. The widely-repeated "probabilistic beats greedy, 49
  vs 32 tok/s" claim was withdrawn by its authors after re-measurement — worth
  recording so nobody re-derives it here.
- **`k=3` as the garble fix.** Also widely repeated, also withdrawn: measured,
  `k=3` failed 10 of 10 cold prefills. It costs ~24% of decode and fixes
  nothing. This is the strongest argument for owning a reproducer rather than
  inheriting a folk remedy.
- **`NCCL_IB_MERGE_NICS=1` and a pinned dual-HCA list.** Their measurement is
  98 → 161 Gb/s, +64%, and it does not apply here: this cluster already
  measures **22.7 GB/s ≈ 181 Gb/s** with the device list *unpinned*
  ([#one-cable-two-partitions](#one-cable-two-partitions)). Their 98 Gb/s is
  almost exactly the "one partition only" row in
  [connect-cluster](runbooks/connect-cluster.md#reading-the-result) — so this
  is the same finding from the other side, and useful as corroboration rather
  than as a knob to add. [#no-speculative-roce-tuning](#no-speculative-roce-tuning)
  still applies to the pinning half.
- **Their context and concurrency numbers** (1M/1.5M, `max_num_seqs` 12,
  `nvfp4_ds_mla`). They belong to the fork image; ours are derived from the
  KV arithmetic of an fp8 checkpoint on two nodes and are documented where
  they are used.

### Improved on

Their gate scripts are separate one-off tools (`agent_sanity_bench.py`,
`replay_hermes.py`, `loop_detector.py`, `garble_tap.py`), each pointed at a
hardcoded lane and each carrying its own copy of the detectors. Here it is one
workspace with one detector set, a discovered model id, and an exit status —
so it composes with `ws` like everything else and can gate a deployment.

The detectors also gained an offline test in CI, which the originals do not
have. That matters more than it sounds: a text detector is exactly the kind of
code that keeps running and quietly stops matching.

### Recorded, not acted on

- **Reasoning quality is a measurement setting, not a model property.** On
  their execution-graded harness, thinking off scored 12/20 one-shot and
  thinking on scored **11/20** — worse — because every one of the nine failures
  was `finish_reason=length` at an 8K cap. Retried with 32K, thinking on scored
  **20/20**. Any evaluation run here must report the thinking setting and retry
  length-capped failures, or it is measuring its own cap. This is why the gate
  treats `max_tokens` as a detector setting.
- **`sm_121a` again.** They compile with `TORCH_CUDA_ARCH_LIST=12.1a`, as
  MiaAI-Lab did. [#two-node-vllm](#two-node-vllm) already recorded it; a second
  independent recipe using the `a` suffix strengthens it as the first thing to
  check if a FlashInfer or CUTE-DSL kernel ever misbehaves here.
- **Acceptance is content-driven, so a single headline number is not a
  measurement.** Measured on one patched server: structured/repetitive 78.3%,
  code 68.7%, prose 33.7%. This is why `vllm-quality-gate` sends three prompt
  shapes rather than one, and why the bench view flags only *very* low
  acceptance rather than pretending there is a universal good value.

## <a name="persistence-latch"></a>Persistence mode turns an OOM-killed CUDA process into a permanently wedged counter

`nvidia-smi` on one node reported **96% GPU utilisation for six days with no
compute process on the GPU**. `--query-compute-apps` was empty, `pmon` listed
nothing, `docker ps -a` was empty, and the only process holding `/dev/nvidia*`
was `nvidia-persistenced` itself. The number was not describing anything.

**How to tell a wedged counter from real load**, because "96%" is exactly what
a busy GPU looks like:

- **It does not move.** `nvidia-smi -q -d UTILIZATION` reported 71 samples over
  14 s with min = max = avg = 96%. Real load varies sample to sample — the
  two-node training run measured later on the same hardware swung 33→48 W in
  step with 90–96%.
- **The power does not match.** 18.5 W at a claimed 96%. The idle baseline
  recorded in [#history-timer](#history-timer) — 0%, ~5.3 W, 208 MHz — is what
  the box actually returned to once the latch was cleared: 4.8 W, 208 MHz.
- **The clock is pinned high anyway.** 2528 MHz with `Idle: Not Active`. The
  driver believed the device was in use, which is why DVFS never wound it down.

So the tell is the *pair*: a utilisation figure that never varies, next to
power and clocks that disagree with it. Either number alone is unremarkable.

### What put it there

From `kern.log`, which survived because it had not rotated — the journal had
not, so `journalctl` alone would have shown nothing:

- **day 1, 20:51** — the driver starts failing allocations: `NVRM: Check
  failed: Out of memory [NV_ERR_NO_MEMORY] returned from
  _memdescAllocInternal(pMemDesc) @ mem_desc.c:1359`. Thirty of these follow
  over the next thirteen hours.
- **day 1, 21:34 and day 2, 09:00** — two `python3` processes, each inside a
  container (`task_memcg=/system.slice/docker-<id>.scope`), killed by the
  global OOM killer. The second was 307 GB virtual, **41.7 GB resident**, on a
  124 GB box.
- **day 2, 10:06–10:08** — the storm continues and takes the desktop session
  with it: `pipewire`, `dbus-daemon`, `wireplumber`, `systemd --user`.

Host memory *is* GPU memory here, so a container's CUDA allocations do not hit
a framebuffer ceiling and fail politely — they drive the **whole box** out of
memory, and the kernel resolves that with `SIGKILL`. A process killed that way
never tears down its CUDA context.

### Why it survived six days, and why that is our own setting

Normally the driver deinitialises the device when its last client closes, and
whatever a dead client left behind goes with it. `nvidia-persistenced
--persistence-mode` exists precisely to stop that from happening — and the
drop-in at `/etc/systemd/system/nvidia-persistenced.service.d/` sets it,
overriding the `--no-persistence-mode` in NVIDIA's own unit.

That is the right default (it keeps device init off the critical path of every
job) and it is also the mechanism that made a dead container's state permanent.
Persistence mode does not distinguish "keep the device warm for the next job"
from "keep the wreckage of the last one".

### The fix is a daemon restart, not a GPU reset

```
sudo systemctl restart nvidia-persistenced
```

The journal shows the whole cycle, and the last line is the one that matters:

```
device 000f:01:00.0 - persistence mode disabled.
device 000f:01:00.0 - NUMA memory offlined.
...
device 000f:01:00.0 - registered
device 000f:01:00.0 - persistence mode enabled.
device 000f:01:00.0 - NUMA memory onlined.
```

Releasing the handle forces the deinit the OOM kill never got. Utilisation went
to 0%, clocks 2528 → 208 MHz, power 18.5 → 4.8 W. Note that on GB10 this is a
NUMA operation: the device's memory is host memory, so persistenced onlines and
offlines a memory node rather than touching a framebuffer.

**`nvidia-smi -r` is the wrong reflex here** and is what most search results
will tell you to run. This GPU is part of the SoC, not a resettable PCIe card:
the driver does not expose `GPU Reset Status` in `nvidia-smi -q` at all, and
`gpu_reset_status.reset_required` comes back as *"not a valid field to query"*.
Do not go looking for a reset path that the hardware does not have.

### What it costs to not notice

Roughly 14 W burned continuously at idle, and — worse — every tool that reads
`utilization.gpu` lies for as long as it lasts. `gx10-top`, `gx10-status` and
any dashboard built on NVML all report a busy GPU, so the one signal you would
use to ask "is anything running on this node?" is the signal that is broken.
The `on-GPU` row is the cross-check: it reads `idle, no GPU procs` from
`--query-compute-apps`, which stays honest because per-process accounting is
unaffected.

## <a name="storage-classes"></a>Disk pressure is a classification problem, not a `df` problem

`gx10-status` already printed free space and the size of the HF cache. That
looked like enough until the numbers were added up on odysseus at 660 GB used:

| | measured |
|---|---|
| `~/.cache/huggingface` | 175 GB — the only line `gx10-status` showed |
| `/var/tmp` | 303 GB — training checkpoints |
| `/var/lib/apport` | 63 GB — core dumps |
| `/var/lib/docker` | 44 GB |

**485 GB was invisible.** Not hidden — just in directories nobody `du`s, none of
which `hf cache scan` can see, because they are outside the HF cache by
definition. The tool that was missing is not another `df` wrapper.

### The class is the product

The obvious design is "rank directories by size and offer to delete them", and
it is wrong here, because the largest thing on the disk is almost always the
thing you must not touch. So every row `gx10-storage` prints carries a class,
and the class — not the size — decides what `--reclaim --apply` may remove:

| class | may `--apply` remove it? | why |
|---|---|---|
| `weights`, `job` | **no** | expensive to re-fetch, and a script cannot know you are done with it |
| `image` | **no** | a docker image built here exists in no registry — `docker pull` cannot undo the delete |
| `crash`, `cache`, `system` | yes | regenerable by definition — deleting one costs a recompile or a re-pull |
| `fixed` (swap) | never a candidate | reported only so the arithmetic adds up |

`hf cache delete` is interactive for exactly this reason, and this tool inherits
the stance. A tool that frees 300 GB by deleting a checkpoint you had not
finished with is not a tool, it is an incident.

### Weights are detected by content, not by location

The 303 GB in `/var/tmp` is model data that no weight-aware tool could see,
because "model weights live in the HF cache" is an assumption, not a fact. So
the scan looks for `*.safetensors`, `*.gguf`, `*.pt` and `pytorch_model*.bin`
under the places jobs actually write — `/var/tmp`, `/opt`, `~/models`, `/raid`,
`/mnt`, `/srv` — and classes whatever holds them as `weights` wherever it sits.

Hits roll up to the topmost directory inside the scanned root, because reporting
40 shard directories separately is a list, not an answer. That rollup is
**relative to the root, not a fixed component count**: the first version kept
four path components, which is right for `/var/tmp/<job>/<shards>` and silently
wrong for every other root — and silently wrong rather than empty, which is the
worse failure. `tests/check_storage.py` asserts the rollup for this reason.

### It states what it could not explain

The report ends with `accounted for: 604 GB of 706 GB used (102 GB elsewhere)`.
That line is not politeness. A report that silently explains 60% of a disk sends
you looking in the wrong place with full confidence — which is precisely the bug
that made this tool necessary. The same rule governs unreadable directories: with
no passwordless sudo the root-owned rows are labelled **UNMEASURED, not zero**,
because a 63 GB directory reported as `0 GB` because `du` could not open it is
the exact silent-wrong-answer this repo keeps finding on this hardware.

### `docker system prune -af` was in the auto tier, and that was a bug

It shipped that way and was wrong within the hour. Running it on this cluster
found three of six images — `ar-deberta:ctl`, `ar-deberta:spark`,
`split-inference:spark`, 65 GB — built locally and pushed nowhere. "Regenerable"
was doing unearned work: a *cache* is regenerable by a command, whereas those
are regenerable only if the Dockerfile still exists and you have an hour, which
is not the promise the `cache` class makes.

`RepoDigests` is the exact discriminator and the name is not. An image ever
pulled from or pushed to a registry has one; a `docker build` output has none.
`ar-deberta:spark` is indistinguishable from a public image by its tag alone, so
any heuristic on the string would have kept the bug.

So the docker row is now classed by what is actually in it: `cache` when every
unused image can be re-pulled (a prune then costs a download), `image` — held
back, never automatic — the moment one cannot. The build cache is split into its
own row and stays in the plan either way, because that genuinely is regenerable
by a command.

The general lesson, which is why this is written down rather than just fixed:
**"can a script recreate this" is the question, not "is this an artifact".** Both
of the categories this tool holds back — weights and locally-built images —
failed that test while looking like caches.

### It shares the models role's floor

`gx10-storage` compares free space against `model_min_free_gb` — the same number
`roles/models` projects against before it will download anything. Two thresholds
would eventually disagree, and the failure mode of that is `make models`
refusing to run right after a storage tool said there was plenty of room.

### The docker row uses docker's figure, not the directory's

`/var/lib/docker` is 44 GB on disk and only 20 GB of that is reclaimable —
running containers are using the rest, and `prune` will not touch it. Planning
around the directory size promises space that cannot be returned. The cost is
one visible inconsistency: docker reports SI GB and everything else here is
binary, so the row can print one GB below what `docker system df` says. Byte
correctness wins, because the byte count is what the floor arithmetic needs.

### Two hardware-specific findings that came out of building it

**A core dump is a RAM image, and RAM here is 121 GB.** Measured: five cores in
`/var/lib/apport/coredump` totalling 62 GB, the largest **41 GB**, from a
crashed `python3.12`. On a normal server a core dump is an annoyance; on unified
memory it is a full-size copy of the model you were serving, written to the same
NVMe that holds the weights *and* the swap file. `ulimit -c` says `0` and is
irrelevant — that is the login shell's soft limit, while systemd's
`DefaultLimitCORE` is `infinity` and what crashes here is a unit or a container.
Apport ages them out after `3d`, so it is not a leak: it is three days of the
disk being smaller than you think, starting the moment something OOMs. Related:
[persistence-latch](#persistence-latch), which is what the *same* OOM kill
leaves behind on the GPU.

**`/var/tmp` never expires.** Ubuntu ships
`#q /var/tmp 1777 root root 30d` — commented out — in
`/usr/lib/tmpfiles.d/tmp.conf`. Anything a job leaves there is permanent, and it
is the natural place for a run to write checkpoints. The repo does **not** ship a
drop-in to enable that rule: a timer that deletes files under a long training run
is a policy decision for whoever owns the box, so
[manage-storage](runbooks/manage-storage.md#var-tmp) gives the one-line command
and says plainly when not to run it.

### What was not done

**No daemon, no exporter, no history.** Same bargain as `gx10-status`: on
unified memory every resident MB is model capacity. Disk pressure also moves in
hours, not seconds, so `make verify` asserting the floor and a script you run
covers it. If you want it in Prometheus, `node_exporter` already exports
`node_filesystem_avail_bytes` — what it cannot export is the *class*, which is
the half that matters.

**Both verify checks are `required: false`.** A box deliberately packed with
weights is full, not broken. Failing the whole health check for that would train
people to ignore `make verify`, which costs more than the warning is worth.

## <a name="nemotron35-lightning"></a>Nemotron 3.5 Lightning: the checkpoint that proved "SGLang cannot serve NVFP4" was a claim about the wrong noun

[MiaAI-Lab/Nemotron3.5-Lightning-DGX-Spark-RTX-5090-6000-PRO](https://github.com/MiaAI-Lab/Nemotron3.5-Lightning-DGX-Spark-RTX-5090-6000-PRO)
is the third published DGX Spark serving configuration this repo has taken
from, after [#two-node-vllm](#two-node-vllm) and
[#dspark-1m-recipe](#dspark-1m-recipe). It is also the first one that made this
repo **delete** something it had written down as a fact.

### The correction, which is the most valuable thing in the port

[workspaces/README.md](../workspaces/README.md) carried a matrix row saying
**SGLang cannot run NVFP4**, with a reason: a quantised `lm_head`. That
observation was real — it was measured on `unsloth/Qwen3.8-27B-NVFP4`, and
`sglang-qwen3.8-27b-gguf` exists because of it. What was wrong was the *noun*.
It is a property of **that checkpoint**, not of the engine, and the matrix
stated it as an engine capability.

NVIDIA's `NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4` has day-0 SGLang
support on GB10, with a published operating point and a measured allocation
table. Both halves of the row are now true at once, so the matrix says
**checkpoint-dependent** and names both cases.

The general lesson, which is why this is a section and not a one-line diff:
**a negative result measured on one checkpoint is not a capability claim about
an engine.** This repo's matrix is one of its most-read tables, and it was
confidently steering people away from a configuration that works.

### Two workspaces for one model, and the split is about what can be measured

| | `sglang-nemotron35-lightning-nvfp4` | `vllm-nemotron35-lightning-nvfp4` |
|---|---|---|
| Provenance | the published DGX Spark operating point, with the allocation table behind it | a published DGX Spark vLLM run, plus this repo's conventions |
| Context | the full **1M** window, as measured | 256K by default |
| Image | `lmsysorg/sglang:dev-…` — a **dev** tag | `vllm/vllm-openai:v0.27.1` — a **release** tag |
| Acceptance | accept **length** only | the **per-position ladder** |
| Bench + gate workspaces | partial | all of them |

Not a preferred and a fallback. This is a model with **three** published
drafters, and choosing between them is a measurement problem — which is
exactly the half SGLang cannot instrument. So: SGLang to run it the way its
authors published it, vLLM to find out *why* a speculator is underperforming.

### Taken

| From them | Why it matters |
|---|---|
| **The DGX Spark operating point** — `--mem-fraction-static 0.78`, `--cuda-graph-max-bs-decode 4`, `--speculative-dspark-block-size 3`, `--mamba-ssm-dtype float16` | The only published GB10 configuration with an allocation table behind it: ~4.93M pool tokens, ~14.1 GiB of FP8 KV, 48 concurrent, ~1,048,570 max input |
| **The hybrid KV arithmetic**, and that it makes 1M affordable | 52 layers = 23 Mamba-2 + 23 MoE + **6** attention. Only those six pay a growing per-token K/V cost; the mamba state is a fixed 716 MiB. This is the *second* model here where a large fixed floor plus a small slope inverts the usual tuning move ([#glm53-flash](#glm53-flash) was the first) |
| **That the draft model keeps its own separate KV cache** — bf16, ~28.2 GiB | The **largest single allocation in the server**, larger than the 30B target it drafts for. The drafter is **1.3 GB on disk** against the target's 21.6 GB (HF API), so this is the sharpest example in the repo of download size failing to predict footprint. It reframes `SPEC_METHOD=none` from "give up speed" to "recover 28 GiB" — the right first move when the pool binds, ahead of a lower `mem-fraction-static` |
| **Every capacity number is a startup-time outcome, not a constant** | Pool size, KV size and `max_running_requests` are all derived at boot from a fraction of whatever was free. Their `get_server_info` recipe became `./report.sh`, so nobody quotes the reference kit's numbers as if they were their own |
| **The per-GPU `mem-fraction-static` table** | The same fraction means a fraction of *that* card's memory. Kept because this repo's recipes get copied to other hardware, and 0.78 on a 32 GiB card OOMs at startup |
| **Prefill is chunked at 8192**, so TTFT grows with prompt size and decode does not | Stops a long-prompt first-token delay being diagnosed as a slow model |

### Taken from the wider sources, not from their repo

| | |
|---|---|
| **The three speculators, ranked by measurement** — `none` 81.3, `dflash` 95.5, `mtp` 111.4, `dspark` **124.2** tok/s single-stream on a DGX Spark | Their repo ships DSpark only. The ranking is what makes the choice a decision rather than a default, and `mtp` is the interesting row: +37% with **no second checkpoint and no extra KV** |
| **`--moe-backend marlin`** | The model card's own hardware table gives native FP4 tensor-core execution to **GB200** and lists DGX Spark under **Marlin**, a W4A16 kernel. This repo says "NVFP4 is the format this hardware exists for" in several places; on `sm_121` that is a claim about **footprint**, and this is the card that says so |
| **`num_speculative_tokens` 3, not 7** | Measured better than 7 for single-stream use on this box. [#dspark-1m-recipe](#dspark-1m-recipe) already recorded what inheriting a `k` from a model card costs |
| **`--enable-metrics`** | SGLang serves no `/metrics` without it, so `spec-decode-accept` would report a healthy DSpark server as having no speculative decoding. A wrong answer wearing the costume of a finding is the exact failure that tool exists to avoid |
| **Block size is gamma, not the verify window** | SGLang's own help: the window is `gamma + 1`. Block size 3 drafts three and verifies four — so the "k" printed by the acceptance probe and the number in the flag are deliberately one apart |

### Not taken

- **Their snapshot-path resolution.** `start.sh` resolves
  `~/.cache/huggingface/hub/models--…/snapshots/<hash>` on the host and passes
  the container path, for both the target and the draft. It exists to keep the
  container off the network; the bind-mounted cache already achieves that, and
  SGLang resolves a Hub id itself. The cost of keeping it is a launcher that
  breaks whenever a second snapshot lands in the cache — `ls | head -1` picks
  one arbitrarily.
- **The host-RAM hard floor at 80 GiB and warning at 110 GiB.** The same
  question is already asked, better, by `ws check`: `MemAvailable` is what a
  server can actually claim, and `MemTotal` on a box running a desktop session
  says a machine qualifies that does not
  ([#workspaces](#workspaces)).
- **`--network host` as the only option.** Kept for SGLang, which the upstream
  recipe launches that way, but the vLLM sibling publishes a port instead —
  this repo already has seven serving workspaces on distinct ports and host
  networking makes port collisions invisible until two of them are up.
- **The `.sglang.pid` / `.sglang.log` files.** A container id in a dotfile
  next to the recipe duplicates what `docker ps` already knows and goes stale
  the moment anything else removes the container. A stable `--name` gives
  `docker logs -f ws-sglang-nemotron35` for free.
- **Their sampling parameters as *the* answer.** They publish 0.6 / 0.95 /
  top_k 20 / repetition_penalty 1.08; NVIDIA's model card and the NeMo cookbook
  publish **1.0 / 0.95**. Both are cited in both workspaces, with NVIDIA's as
  the default because it is the model author's number and the one the published
  evaluations were run at. Averaging two disagreeing published sets is how a
  recipe ends up matching neither.

### Improved on

**The acceptance probe now knows which engine it is talking to.**
`spec-decode-accept` was written against `vllm:spec_decode_*` and would have
read an SGLang server as having no speculative decoding at all. It now detects
the engine before generating anything, and on SGLang degrades to accept length
with the comparable ratio derived as `(length − 1) / k`.

The important half is what it refuses to do. SGLang publishes no per-position
counter, so the **`mask` verdict is unreachable** on that path, and
`tests/check_spec_accept.py` asserts that at four different accept lengths. A
degraded path that degrades *silently* would return a confident verdict about a
shape it never measured — strictly worse than not running, and the same
discipline that already stops a healthy prose ladder convicting a server.

**Both engines' recipes are in one repo with one bench toolchain.** Upstream is
a two-script repo for one engine; the value that could not be copied was the
comparison, which needs both servers behind the same probe.

### Recorded, not acted on

- **W4A16 quantisation of the draft head.** Upstream reports it cuts the
  drafter's memory footprint and per-step latency *without hurting acceptance
  rate*, and says it matters most on memory-constrained parts — which is
  exactly this box, where the draft KV is the largest allocation. Not adopted
  because no published DGX Spark configuration shows the flag, and inventing
  one for the single largest allocation in the server is not the place to
  guess. If a quantised-draft checkpoint appears, this is the first thing to
  try.
- **DSpark wins on throughput *and* latency**, which is unusual — speculative
  decoding normally trades the first for the second. Worth re-testing on a
  non-code workload before treating it as general: the published comparison is
  code generation with thinking off at a 64K window, and acceptance is a
  property of the text ([#dspark-1m-recipe](#dspark-1m-recipe) recorded the
  same caveat from the other direction).
- **`--reasoning-parser` is `nemotron_3` in SGLang and `nemotron_v3` in vLLM.**
  Neither is a typo. Copying one into the other fails at startup, which is the
  good outcome; the bad one would be a parser that loads and silently returns
  reasoning as content.
- **Ollama serves this model too**, from a GGUF Q4_K_M build, at 71.7–87 tok/s
  with `draft_num_predict 2` built in. Not made a workspace: `roles/ollama`
  already installs it and this repo's ollama story is "quickest, good for chat"
  ([serve-models](runbooks/serve-models.md)). Recorded because it is the
  cheapest way to try the model before committing ~94 GiB to it.
