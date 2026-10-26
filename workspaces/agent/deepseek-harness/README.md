# deepseek-harness

> DeepSeek's own agent harness (`dsh`), pointed at a model **this cluster is
> serving** rather than at their API. Then use the thing you built.

| | |
|---|---|
| Kind | `agent` — a **client**, not a server |
| Engine | `dsh` (Node) |
| Nodes | 1 — **gb10-homer**, the idle Spark — and it claims no GPU |
| Endpoint | `http://127.0.0.1:39090` on gb10-homer (web UI; `ssh -L 39090:127.0.0.1:39090 gb10-homer`) |
| Needs | Docker and key-based ssh to the node. That is all |
| Provenance | **`verified`** — UI reached on :3080, and on :39090 on gb10-homer; `dsh` is still a **developer preview** by its own README |

## What

`node:22-slim` running `npx @deepseek-ai/dsh web --no-open` on host networking,
with two mounts: `./dsh-home` for config and credentials, and `./work` for
whatever the agent is allowed to touch.

## Why

Every other workspace here gives you an **endpoint**. Nothing gave you something
to *use* it with. `dsh` is plugin-based, MIT, a local web UI, and it takes a
custom OpenAI-compatible provider — which is exactly what a GB10 running vLLM
is.

**So the pairing is the point, and no token leaves the house:**

```bash
ws up tensorfold-2node-dsv41-flash-1017   # the model, on the cluster
ws up deepseek-harness                    # the agent, on gb10-homer, talking to it
```

### `kind: agent`, and why that is not bookkeeping

This runs no model, claims no GPU, and needs no unified memory. **It coexists
with a serving workspace**, which no two `inference` workspaces do.

### Two decisions in `compose.yml` worth knowing

- **Host networking**, for two reasons. `dsh web` serves on `127.0.0.1:3080` —
  inside a bridge network that is the *container's* loopback, so `-p 3080:3080`
  publishes a port nothing is listening on and the UI appears dead. And on host
  networking **the URL in `settings.yaml` is the URL you would `curl` from that
  node's shell** — loopback when the harness and server share a node, the head's
  mesh address when they do not. The cost is real: this container has the host's
  whole network namespace.
- **It runs as you (`1000:1000`), not root.** A container writing into
  `./dsh-home` as root leaves root-owned config you cannot edit without sudo —
  and `.credentials.yaml` is exactly the file you will want to edit.

## Two honest warnings

1. **It is a developer preview** by its own README, with compatibility changes
   ongoing — and one of them landed: **0.2.1 moved provider config out of
   `settings.yaml` into Cordis patch layers** and rejects the `llm-pi-ai`
   section on import, so the harness fell back to DeepSeek's hosted route with
   `MISSING_CREDENTIAL` (measured 2026-10-25). This workspace therefore pins
   **`DSH_VERSION=0.1.5-rc.1`**, the version its `settings/` catalogue is
   written for. Unpin deliberately, not by accident; the forward path is a
   `$DSH_HOME/cordis.patch.yml` home patch, which one file covers for every
   profile (web, headless, acp, sdk).
2. **It is an agent harness.** It executes tool calls against whatever you mount
   at `/work`, on host networking. The default mount is `./work` — a directory
   that starts **empty** — rather than `$HOME`, and **that default is the
   security design, not an inconvenience to route around.** Give it a project.

## When to use it — and when not

| Use it when | Use something else when |
|---|---|
| You want to actually use a model this cluster serves | You want to measure it → [`vllm-bench-serve`](../../bench/vllm-bench-serve/README.md) |
| You want agentic tool use with nothing leaving the house | You want to know it is answering correctly → [`vllm-quality-gate`](../../bench/vllm-quality-gate/README.md) |
| You want to compare your server against DeepSeek's hosted API | You need a stable, pinned tool — this is a preview |

## Where the harness runs

**On gb10-homer, not on the head.** A client holds no GPU and no unified memory,
so putting it on a node that is serving buys nothing and costs something: the
head is the node `memguard` watches, and odysseus sat at **3.3 GiB MemAvailable**
against a 2.5 GiB kill floor while the 1017 server ran. The harness is ~100 MB;
it is not the reason the head is tight, but it is the one thing in the pair that
can leave.

`up.sh` is what moves it. It writes the settings file **on the node**, rsyncs
`compose.yml` and `.env` there, and starts compose over ssh:

```bash
cd workspaces/agent/deepseek-harness
./up.sh                 # HARNESS_HOST=gb10-homer by default
./ask.sh "what is in /work?"
./down.sh
```

`ws up`, `ws down` and `ws logs` call those scripts, so the usual verbs still
work:

```bash
ws up   deepseek-harness
ws logs deepseek-harness -f
ws down deepseek-harness
```

**`ws status` is the one verb that stays local.** It asks each workspace's own
docker, and the harness's container is on another machine. Use
`ssh gb10-homer docker ps` for it; saying so is better than a command that
reports "no workspace is running" while one is.

`HARNESS_HOST=local` runs it here, unchanged. The bundle on the node is
`~/ws-deepseek-harness/`; `dsh-home/` is the node's own state and no script here
deletes it.

## Reaching the server

The 1017 server stays on odysseus and binds `0.0.0.0:8903`. From gb10-homer
there are two paths, and only one of them is open today:

| Path | Address | Status |
|---|---|---|
| **Mesh** | `http://<head-mesh>:8903` | **works** — `/health` 200 in 98 ms. odysseus's ufw allows the nordlynx interface wholesale, and homer's mesh address explicitly |
| LAN | `http://<head-LAN>:8903` | **blocked** — `ping` and `:22` work over the LAN (8–13 ms), but odysseus's default-deny policy allows only `22/tcp from 192.168.0.0/16`; `:8903` from homer's LAN subnet is dropped |

So `up.sh` defaults to the mesh: it takes the head's nordlynx address and
rewrites the one `baseURL:` line to it. `127.0.0.1:8903` is correct **only when
the harness runs on odysseus** — on gb10-homer it is homer's own loopback, where
nothing listens.

To use the LAN instead, two things must change: the firewall and `.env`.

1. Allow `:8903` from homer's LAN address on the head. This belongs in the play,
   not in a hand-typed rule: `roles/remote` writes the peer rules from
   `cluster_peer_mgmt_addrs`, which is each peer's **`ansible_host`** — for
   homer that is its mesh address by inventory design, so the LAN source has no
   home in that list today. A port-scoped rule (or an `ufw_extra_sources` list)
   has to be added to the role and then applied with `make apply`. A hand-typed
   `ufw allow` survives until the next converge rewrites the policy, and the
   failure after that is a silent timeout again.
2. Set `HARNESS_ENDPOINT=http://<head-LAN>:8903` in `.env` and re-run
   `./up.sh`.

**The web UI stays on the node's loopback**, so it is reached with a tunnel
regardless of which server path you pick:

```bash
ssh -L 39090:127.0.0.1:39090 gb10-homer
ssh gb10-homer docker logs ws-deepseek-harness | grep -o 'http://[^ ]*token=[^ ]*'
```

## How

```bash
# 1. a model, on the cluster. The 1017 recipe is what this workspace ships
#    settings for; any of the ten in `./use.sh` works.
ws up tensorfold-2node-dsv41-flash-1017

# 2. the agent, on the node that is not holding a rank. `ws up` runs up.sh,
#    which deploys it to gb10-homer and points it at the 1017 server.
ws up   deepseek-harness              # -> gb10-homer, :39090 (tunnel to it)
ws logs deepseek-harness -f
ws down deepseek-harness
```

`up.sh` refuses before starting anything if the node cannot reach the endpoint,
and `use.sh` (which `up.sh` calls) warns if the server is up but serving a
different id.

**First start downloads the npm tree before it binds anything** — the
healthcheck's `start_period` is 12 minutes for that reason.

## Pointing it at a model

dsh reads exactly one file: `dsh-home/settings.yaml`, which `compose.yml`
mounts. So "switch model" means **put a different file there**, and that is all
[`use.sh`](use.sh) does — plus the one check worth doing. When `HARNESS_HOST` is
another node, `use.sh` writes it **there** and rewrites the `baseURL:` line to
that node's view of the server, so `./use.sh <recipe>` switches the harness
wherever it runs.

```bash
./use.sh                                  # what is available, and what is active
./use.sh vllm-2node-deepseek-v4-flash     # switch
./use.sh --port 8891                      # build one from a RUNNING server
```

[`settings/`](settings/) holds one file per serving workspace, **named after the
workspace rather than the model** — two of them serve the same model name on
different ports, so the workspace is the only key that is unique:

| `use.sh <this>` | Port | `models[].id` |
|---|---|---|
| [`tensorfold-2node-dsv41-flash-1017`](../../inference/tensorfold-2node-dsv41-flash-1017/README.md) | 8903 | `DeepSeek-V4.1-Flash-1017` — **the recipe `.env` now deploys to gb10-homer** |
| [`vllm-2node-qwen38-flash-next`](../../inference/vllm-2node-qwen38-flash-next/README.md) | 8896 | `qwen3.8-flash-next` — **the default** |
| [`vllm-2node-deepseek-v4-flash`](../../inference/vllm-2node-deepseek-v4-flash/README.md) | 8890 | `deepseek-v4-flash` |
| [`vllm-2node-glm53-flash-exl3`](../../inference/vllm-2node-glm53-flash-exl3/README.md) | 8893 | `glm-5.3-flash-exl3` |
| [`vllm-2node-dsv41-flash-exl3`](../../inference/vllm-2node-dsv41-flash-exl3/README.md) | 8897 | `DeepSeek-v4.1-Flash-EXL3` — that workspace is `unverified` |
| [`vllm-nemotron35-lightning-nvfp4`](../../inference/vllm-nemotron35-lightning-nvfp4/README.md) | 8895 | `nemotron-3.5-lightning` |
| [`sglang-nemotron35-lightning-nvfp4`](../../inference/sglang-nemotron35-lightning-nvfp4/README.md) | 8894 | `nemotron-3.5-lightning` — same name, different port |
| [`vllm-qwen3.8-27b-nvfp4`](../../inference/vllm-qwen3.8-27b-nvfp4/README.md) | 8888 | `qwen3.8-27b` |
| [`vllm-2node-tp2`](../../inference/vllm-2node-tp2/README.md) | 8888 | `nemotron-120b` — generic recipe, so it follows your `SERVED_NAME` |
| [`sglang-qwen3.8-27b-int4`](../../inference/sglang-qwen3.8-27b-int4/README.md) | 8900 | `RedHatAI/Qwen3.8-27B-INT4` — no alias is passed, so SGLang echoes the model path |

**The three llama.cpp workspaces are deliberately absent** — 8891, 8892 and
8899 pass no `--alias`, so their id is whatever llama.cpp derived from the GGUF
and this repo cannot ship it honestly. `./use.sh --port 8891` asks the server
and writes the answer.

### Why `use.sh` curls the server

`models[].id` must be the **served** name (`--served-model-name`), not the HF
repo id — and a wrong one **does not fail at startup**. dsh binds its UI port, the UI
loads, and the error arrives on the first message, long after you stopped
thinking about settings. So `use.sh` asks the endpoint what it actually serves
and says so before you open the tab. A server that is not up yet is a `note`,
not a failure; a server that is up and serving something else is a `warn` that
prints the real ids.

### The file, in one look

```yaml
llm-pi-ai:            # providers live under the plugin that owns them
  providers:
    gx10:             # lowercase id, yours to choose; the UI lists it
      apiKeyEnv: LOCAL_API_KEY     # read from the ENV, not stored in this file
      api: openai-completions
      baseURL: http://127.0.0.1:8896/v1
      models:
        - id: qwen3.8-flash-next   # the SERVED name, not the HF repo id
```

Every file also carries an `agent-default-model` block, and **it is the half
that is easy to miss**:

```yaml
agent-default-model:
  provider: gx10
  model: qwen3.8-flash-next
```

Defining a provider does not *select* one. Without those two lines dsh keeps
its shipped default — provider `deepseek-official`, model `deepseek-flash`,
DeepSeek's **hosted** API — so the harness never touches the cluster and
`--profile headless` fails outright:

```
dsh: MISSING_CREDENTIAL: llm-deepseek: no API key for provider route
"deepseek-official"; store DEEPSEEK_API_KEY through the credentials service
```

That error names a key, which reads like a credentials problem. It is not: the
fix is to point the default at the provider you already configured. `use.sh`
writes the block and warns if a file lacks it.

**The web UI writes back into this file.** Observed on a first visit: it appends
`ui-onboarding: welcomeNoticeVersion`, and the Models page persists through the
same settings service. So switching is not a pure copy onto a file only `use.sh`
owns — it drops whatever the UI put there. That is survivable, because dsh
rewrites its own preferences, but it is never silent: the outgoing file is kept
as `dsh-home/settings.yaml.prev` and the lost top-level keys are named.

```
kept  dsh-home/settings.yaml.prev - these top-level keys are not in the new file:
        ui-onboarding
```

Host networking means `baseURL` is literally the URL you would `curl` — if it
works in your shell, it works in the container. `apiKeyEnv` names an
**environment variable**, which is why these files are tracked in git and
`dsh-home/` is not: no key is ever written into one.

To reach DeepSeek's hosted API for comparison, add a second provider with
`baseURL: https://api.deepseek.com/v1` and `apiKeyEnv: DEEPSEEK_API_KEY`.
Leaving `DEEPSEEK_API_KEY` unset is a reasonable way to guarantee nothing
reaches DeepSeek at all.

### Settings, in `.env`

| Variable | Default | Note |
|---|---|---|
| **`HARNESS_HOST`** | `gb10-homer` | The ssh target the harness runs on. `local` keeps it on this machine |
| **`HARNESS_ENDPOINT`** | derived | The server, **without `/v1`**: the recipe's loopback URL when local, else the head's nordlynx address. See [Reaching the server](#reaching-the-server) |
| `HARNESS_SETTINGS` | `tensorfold-2node-dsv41-flash-1017` | Which file in `settings/` `up.sh` deploys |
| `DSH_PORT` | `3080` | The web UI port. Set it when the node already uses 3080 — **gb10-homer uses 39090** because VS Code's extension host holds a wide forwarded-port set there (3080, 3081, 8896, 8903, …) |
| **`DSH_WORKSPACE`** | `./work` | **The one setting worth thinking about.** Point it at a project, not at `$HOME` |
| `LOCAL_API_KEY` | `gx10` | Any non-empty string — a local server ignores the value, but the client library refuses to send a request without one |
| `DEEPSEEK_API_KEY` | unset | Leaving it unset is a reasonable way to guarantee nothing reaches DeepSeek |
| `DSH_VERSION` | `0.1.5-rc.1` | **Pinned**: 0.2.1 moved provider config to Cordis patches and rejects `settings.yaml`'s `llm-pi-ai` section |
| `DSH_UID` / `DSH_GID` | `1000` | Set if `id -u` says otherwise, or `./dsh-home` fills with files you cannot edit |

## The five profiles

A profile is an ordered stack of plugin-bundle patch layers, and **all five
compose over the same `dsh-base`** — same model adapters, same tools, same
persistence, same sandbox policy, same settings and credentials. What differs is
the transport and the session lifecycle, nothing about the agent itself.

| Profile | Transport | Audience | Lifetime | Conversation | Ports |
|---|---|---|---|---|---|
| **`web`** | HTTP + browser GUI | a person | until `ws down` | yes | :3080 (39090 here) |
| **`headless`** | argv in, stdout out | a person, or a script | one task, then exits | no — one turn | none |
| **`acp`** | [ACP](https://agentclientprotocol.com) v1 JSON-RPC over stdio | another **program** | until the client disconnects | yes, and resumable | none |
| `sdk` / `sdk-minimal` | DeepSeek's own JSON-RPC over stdio | another program | until shutdown | — | none |

`desktop` is a sixth name, reserved for the Electron build; the CLI rejects it.

**`web`** is the only one with a model dropdown, settings pages and session
history. Startup prints an **authenticated** URL — that is the `?token=`, and it
is the only URL that opens. It can change port and allow extra hosts but
**cannot bind all interfaces**, which is precisely why `compose.yml` uses host
networking instead of publishing a port.

**`headless`** works one task and prints the final answer. No GUI, no server, no
port, nothing left running. One fresh persisted session per invocation, no
interactive follow-up, no resume. **Its exit code is the outcome** — 0
completed, 1 aborted or errored — which is what makes it scriptable;
[`ask.sh`](ask.sh) `exec`s, so that code reaches your shell.

**`acp`** is a server, not a UI: stdout is reserved for newline-delimited
JSON-RPC frames, so a human who runs it just sees frames. A client initializes
it, calls `session/new` with an absolute `cwd` and optional MCP declarations,
picks a model or reasoning effort, prompts while observing updates, then calls
`session/close`; another process can `session/list` and `session/resume` against
the same persistence root, though resume reconnects MCP declarations rather than
replaying history. Deletion, forks, transcript replay and extra directories are
unsupported, and model-generated session titles are switched off because ACP has
nowhere to show one. It is meant for out-of-process subagents, test runners and
scripted controllers — **and it needs a client this cluster does not have**: the
neovim `roles/editor` installs has no ACP plugin configured.

> One trap if you reach for `acp`: its bundle ships its own default route of
> `deepseek-official` / `deepseek-v4-flash`, the same shape as the one that bites
> `headless`. The `agent-default-model` block in `settings.yaml` sits above the
> bundle layer and should win — but **that is read off the patch order, not
> measured.** Nothing in this repo has run `acp`.

## From a terminal

**There is no TUI**, and the confusion is dsh's own: its README shows
`dsh --profile tui --resume <id>` in an examples block, annotated *"assuming
the tui profile is installed"*. Nothing installs it. The shipped bundles are
`dsh-base`, `dsh-web-app`, `dsh-headless`, `dsh-sdk-app`, `dsh-sdk-minimal` and
`dsh-acp-app`; `@deepseek-ai/dsh-tui`, `-dsh-tui-app`, `-dsh-terminal-app` and
`-dsh-cli-app` are all **404 on npm**. So `headless` is the terminal mode:

```bash
./ask.sh "summarise what up.sh does, in three lines"
echo "what is in /work?" | ./ask.sh
./ask.sh < prompt.txt
```

[`ask.sh`](ask.sh) runs `--profile headless` **inside the container that is
already up**, so it shares the settings, the cached npm tree and the `/work`
mount with the web UI — and therefore the same tool access, which is the only
boundary there is. Each call is a fresh session: headless persists one but
never resumes one, so this is one question and one answer, not a conversation.
For a conversation, use the web UI.

## Where your data lives

Everything dsh writes goes to **`$DSH_HOME`, which `compose.yml` mounts from
`./dsh-home`** — nothing lands in the container layer, which is why a restart
costs seconds rather than another 470 MB of npm. Measured on a running instance:

| Path | What | Mode | Size here |
|---|---|---|---|
| `dsh-home/settings.yaml` | providers, `agent-default-model` — what [`use.sh`](use.sh) writes, **plus whatever the UI appends** | `0600` | 1.6 K |
| `dsh-home/settings.yaml.prev` | the previous one, kept by `use.sh` on every switch | | 1.6 K |
| `dsh-home/.credentials.yaml` | the credentials store. **Right now it holds the web UI's browser-session token, not a model key** — `apiKeyEnv` means the model key never reaches disk | `0600` | 161 B |
| `dsh-home/sessions/<workspace>/<session-id>/` | **every prompt and every answer**, as `session.v3.jsonl.zstd` | `0700` | 116 K |
| `dsh-home/storages/` | workspace and session-projection cache — ids, titles, which sessions are archived | | 48 K |
| `dsh-home/profiles/<name>/` | one directory per profile you have booted, with its `cordis.patch.yml` and its own `node_modules` | | 1.6 M |
| `dsh-home/.anonymous-user-id` | a local install id | | 37 B |
| `dsh-home/.npm/` | the npx package tree, cached so restarts are fast | | **470 M** |
| `${DSH_WORKSPACE:-./work}` → `/work` | whatever the agent creates or edits | | — |

**There is no separate memory store.** dsh's long-term state *is* the session
transcript, compacted in place (`dsh-compaction`); the skill plugins
(`dsh-skill`, `dsh-skill-filesystem`, `dsh-tool-skill`) are **disabled** in the
web profile, so they write nothing. Persistent memory is an opt-in MCP overlay
from dsh's own `config/examples/`, which this workspace does not enable.

### Yes, all of it is gitignored

```
workspaces/**/.env
workspaces/agent/*/dsh-home/*
!workspaces/agent/*/dsh-home/.gitkeep
workspaces/agent/*/work/*
!workspaces/agent/*/work/.gitkeep
```

The trailing `*` is doing real work: ignoring the *contents* rather than the
directory means git never descends, so no `git add -A` and no explicit path can
pull in a transcript or the 470 MB cache. Verified with `git check-ignore` —
`settings.yaml`, `.credentials.yaml`, `sessions/`, `storages/`, `profiles/`,
`.npm/` and `.anonymous-user-id` all report ignored; the only tracked things in
either directory are the two `.gitkeep` files.

[`settings/`](settings/) is tracked **on purpose** and holds no secret: every
file names an environment variable via `apiKeyEnv` instead of carrying a key.

**One thing this repo cannot protect.** The moment you point `DSH_WORKSPACE` at
a real project, the agent's output lands in *that* tree under *that* repo's
`.gitignore`, not this one. Scoping it is the whole security design — see
[the second warning](#two-honest-warnings).

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| Nothing on the UI port, and `ws status` says `unhealthy` | First start is still resolving the npm tree — measured at ~7.5 minutes and ~476 MB here, during which nothing is listening | Wait, and watch `ws logs deepseek-harness -f` for `dsh web: http://127.0.0.1:<DSH_PORT>`. `start_period` is 12m for this reason; health does not trigger a restart, so an `unhealthy` first start is not a loop |
| `EADDRINUSE 127.0.0.1:3080` in the logs, container restarting | Another process on the node owns dsh's default port — on gb10-homer, VS Code's extension-host node service holds it | Set `DSH_PORT=39090` in `.env` and re-run `./up.sh`; tunnel to that port |
| Cannot reach the model | `baseURL`, an empty API key, or a firewall between the node and the server | Host networking means the URL in `settings.yaml` is the URL **that node** would `curl`. `./use.sh` tells you which of the two it is; `up.sh` checks reachability from the node before it starts anything |
| `up.sh` says the node cannot reach the endpoint | The mesh is down, or you set a LAN endpoint without the ufw rule | nordlynx up on both nodes; or add the `:8903` rule and `make apply` — see [Reaching the server](#reaching-the-server) |
| Nothing on the UI port on the head, though `ws logs` shows `dsh web:` | The UI binds **127.0.0.1 on gb10-homer**; the head's loopback is a different one | `ssh -L 39090:127.0.0.1:39090 gb10-homer`, then open the tokenised URL |
| `ws status` says no workspace is running | It is local-only by design | `ssh gb10-homer docker ps` |
| `ask.sh` says the container is not running | It looks on `HARNESS_HOST`, which may not be where you started it | Check `HARNESS_HOST` in `.env`, or `ssh <node> docker ps` |
| The UI errors on the first message only | `models[].id` is not the name the server answers to | `./use.sh <workspace>` — it prints the real ids when they disagree |
| Switched model and nothing changed | dsh reads `settings.yaml` at startup | `ws down deepseek-harness && ws up deepseek-harness` |
| `MISSING_CREDENTIAL: ... deepseek-official` | The provider is defined but not selected — dsh is still on its hosted default | Add `agent-default-model` (see above), or just re-run `./use.sh <workspace>` |
| The web UI shows a login or an empty page | `dsh web` prints a **tokenised** URL and only that URL works | `ws logs deepseek-harness \| grep 'dsh web:'` — open the `?token=…` link it printed |
| UI sits on "Thinking…" until the whole answer lands | A field name, not a stall: these runtimes stream the trace as `reasoning`, OpenAI-compatible clients read `reasoning_content` | Nothing to fix on the server |
| `./dsh-home` files are root-owned | `DSH_UID`/`DSH_GID` do not match you | Set them; `sudo chown -R $(id -u):$(id -g) dsh-home` |
| The agent touched something you did not expect | It has tool access to everything under `/work` | That is what `DSH_WORKSPACE` is for. Scope it |
| It behaves differently after a restart | `latest` moved | Pin `DSH_VERSION=0.1.5-rc.1` |
| `MISSING_CREDENTIAL: ... deepseek-official` right after an upgrade | 0.2.x imports `settings.yaml` once and rejects the `llm-pi-ai` section, falling back to the hosted route | Pin `DSH_VERSION=0.1.5-rc.1`, or move the provider to `$DSH_HOME/cordis.patch.yml` — the home patch outranks every profile |

## Sources

- <https://github.com/deepseek-ai/deepseek-harness>
- <https://deepseek-harness.github.io/deepseek-harness/en/guide/providers>

See also: [`workspace.yml`](workspace.yml) · [`compose.yml`](compose.yml) ·
[`use.sh`](use.sh) · [`ask.sh`](ask.sh) · [`settings/`](settings/) ·
[runbook](../../../docs/runbooks/workspaces.md)
