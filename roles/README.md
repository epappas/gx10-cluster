# Roles

Eleven roles run in `site.yml`, in the order below; the other five are opt-in
and run only from `optional.yml`. Each row's tag is what you pass to
`make apply TAGS=…` / `SKIP=…`, or to `make optional TAGS=…`.

## Provisioning — run by `site.yml`

| Role | Tag | Does |
|---|---|---|
| `base` | `base` | apt safety (driver holds), build toolchain, CLI tools, `gh`, git config, sysctl, memlock |
| `docker` | `docker` | group membership, NVIDIA runtime, merged `daemon.json`. Verifies; never installs Docker |
| `shell` | `shell` | the env fragment both shells source, tmux config, zsh as the login shell |
| `dev_python` | `python`, `dev` | uv and standalone tools (ruff, ipython, pre-commit) |
| `dev_rust` | `rust`, `dev` | rustup pinned to `rust_toolchain`, plus `bat` / `fd-find` / `zoxide` from apt |
| `ml` | `ml` | NCCL, cuDNN, the pinned venv from `requirements-ml.txt`, ollama, llama.cpp built for sm_121 |
| `inference` | `inference`, `serving` | vLLM container, `vllm-serve`, templated systemd unit |
| `monitoring` | `monitoring` | `gx10-status` (live), `gx10-top` (all nodes at once), `gx10-sample` (history, systemd timer). **No daemons, nothing resident** |
| `remote` | `remote` | sshd, ufw, NordVPN Meshnet |
| `cluster` | `cluster` | RoCE, interconnect addressing, `/etc/hosts`, inter-node SSH, `/etc/nccl.conf`, `gx10-interconnect` |
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
| `dev_node` | `node` | nvm + Node 22. Nothing in the ML path needs it |
| `benchmark` | `bench` | perftest, fio, OpenMPI, DCGM and a pinned `nccl-tests` build. Installs only — `make bench` runs them |

```bash
make optional TAGS=ray
```

`optional.yml` uses `include_role` **tasks**, not a `roles:` list, and
`observability` is two task files rather than two tags. Both are the same fix
for the same bug: role-level tags are additive with task tags, so `--tags
exporters` used to install grafana ([why](../docs/decisions.md#optional-include-role)).
`roles/observability/tasks/main.yml` therefore fails on purpose — pick a tier.

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
- **New role?** Add it to `site.yml` with a tag — or, if it is opt-in, to
  `optional.yml` as an `include_role` task tagged `[<name>, never]`. Add a check
  to `vars/verify_checks.yml`, and a row above — `make docs` fails if you skip
  the last one.

Full checklist: [docs/contributing.md](../docs/contributing.md).
