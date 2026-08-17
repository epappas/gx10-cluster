# vars/

Playbook-scoped data — loaded explicitly with `vars_files`, not automatically.

| File | Loaded by | Contains |
|---|---|---|
| `verify_checks.yml` | `verify.yml` | The health checks `make verify` runs |
| `benchmark_checks.yml` | `benchmark.yml` | The single-node benchmark gates and gauges `make bench` runs |

## Why not `group_vars/`

`group_vars/` files are auto-loaded and must be named after a real inventory
group. An early version of this data lived in `group_vars/verify.yml`, which
silently loaded **nothing** — there is no group called `verify`. Data belonging
to one playbook goes here and is named in that playbook's `vars_files`.

`group_vars/all.yml` remains the home for everything that configures the
*node*; this directory is only for data a specific playbook consumes.

## verify_checks.yml

A list of checks. Each entry:

```yaml
- name: "torch sees GB10"        # shown in the report
  cmd: "…"                       # shell; rc 0 = pass. Jinja is templated
  required: false                # optional; default true
  hint: "…"                      # what to DO about it — name a runbook
```

- **`required: false`** for anything legitimately unmet on a healthy node —
  cable-dependent checks, or ones needing a login session or a sudo password.
  Those get reported, never fail the run.
- **`hint` is mandatory** and should name the runbook that fixes it. A check
  that says only what broke wastes the moment it fires.
- **Quote carefully.** Use a double-quoted scalar, not `>-`, for anything with
  backslashes: a folded scalar does not process escapes, so `\\.` stays two
  literal backslashes and the regex silently never matches. That shipped once.
  A double-quoted scalar may still span lines — the newline folds to a space —
  so a long one-liner does not have to fight the 160-column limit.

`tests/render.yml` asserts every entry has `name`, `cmd` and `hint`, so a
malformed check fails `make check` rather than failing at 2am.

## benchmark_checks.yml

Same shape, two differences. Each entry declares a `kind`:

- **`gate`** — the command exits 0 or non-zero. Asserts setup, not speed.
- **`gauge`** — the command prints exactly one number on stdout. Always
  reported; asserted only if the entry carries a `floor`.

And `provenance` is **mandatory on every entry**, saying where the threshold
came from — a hardware register, a vendor tool, or a documented failure mode.
Where no defensible source exists the entry says `RECORD ONLY` and takes the
measurement without asserting on it. A threshold with no stated basis is
indistinguishable from one invented to make the suite pass, so it is a bug.

Cross-node benchmarks are not here, for the same reason the drift check is not:
`ib_write_bw` and `iperf3` are client/server and `all_reduce_perf` is
MPI-launched, none of which is one command on one node. Those live in
`benchmark.yml`.

## What does not go here

A check that has to compare two hosts. Every entry here is one shell command
run on one node, and nothing in a shell on node A can see node B — so the
cross-node version-drift assertion lives in `verify.yml` itself, as tasks. Put
a new comparison there, next to it, not here.
