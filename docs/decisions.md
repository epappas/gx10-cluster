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
which SGLang does not support. So on Blackwell hardware, whose entire advantage
here is NVFP4, SGLang is the one engine that cannot use it. This is recorded in
`workspaces/README.md`, in the runbook and in the SGLang manifest itself,
because it is discoverable only by trying and failing.

**All six workspaces ship `provenance: unverified`.** They are written from
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
