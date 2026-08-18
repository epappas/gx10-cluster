# Contributing

Thanks for looking. This is a small, opinionated repo that configures real
hardware, so the bar is "explain why", not "match the style guide".

The full guide — conventions, the test tiers, how to add a role, how to
regenerate the ML lockfile — lives in
**[docs/contributing.md](docs/contributing.md)**. This page is the short version.

## The loop

```bash
./bootstrap.sh    # installs ansible via uv, no sudo
make check        # lint + syntax + smoke + render + handlers + tags + docs + lockfile + shellcheck
```

**`make check` must pass.** It runs offline, needs no hardware, and is what CI
runs. It is fast — run it constantly, not at the end.

If you have GB10 hardware, also run `make diff` (a dry run) and `make verify`.
If you do not, say so in the PR; a reviewer with hardware can cover it.

## What makes a change easy to accept

- **Say how you verified it.** "Measured on two nodes, 4 runs each way" beats
  "should be faster". If you could not verify it, say that too — an honest
  unknown is fine, a confident guess is not.
- **Put the reason where it will be found.** Non-obvious code gets a comment
  explaining *why*, not what. A real design choice gets an entry in
  [docs/decisions.md](docs/decisions.md).
- **Label the provenance of hardware claims.** Unlabelled means you measured it
  and the command is in the doc. Anything from a forum is
  `Confidence: community-reported` and must ship with a way to measure whether
  it applied to the reader. See [provenance](docs/README.md#provenance) — most
  GB10 information online is unsourced and some of it is wrong.
- **Tunables go in `group_vars/all.yml`**, not hardcoded in a role.
- **New role or runbook?** Index it. `make docs` fails if you forget, on
  purpose.

## What gets pushed back

- A default that changes the security posture without saying so — read
  [SECURITY.md](SECURITY.md) first.
- Speculative tuning. Knobs that "should help" but were not measured belong in
  the tier-2 section of [tune-network](docs/runbooks/tune-network.md), clearly
  marked unverified, not in a role.
- Deleting a check because it fails. The checks encode bugs that already
  happened at least once.

## Reporting a bug

Include the command, the output, and which node. For anything hardware-shaped,
`gx10-interconnect` and `gx10-top -1` output is worth pasting — it captures the
fabric, thermals and process state in one go.

Security issues go through [SECURITY.md](SECURITY.md), never a public issue.
