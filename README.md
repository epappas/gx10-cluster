# gx10-cluster

Ansible provisioning for ASUS Ascent GX10 (NVIDIA GB10 Grace Blackwell) nodes,
written so a second box comes up identical to the first.

```bash
./bootstrap.sh        # install ansible via uv, no sudo
make apply            # provision BOTH nodes (prompts for sudo). Run under tmux.
# log out and back in  -- docker, nordvpn groups; zsh; shell environment
make verify           # assert the nodes are in the expected state
```

`make` on its own lists every target.

The two nodes are `odysseus` (192.168.4.36) and `poseidon` (192.168.4.37). The
inventory name **is** the machine's hostname — the play sets it, and
`/etc/hosts`, `~/.ssh/config`, the Slurm `NodeName` and the Prometheus label all
derive from that one string. To rename a box, rename it in `inventory.yml` and
re-run ([how](docs/runbooks/provision-node.md#renaming-a-node)).

Both are addressed over SSH, including the one you type the command on — there
is no `ansible_connection: local` special case, so the command behaves the same
wherever you run it and no host skips the SSH path
([why](docs/decisions.md#ssh-both-nodes)).

**The first run needs `-K`** and both boxes must accept the same sudo password,
because `-K` prompts once per run rather than once per host. That run installs a
sudoers drop-in (`sudo_passwordless`), so every run after it does not.

Two things the play cannot do for you:

- **Move the cluster admin private key off the node** — it is generated at
  `~/.ssh/gx10_admin` on `odysseus` and belongs on your laptop
  ([how](docs/runbooks/provision-node.md#the-cluster-admin-key)).
- **Join the Meshnet** — the NordVPN client is installed and the firewall is
  open for it, but logging in needs a token you generate in Nord Account
  ([how](docs/runbooks/provision-node.md#join-the-meshnet)). Until then the
  nodes are reachable on the LAN only.

> **Status: applied end-to-end on zero machines so far.** The hardware facts in
> [hardware.md](docs/hardware.md) are verified on a live GX10; the playbook's
> own behaviour is reviewed and statically checked, not yet proven by a run.

## Runbooks

Task-oriented. Start here.

| I want to… | Runbook |
|---|---|
| Set up a brand-new GX10 | [provision-node](docs/runbooks/provision-node.md) |
| Cable two boxes together and verify 200 Gb/s | [connect-cluster](docs/runbooks/connect-cluster.md) |
| Get back in after an SSH lockout | [recover-ssh-lockout](docs/runbooks/recover-ssh-lockout.md) |
| Update packages without breaking CUDA | [upgrade-drivers](docs/runbooks/upgrade-drivers.md) |
| Run or serve a model | [serve-models](docs/runbooks/serve-models.md) |
| Download or clean up model weights | [manage-models](docs/runbooks/manage-models.md) |
| Run a job across both nodes | [run-distributed](docs/runbooks/run-distributed.md) |
| See what the machine is doing | [monitoring](docs/runbooks/monitoring.md) |
| Fix something that's broken | [troubleshoot](docs/runbooks/troubleshoot.md) |
| Change this repo safely | [contributing](docs/contributing.md) |

## Reference

- [docs/](docs/README.md) — index of everything below
- [roles/](roles/README.md) — what each role does, and its tag
- [hardware.md](docs/hardware.md) — GX10 facts that drive the design, and what
  DGX OS already manages so you don't re-tune it
- [decisions.md](docs/decisions.md) — why things are the way they are, one
  short entry per decision

## Layout

```
site.yml            main playbook (serial: 1, any_errors_fatal)
verify.yml          assertion-based health check
bootstrap.sh        the one thing you run by hand
Makefile            every command you need
inventory.yml       both nodes, interconnect index and rank
group_vars/all.yml  every tunable
vars/               playbook-scoped data           -> vars/README.md
tests/              render, handler and docs checks
optional.yml        opt-in components, never run by site.yml
roles/              15 roles, 11 of them in site.yml -> roles/README.md
docs/               runbooks and reference          -> docs/README.md
```

Run one role with `make apply TAGS=ml`, skip one with `make apply SKIP=ml`, and
pass anything else with `EXTRA='-e allow_apt_upgrade=true'`. (Not `make apply
-e ...` — make eats `-e` as its own flag and the variable never reaches
Ansible.) The models role is the long pole at ~130 GB; `make apply SKIP=models`
now and `make models` later.

The four roles `site.yml` does not run are opt-in — `ray`, `slurm`,
`observability` (two tiers, two tags) and `dev_node`:

```bash
make optional TAGS=ray|slurm|exporters|dashboards|node
```

Nothing in `optional.yml` runs without a tag, so a bare invocation is a no-op.
`exporters` and `dashboards` really are separate tiers — that took an
`include_role` rewrite to make true
([why](docs/decisions.md#optional-include-role)).

There is no `enable_*` variable *per role* — tags do that. A few within-role
toggles remain (`build_llama_cpp`, `install_ollama`, `install_nordvpn`,
`enable_ufw`) because tags cannot reach inside a role.

## Requirements

aarch64 Ubuntu 24.04 (DGX OS 7.x) on GB10 hardware. `site.yml` asserts the
architecture and the GPU compute capability before doing anything, because the
PyTorch index and llama.cpp CUDA arch here are chosen for `sm_121` and would
silently misbuild elsewhere. It also refuses to run as root: everything lands in
the connecting user's home, and under `sudo` that would be `/root`.

The ML venv is installed from a committed lockfile
(`roles/ml/files/requirements-ml.txt`), resolved for aarch64 and the cu130
index. `make lock` regenerates it and must run **on a GX10** — see
[contributing](docs/contributing.md#adding-or-changing-a-python-package).

## License

MIT
