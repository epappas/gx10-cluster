# Roles

Run order is the order in `site.yml`. Each row's tag is what you pass to
`make apply TAGS=…` or `make apply SKIP=…`.

## Provisioning — run by `site.yml`

| Role | Tag | Does |
|---|---|---|
| `base` | `base` | apt safety (driver holds), build toolchain, CLI tools, `gh`, git config, sysctl, memlock |
| `docker` | `docker` | group membership, NVIDIA runtime, merged `daemon.json`. Verifies; never installs Docker |
| `shell` | `shell` | zsh + starship, the shared env fragment both shells source, tmux |
| `dev_python` | `python`, `dev` | uv and standalone tools (ruff, ipython, pre-commit) |
| `dev_rust` | `rust`, `dev` | rustup + CLI tools |
| `dev_node` | `node`, `dev` | nvm + Node 22 |
| `ml` | `ml` | NCCL, cuDNN, PyTorch cu130, ollama, llama.cpp built for sm_121 |
| `inference` | `inference`, `serving` | vLLM container, `vllm-serve`, templated systemd unit |
| `monitoring` | `monitoring` | `gx10-status` — GPU, throttling, unified memory, swap. **No daemons** |
| `remote` | `remote` | sshd, ufw, tailscale |
| `cluster` | `cluster` | RDMA, interconnect addressing, inter-node SSH, `/etc/nccl.conf` |
| `models` | `models` | pre-loads open weights. **The long pole** — ~130 GB |

## Opt-in — run only by `optional.yml`

Behind the `never` tag, so `site.yml` never touches them and a bare
`ansible-playbook optional.yml` is a no-op. None is required: `torchrun`
already runs 2-node jobs, and `gx10-status` already shows you the machine.

| Role | Tag | Does |
|---|---|---|
| `ray` | `ray` | Ray head/worker by `cluster_rank`. The substrate multi-node vLLM uses for tensor parallelism |
| `slurm` | `slurm` | slurmctld/slurmd + munge. Real queueing; heavy for two nodes |
| `observability` | `exporters` | node_exporter + GPU textfile collector, ~20 MB RSS, for an external scraper |
| `observability` | `dashboards` | the above plus prometheus + grafana **on this box** — costs model capacity |

```bash
make optional TAGS=ray
```

## Conventions

- **Every tunable lives in `group_vars/all.yml`**, not in the role. If you are
  editing a version or an address inside `roles/`, it belongs elsewhere.
- **Roles must be idempotent.** `make idempotence` enforces one direction of
  that; see the blind spots in [contributing](../docs/contributing.md).
- **`notify:` must name a handler in the same role.** `make handlers` enforces
  it — Ansible itself only errors when the notifying task reports changed, so a
  typo hides until a first-time provision.
- **New template?** Nothing to do: `tests/render.yml` discovers `roles/**/*.j2`
  automatically. Add a case only if it has a conditional branch worth covering.
- **New role?** Add it to `site.yml` with a tag, add a check to
  `vars/verify_checks.yml`, and add a row above — `make docs` fails if you skip
  the last one.

Full checklist: [docs/contributing.md](../docs/contributing.md).
