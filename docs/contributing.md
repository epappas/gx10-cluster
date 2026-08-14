# Growing this repo

How to add to it without it rotting.

## The loop

```bash
# 1. change something (usually group_vars/all.yml, not a role)
# 2. offline checks - fast, run these constantly
make check           # lint + syntax + smoke + render

# 3. on the hardware
make diff            # what would change
make apply
make verify          # asserts, does not just print
make idempotence     # applies twice; second run must be changed=0
```

CI runs `make check` plus `yamllint` and `shellcheck`. The rest needs the real
GB10.

## Why testing is tiered

You cannot fake a GB10, a 580 driver, or a ConnectX-7 in a container, so most
of this repo is untestable in CI by construction. Rather than pretend
otherwise with Molecule (which would exercise only the handful of tasks that
do not touch hardware, while implying broader coverage), the split is explicit:

| Layer | Runs | Catches |
|---|---|---|
| `make lint` | anywhere, CI | style, deprecated modules, missing `changed_when` |
| `make syntax` | anywhere, CI | malformed playbooks |
| `make smoke` | anywhere, CI | a broken `ansible.cfg` — see below |
| `make render` | anywhere, CI | undefined vars and bad filters in templates |
| `make handlers` | anywhere, CI | a `notify:` naming a handler that doesn't exist |
| `make idempotence` | the box | a task reporting changed when it shouldn't |
| `make verify` | the box | the node not being in the state we claim |

Know the blind spots, so you don't trust a green run further than it deserves:

- **`make idempotence` is one-directional.** It catches a task that reports
  changed on a no-op. It cannot catch the opposite — a `changed_when` that
  *never* fires makes it pass. That bug has shipped here twice.
- **`make render` only sees `.j2` files.** Inline Jinja in `content:` blocks
  and `blockinfile` bodies is untested; a typo'd variable there surfaces at
  apply time, on the box.
- **Nothing offline can see a `when:` typo.** `when: instal_ollama` silently
  never fires and every check stays green.

`make smoke` exists because `--syntax-check` does **not** load stdout
callbacks. This repo once shipped an `ansible.cfg` that aborted every real run
while lint and syntax-check both passed. Never trust those two alone.

## Adding a role

1. `roles/<name>/{tasks,defaults,handlers,templates,files}/`
2. Add it to `site.yml` with a tag.
3. Put every tunable in `group_vars/all.yml`, not in the role.
4. Add a check to `vars/verify_checks.yml` with a `hint` naming the runbook
   that fixes it.
5. If it adds a template, add it to `tests/render.yml`.
6. If the choice was non-obvious, add an entry to [decisions.md](decisions.md).

## Conventions

**Every task must be idempotent.** `make idempotence` enforces it. The usual
offenders are `command`/`shell` without `creates:` or a `changed_when`, and a
`changed_when` that greps for a string the tool does not actually print —
verify the string before trusting it.

**Never `failed_when: false` to make a task quiet.** It swallows dpkg lock
errors and half-configured package states along with the case you meant to
ignore. Tolerate the specific condition instead.

**Prefer modules to shell.** Where shell is genuinely right, `set -o pipefail`
and an explicit `executable: /bin/bash`.

**Do not fight DGX OS.** Check what already sets a value before setting it —
see the ownership table in [hardware.md](hardware.md#what-dgx-os-already-manages).
Several settings were removed from this repo because DGX already owned them, and
one (`fs.file-max`) was a twelve-order-of-magnitude regression.

**Comments explain WHY, not WHAT.** The valuable ones here record things that
cost hours to rediscover: the hotplug behaviour of the CX-7, the cu130 index,
`nvidia-ctk` owning the runtimes block. If a comment restates the code, delete it.

**Anything touching sshd or networking gets a runbook entry.** If it can lock
you out, [recover-ssh-lockout](runbooks/recover-ssh-lockout.md) must say how to
get back in.

## Tooling versions

`ansible-lint` is pinned to the same version in CI and in `.pre-commit-config.yaml`.
Keep your local copy matched, or you will chase findings that only exist in one
of the three:

```bash
uv tool install --with ansible 'ansible-lint==25.6.1'
ansible-galaxy collection install -r requirements.yml
python3 -m pip install pyyaml     # tests/check_handlers.py
```

`requirements.yml` matters more than it looks: `ansible-lint` runs in an
isolated venv with `ansible-core` and no collections, so without it every
non-builtin module reports as unknown — locally it may pass only because your
environment happens to have them.

## Pre-commit

```bash
uv tool install pre-commit
pre-commit install
```

Runs yamllint, ansible-lint, shellcheck and a private-key detector before each
commit — the same checks as CI.

## Keeping the docs honest

Every doc answers **what / when / why / how**, in that order, with a runnable
example for anything you would otherwise have to guess at.

- `README.md` routes. Short enough to read in a minute.
- **Runbooks** are task-oriented: what, when, the mechanism in two or three
  sentences, then numbered steps with expected output and a failure table. If
  you worked something out at 2am, it belongs in a runbook.
- `decisions.md` is append-mostly. Edit an entry when a decision changes;
  do not delete it.
- `hardware.md` is verified facts only. If you cannot produce the command that
  proves it, it does not belong there.

### Label provenance

Most GX10 information online is community-written, some of it machine-generated
and wrong. A doc that cannot tell you where a claim came from is worse than no
doc, because it launders a guess into an instruction. Mark anything that is not
first-hand:

| Label | Means |
|---|---|
| *(unlabelled)* | Verified on our hardware — the command is in the doc |
| **NVIDIA docs** | From `docs.nvidia.com` or NVIDIA's own playbooks |
| **Confidence: community-reported** | Forum or blog. A lead to test, not a fact |

Rules that follow from this:

- Never copy a command from a community repo into this one. Read it, understand
  the mechanism, write our own — and never clone or execute theirs.
- A community claim must come with a way to *measure* whether it applied to
  you, so a non-fix can be recognised as a non-fix.
- When you verify or disprove a community claim on the hardware, upgrade or
  delete the label. Stale "reportedly" text is how slop propagates.
