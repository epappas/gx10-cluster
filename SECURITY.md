# Security policy

This repository is Ansible that configures **sshd, a firewall, passwordless
sudo, a VPN client and container runtimes** on real machines. A mistake here
changes the security posture of a host, so it is worth being precise about what
counts as a vulnerability and what is a deliberate decision.

## Reporting a vulnerability

**Please do not open a public issue for anything exploitable.**

Use GitHub's private vulnerability reporting: **Security → Report a
vulnerability** on this repository. That opens a private advisory thread visible
only to the maintainer.

Useful things to include, roughly in order of value:

1. The file and task, or the variable and its value.
2. What posture change it produces — "port X reachable from Y", "credential
   readable by Z", "sudo without a password for W".
3. Whether a default configuration is affected, or only a non-default one.
4. Whether it needs the attacker to already be on the LAN, on the mesh, or on
   the box.

This is a personal-infrastructure project maintained by one person. Expect
best-effort, unpaid response times rather than a corporate SLA. There is no bug
bounty.

## Supported versions

Only `main` is supported. There are no maintenance branches and no backports.

The target platform is **aarch64 Ubuntu 24.04 (DGX OS 7.x) on NVIDIA GB10**
hardware. `site.yml` asserts the architecture and GPU compute capability before
doing anything, so running it elsewhere fails early rather than misconfiguring
an unrelated host.

## In scope

- A task that weakens the posture as a side effect — opening a port, loosening
  a file mode, disabling a control — where the documentation does not say it
  will.
- A default that exposes a service beyond the boundary its documentation claims.
- A credential written to disk, a log, the process table, or shell history.
- Command or template injection through an inventory or `group_vars` value.
- A check in `verify.yml` that reports a control as present when it is not.
  A false green is a security bug here, not just a cosmetic one — the whole
  point of that playbook is to be believed. Two such bugs have already been
  fixed this way.

## Out of scope — deliberate decisions

These are intentional, documented, and reachable from
[docs/decisions.md](docs/decisions.md). Reports that amount to "this repo
configures X" without a concrete attack are likely to be closed with a pointer
here — but if you think the reasoning is *wrong*, that is a legitimate issue and
worth raising publicly.

| Decision | Why | Where |
|---|---|---|
| **Passwordless sudo** for the primary user | The alternative is typing a sudo password into every `make` target, which pushes it into shell history or CI. It is variable-gated, not forced | [decisions](docs/decisions.md#passwordless-sudo-deliberately) |
| **Password SSH auth stays enabled** until you explicitly set `ssh_disable_passwords` | Disabling it automatically, on the strength of a key the play cannot verify you hold, locks people out of their own hardware. It is your assertion to make | [decisions](docs/decisions.md#password-auth-is-disabled-only-by-an-explicit-human-decision) |
| **ufw trusts the peer node wholesale** on the management path | NCCL's bootstrap uses ephemeral ports, so no port-scoped rule can express it. The peer is trusted by address or collectives hang | [decisions](docs/decisions.md#ufw-peers) |
| **`ssh_port` is asserted to be 22** | Port-moving is obscurity, not security, and it breaks every other assumption in the repo | [decisions](docs/decisions.md#ssh_port-is-asserted-to-be-22) |
| **Services bind localhost by default** | Widening a bind is a deliberate, documented opt-in. An unauthenticated metrics endpoint on every interface is the thing being avoided | [decisions](docs/decisions.md#metrics-listeners-bind-monitoring_bind) |
| **NordVPN Meshnet** is the out-of-LAN path | A third-party dependency, accepted knowingly, with the alternatives compared | [decisions](docs/decisions.md#meshnet) |
| **`site.yml` refuses to run as root** | Everything lands in the connecting user's home; under `sudo` that is `/root` | [decisions](docs/decisions.md#siteyml-refuses-to-run-as-root) |

## Accepted risks you should know about

Stated plainly because they are real trade-offs, not oversights.

**The driver stack is held, so its security updates are deferred.**
`driver_stack_holds` pins `nvidia-driver-580-open`, the NVIDIA kernel packages,
**and `docker-ce` / `containerd.io`**. `unattended-upgrades` is enabled but
blacklisted for exactly those packages, so a CVE in the container runtime will
**not** be patched automatically on these hosts. That is deliberate — an
unattended driver bump mid-training run breaks CUDA — but it means container
runtime updates are a manual, scheduled task you own. See
[upgrade-drivers](docs/runbooks/upgrade-drivers.md).

**Secrets are your responsibility, and the repo holds none.** `hf_token` and the
NordVPN token belong in an `ansible-vault` file; `group_vars/*/vault.yml` and
`host_vars/*/vault.yml` are gitignored. Nothing in this repository is encrypted,
because nothing in it is secret. Do not change that.

**The cluster admin private key is generated on a node.** It is created at
`~/.ssh/gx10_admin` and the play cannot move it for you. Copy it to your
workstation and remove it from the node — until you do, a host compromise is a
key compromise. See
[provision-node](docs/runbooks/provision-node.md#the-cluster-admin-key).

**`memlock` is raised to ~64 GB** for RDMA queue pairs and CUDA pinned buffers.
That is a large locked-memory allowance for any process running as that user.

**The interconnect is unauthenticated and unencrypted.** RoCE over a
back-to-back cable has no authentication, and the two interconnect subnets are
trusted wholesale by the firewall. The security boundary is physical access to
the cable. Do not extend those subnets across a switch you do not control. See
[connect-cluster](docs/runbooks/connect-cluster.md).

## Hardening beyond the defaults

If you want a tighter posture than this repo ships:

```bash
# Disable password SSH - only after you have verified key auth from ANOTHER machine
make apply TAGS=remote EXTRA='-e ssh_disable_passwords=true'
```

Then reconsider, in rough order of value: whether `sudo_passwordless` suits your
threat model, whether the desktop session should be running at all
(`systemctl set-default multi-user.target` — it also reclaims ~1.2 GB), and
whether `ufw_ssh_sources` should be narrower than your whole LAN.

Read [recover-ssh-lockout](docs/runbooks/recover-ssh-lockout.md) **before**
changing anything in the sshd or firewall path, not after.
