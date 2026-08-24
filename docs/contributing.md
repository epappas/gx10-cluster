# Growing this repo

How to add to it without it rotting.

## The loop

```bash
# 1. change something (usually group_vars/all.yml, not a role)
# 2. if you touched roles/ml/files/requirements-ml.in
make lock            # re-resolve the ML lockfile. aarch64 only; commit the .txt
# 3. offline checks - fast, run these constantly
make check           # lint + syntax + smoke + render + handlers + docs + lockfile + shellcheck

# 4. on the hardware
make diff            # what would change
make apply
make verify          # asserts, does not just print
make idempotence     # applies twice; second run must be changed=0
```

CI runs `make check` plus `yamllint` and `shellcheck`. The rest needs the real
GB10.

`make apply` drives **both** nodes over SSH, one at a time (`serial: 1`,
`any_errors_fatal`), and `-K` prompts once per run — so both boxes must accept
the same sudo password
([why](decisions.md#ssh-both-nodes)). Use `LIMIT=poseidon` when you
deliberately want one, but read the warning in
[provision-node](runbooks/provision-node.md#how--node-2) first: a limited run
cannot establish inter-node trust and cannot distribute the munge key.

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
| `make docs` | anywhere, CI | a stale directory index, a dead relative link or `#anchor` |
| `make lockfile` | anywhere, CI | an ML lockfile regenerated without the resolution flags, or unpinned |
| `make shellcheck` | anywhere, CI | shell bugs in `bootstrap.sh` |
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
- **`make verify` with a `--limit` is a weaker check than it looks.** The
  cross-node comparison of driver, kernel and torch version needs both hosts in
  the play. It says so rather than passing silently, but only if you read the
  output.
- **`make docs` checks coverage, not truth.** It cannot tell you a command in a
  runbook is wrong, only that the file it links to exists. Grep the tree for
  every variable, tag and path you write.

`make smoke` exists because `--syntax-check` does **not** load stdout
callbacks. This repo once shipped an `ansible.cfg` that aborted every real run
while lint and syntax-check both passed. Never trust those two alone.

## Adding a role

1. `roles/<name>/{tasks,defaults,handlers,templates,files}/`
2. Add it to `site.yml` with a tag. If it is opt-in, add it to `optional.yml`
   instead, as an `include_role` **task** tagged `[<name>, never]` — never as a
   `roles:` entry. Role-level tags are additive with task tags, which is how
   `--tags exporters` came to install grafana
   ([why](decisions.md#optional-include-role)).
3. Put every tunable in `group_vars/all.yml`, not in the role.
4. Add a check to `vars/verify_checks.yml` with a `hint` naming the runbook
   that fixes it.
5. Templates need nothing: `tests/render.yml` discovers `roles/**/*.j2` by
   `find`. Add an explicit case only if the template has a conditional branch
   the default render would not reach — as `ray.service.j2` does.
6. Add a row to [roles/README.md](../roles/README.md) — `make docs` fails
   without one.
7. If the choice was non-obvious, add an entry to [decisions.md](decisions.md).

## Adding a workspace

A workspace is a **recipe**, not a role. It runs on a machine Ansible already
made ready, and the only thing it may assume about that machine is what its
`requires:` block declares ([why](decisions.md#workspaces)).

1. `workspaces/<kind>/<name>/` — `<kind>` is one of `inference`, `cluster`,
   `rl`, `bench`, `agent`, and the directory and the manifest field must agree.
2. `workspace.yml`. The `name` must equal the directory name, `provenance`
   starts at `unverified`, and `sources:` is **required in practice** — flags
   come from somewhere, and citing it is what keeps these recipes from drifting
   into folklore.
3. Something that runs: `compose.yml`, or `up.sh` + `down.sh` (executable).
   `kind: cluster` is exempt — Slurm ships job scripts and nothing to start.
4. `README.md`. **What / why / when / how**, plus a failure table and the
   sources. This is not decoration: a manifest says what a recipe *needs* and a
   script says what it *does*; neither says **when you should reach for this one
   instead of the one next to it**, which is the question people arrive with.
5. Add it to the catalogue in
   [workspaces/README.md](../workspaces/README.md). `make check` fails if a
   workspace has no README, or if the catalogue does not link it.
6. `.env.example` if it has any knobs. The real `.env` is gitignored; never
   commit one ([tiers](runbooks/manage-secrets.md)).

Two things to get right that the checks cannot see for you:

- **Keep it standalone.** Every recipe here should be readable, copyable and
  runnable by hand without `ws`. The one exception is `workspaces/lib/`, and it
  is an exception with a written argument
  ([why](decisions.md#twonode-lib)) — read it before adding to it.
- **Pick a free port.** 8888, 8890, 8891, 8892, 8899, 8900, 3080 and 8265 are
  taken. Two serving workspaces cannot run at once anyway, but a collision
  fails in a way that reads as a broken recipe.

`tests/check_workspaces.py` rejects a name/directory mismatch, an unknown
`requires:` key (awk silently returns nothing for one, so the check would never
run and preflight would report ready), a missing `sources:`, a non-executable
script, and a missing or unlinked README.

## Adding or changing a Python package

The ML venv is not a package list any more. `roles/ml/files/requirements-ml.in`
holds the **top-level wants** — 16 of them today; `requirements-ml.txt` is their
fully pinned resolution, 87 packages, and it is what the role installs.

```bash
# edit roles/ml/files/requirements-ml.in
make lock                 # regenerates the .txt
git diff roles/ml/files/requirements-ml.txt    # review, then commit
```

Three things will bite you:

- **`make lock` must run on a GX10.** uv resolves for the platform it runs on,
  so a laptop produces a lockfile pinning x86_64 wheels and an `nvidia-*` stack
  this box cannot use. The target refuses on anything but aarch64.
- **`--index-strategy unsafe-best-match` is load-bearing**, not tuning. The
  cu130 index carries frozen copies of torch's runtime dependencies and, being
  the priority index, shadows PyPI for every one of them. Without the flag the
  same `.in` resolves `certifi==2022.12.7` and `datasets==1.1.1` and says
  nothing about it ([the whole story](decisions.md#ml-lockfile)). It is already
  on `make lock` and on the install task; do not drop it from either.
- **Review the diff.** `make lock` re-resolves everything, so a one-line change
  to the `.in` can move fifty pins. That is the point — but it is the moment to
  look, not after `make apply`.

### If a bot opens a PR against the lockfile

Close it and run `make lock` instead. A single bumped pin corresponds to no
real resolution — it was not produced against the cu130 index on aarch64 with
`--index-strategy` — and it looks entirely plausible in review, which is what
makes it dangerous.

`.github/dependabot.yml` configures GitHub Actions only, so no *version* update
will ever touch the file. Dependabot **security** updates are a different
mechanism: they read the dependency graph regardless of that config, GitHub
provides no way to exclude a manifest path from them, and they are enabled on
this repo. So this will eventually happen.

`make check` runs `tests/check_lockfile.py`, which asserts the header still
records the resolution flags, both index directives survive, torch keeps its
`+cu130` local version, and every requirement is pinned with `==`. That catches
a lockfile regenerated the wrong way. It does **not** catch a plausible
single-line edit — only reading the diff does.

Adding a package to the venv by hand with `uv pip install` is not an error, but
it is invisible: `make verify`'s `lockfile applied` check compares the installed
torch against the copy of the lockfile in the venv, so it will not notice
anything else you added, and the next `make apply` will not remove it either
(the role uses `pip install -r`, deliberately not `pip sync` — that would
uninstall Ray).

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

`uv` itself is a hard requirement of `make lock` — `bootstrap.sh` puts it in
`~/.local/bin`, which the Makefile prepends to `PATH`.

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
- **A workspace README** is the same shape, scoped to one recipe, and its job is
  the comparison: why this one and not the one next to it.
- `decisions.md` is append-mostly. Edit an entry when a decision changes;
  do not delete it.
- `hardware.md` is verified facts only. If you cannot produce the command that
  proves it, it does not belong there.

`make docs` enforces the mechanical half: every role, runbook, reference doc and
`vars/` file is indexed, and every relative link and `#anchor` resolves.
`make workspaces` does the same for the recipe catalogue. A dead
anchor is otherwise silent — the page loads and ignores the fragment. Give a
`decisions.md` entry an explicit `<a name="…">` if you intend to link to it;
heading slugs are long and they move when you reword the heading.

A wrong command is worse than a missing one, so grep before you write: every
variable, tag, filename and command in a doc should exist in the tree at the
moment you commit it.

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
