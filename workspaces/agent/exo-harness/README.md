# exo-harness

> [Exo](https://github.com/exoharness/exo) — an agent harness built to **rewrite
> itself** — running on the host, pointed at a model **this cluster is
> serving**.

| | |
|---|---|
| Kind | `agent` — a **client**, not a server |
| Engine | `exo` (Rust CLI + TypeScript harness) |
| Nodes | 1, and it claims no GPU |
| Endpoint | your terminal (REPL). The scheduler keeps running after `/exit` |
| Needs | Docker, git, node, pnpm, cargo — and **11 GB** for the build tree |
| Provenance | **`verified`** — built and round-tripped a prompt on a GB10 |

## What

A pinned checkout at `~/src/exo`, built with the toolchain this repo already
installs, launched against a model binding that points at your own server.

Exo's own [`setup.sh`](https://github.com/exoharness/exo/blob/main/setup.sh)
installs mise and pinned node/pnpm/rust toolchains, then asks for an **OpenAI or
OpenRouter** key. This workspace does neither: it uses the node 22 and Rust
1.97.1 that `make optional TAGS=node` and `TAGS=rust` already put on the box,
and registers a binding pointed at `127.0.0.1`.

## Why this one is different from the other two agents

`dsh` and `pi` are harnesses **you** configure. Exo is a harness that
configures **itself** — it has its own source mounted inside its sandbox at
`/workspace/exo`, tools to rebuild and restart itself, and an append-only event
log so it can tell what it has already tried.

| | [`deepseek-harness`](../deepseek-harness/README.md) | [`pi-harness`](../pi-harness/README.md) | `exo-harness` |
|---|---|---|---|
| Runs in | A container | A container | **The host** |
| Sandbox | The container is the boundary | The container is the boundary | **Exo starts its own** |
| Self-modifying | No | Extensions and skills | **Prompts, tools, harness policy, its own Rust** |
| State | `dsh-home/` | `pi-agent/` | **The checkout itself** |

**And the pairing is still the point — no token leaves the house:**

```bash
ws up vllm-qwen3.8-27b-nvfp4    # the model, on the cluster
ws up exo-harness               # the agent, talking to it
```

## Three decisions worth knowing

### Exo runs on the host, and that is not laziness

Exo's loop — the part that builds context, holds your keys, and writes the
event log — runs **outside** the sandbox by design, and starts a Docker
container of its own for tool calls. Putting exo itself in a container means
docker-in-docker, or a shared socket whose bind-mount paths mean different
things on each side of it. The first path to break would be `/workspace/exo`:
the mount that lets exo read and rewrite its own source, which is the entire
premise.

So exo runs on the host exactly as upstream ships it, and the sandbox it starts
is the boundary that was always meant to be the boundary.

### The default template is `minimal`, not upstream's `canonical`

`canonical` wires up **ExoChat**, a chat UI hosted at `exoharness.ai`. Your
conversation with a model your own cluster is serving would travel through
someone else's server — the exact thing this pairing exists to avoid. So the
default here is `minimal` plus an **explicit** Docker sandbox.

`EXO_TEMPLATE=canonical` in `.env` if you want ExoChat and have decided that
trade is fine. `dev` swaps ExoChat for IRC and Discord.

### The checkout is state, not a build directory

`~/src/exo/.exo/` holds every agent, conversation, event and secret; the source
next to it is something **the agent edits**. So:

- `up.sh` **warns** when `HEAD` is not the pin and does not reset it — an
  unexpected `HEAD` here is as likely to be the agent's work as it is drift.
- `up.sh` does **not** pass `--skip-build`, so exo rebuilds itself when its own
  sources are newer than the binary.
- `down.sh` runs `stop-all`, which preserves everything. Throwing state away is
  `./exo.sh fresh` **in the checkout**, and it is deliberately not wired up.

## Three honest warnings

1. **It is built to modify itself** — prompts, tools, harness policy, and its
   own Rust and TypeScript — and it can clone itself and manage a lineage of
   clones. That is the feature, not a bug. Treat the checkout as something that
   changes without you.
2. **The sandbox is the boundary**, and it is a plain `ubuntu:24.04` container
   with networking **enabled** by default. Exo's loop is not in it.
3. **The build tree is 11 GB**, measured after a cold first run — `target/`
   9.6 GB (a debug profile with debuginfo, two binaries, one dependency graph)
   and `node_modules` 1.1 GB — and it is **not** in the HF cache that the
   `min_disk_gb` check measures. See the note in
   [`workspace.yml`](workspace.yml).

## When to use it — and when not

| Use it when | Use something else when |
|---|---|
| You want an agent that can rebuild **itself** against your own model | You want a pinned, stable harness → [`pi-harness`](../pi-harness/README.md) |
| You want a long-running agent with a scheduler and durable history | You want a browser UI → [`deepseek-harness`](../deepseek-harness/README.md) |
| You are willing to give it a container it can install into | You want the agent's work confined to one directory |

## How

```bash
# 1. a model, on the cluster
ws up vllm-qwen3.8-27b-nvfp4

# 2. optional: which model, and which template
cd workspaces/agent/exo-harness && cp .env.example .env && $EDITOR .env && cd -

# 3. the agent
ws up exo-harness                     # clones, builds, registers, REPL
ws up exo-harness --conversation two  # a second conversation
ws down exo-harness                   # stop the loops; state is kept
```

**The first `ws up` clones and builds**: `pnpm install`, then two cargo builds.
Measured here from a cold clone on a GB10 — **1m01s** for the `exo` crate and
**47s** for the scheduler runner, leaving 11 GB at `~/src/exo`.

### What `up.sh` does before it hands over

1. Checks docker, git, node, pnpm and cargo, naming the `make` target for each.
   (Node lives in nvm, which is a shell function rather than a binary, so a
   non-interactive shell has no `node` on `PATH` at all — `up.sh` sources
   `nvm.sh` the same way `roles/dev_node` does.)
2. Clones `~/src/exo` at the pinned commit, or warns if `HEAD` has moved.
3. Builds if the binaries are missing.
4. Warns if nothing is serving at `EXO_BASE_URL`, or if the server does not
   serve `EXO_UPSTREAM` — and names what it does serve.
5. Registers the model binding, **only if `exo model list` does not already
   have it**. Exo does not update a binding in place; a re-register would mint
   a second one with the same name.
6. Prints the log paths, then `exec`s `exo.sh`.

### Settings, in `.env`

| Variable | Default | Note |
|---|---|---|
| `EXO_BASE_URL` | `http://127.0.0.1:8888/v1` | The address you would `curl`; exo is on the host, so there is no namespace in between |
| `EXO_UPSTREAM` | `qwen3.8-27b` | The **served** name, not the HF repo id |
| **`EXO_BINDING`** | `gx10-local` | **Do not name it after an OpenAI model** — see below |
| `EXO_TEMPLATE` | `minimal` | `canonical` adds ExoChat; `dev` adds IRC and Discord |
| `LOCAL_API_KEY` | `gx10` | Any non-empty string. Stored in exo's keystore at registration |
| `EXO_SRC` | `~/src/exo` | Mirrors `~/src/verl` in [`ray-verl`](../../rl/ray-verl/README.md) |
| `EXO_REF` | `7801005e…` | Exo publishes no tags, so the pin is a commit |
| `EXO_SANDBOX_IMAGE` | `ubuntu:24.04` | What the agent installs into |

**Why the binding name matters.** Exo chooses the **OpenAI Responses API** by
model *name* — anything matching `gpt-5-codex`, `gpt-5.3`+, `o1-pro`, `o3-pro`
or `gpt-5-pro`. Call a binding `gpt-5.3-local` and exo will speak an API that
vLLM and llama.cpp do not serve, and the failure is a 404 from a URL you never
typed. Any other name gets Chat Completions, which is what these servers speak.

### Where the logs are

There is **no `container:` in the manifest**, and that is measured rather than
forgotten: exo names its sandbox `exo-<agent-hash>-<conversation-hash>`
(observed: `exo-d7ab946f4fc20aaf-3ccc4394`), so `ws logs` has no fixed name to
reach. `up.sh` prints these on every start instead:

```bash
tail -F ~/src/exo/.exo/exo-scheduler.log   # scheduled task execution
tail -F ~/src/exo/.exo/exo-adapters.log    # adapter startup and delivery
(cd ~/src/exo && pnpm events:tail)         # the durable event stream
```

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `node not found` from `ws up` | nvm is a shell function, and the role is opt-in | `make optional TAGS=node` |
| `cargo not found` | Same, for Rust | `make optional TAGS=rust` |
| `sandbox image ubuntu:24.04 is not present` | The image was removed after the first run | `up.sh` adds `--pull-sandbox` when it is missing; if you invoke `exo.sh` by hand, pass it |
| A 404 from a URL you never typed | The binding is named after an OpenAI model, so exo chose the Responses API | Register a binding with a different name |
| `!  ~/src/exo is at <sha>, pin is <sha>` | Either drift, or **the agent edited itself** | Set `EXO_REF` to adopt it, or check out the pin yourself. `up.sh` will not do it for you |
| `/exit` did not stop anything | By design — exo is long-running, and the scheduler and adapters outlive the REPL | `ws down exo-harness` |
| A second binding with the same name | `register-model` was run twice by hand | `exo model list` in the checkout; register a new name rather than a duplicate |

## Sources

- <https://github.com/exoharness/exo>
- <https://github.com/exoharness/exo/blob/main/exo/docs/EXO-BASICS.md>
- <https://github.com/exoharness/exo/blob/main/docs/RSI.md>

See also: [`workspace.yml`](workspace.yml) · [`up.sh`](up.sh) ·
[`down.sh`](down.sh) · [`.env.example`](.env.example) ·
[runbook](../../../docs/runbooks/workspaces.md)
