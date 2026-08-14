# gx10-cluster

Ansible provisioning for ASUS Ascent GX10 (NVIDIA GB10 Grace Blackwell) nodes,
written so a second box comes up identical to the first.

```bash
./bootstrap.sh        # install ansible via uv, no sudo
make apply            # provision (prompts for sudo). Run under tmux.
# log out and back in  -- docker group, zsh, shell environment
make verify           # assert the node is in the expected state
```

`make` on its own lists every target.

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
| Fix something that's broken | [troubleshoot](docs/runbooks/troubleshoot.md) |
| Change this repo safely | [contributing](docs/contributing.md) |

## Reference

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
inventory.yml       nodes, interconnect index and rank
group_vars/all.yml  every tunable
vars/               playbook-scoped data (verify checks)
tests/render.yml    renders all templates against real facts
roles/              base docker shell dev_python dev_rust dev_node ml remote cluster
docs/               runbooks and reference
```

Run one role with `make apply TAGS=ml`, skip one with `make apply SKIP=ml`, and
pass anything else with `EXTRA='-e allow_apt_upgrade=true'`. (Not `make apply
-e ...` — make eats `-e` as its own flag and the variable never reaches
Ansible.)

There is no `enable_*` variable *per role* — tags do that. A few within-role
toggles remain (`build_llama_cpp`, `install_ollama`, `enable_ufw`) because tags
cannot reach inside a role.

## Requirements

aarch64 Ubuntu 24.04 (DGX OS 7.x) on GB10 hardware. `site.yml` asserts both
the architecture and the GPU compute capability before doing anything, because
the PyTorch index and llama.cpp CUDA arch here are chosen for `sm_121` and
would silently misbuild elsewhere.

## License

MIT
