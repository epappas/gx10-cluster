# vars/

Playbook-scoped data — loaded explicitly with `vars_files`, not automatically.

| File | Loaded by | Contains |
|---|---|---|
| `verify_checks.yml` | `verify.yml` | The health checks `make verify` runs |

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

`tests/render.yml` asserts every entry has `name`, `cmd` and `hint`, so a
malformed check fails `make check` rather than failing at 2am.
