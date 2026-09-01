# deepseek-harness

> DeepSeek's own agent harness (`dsh`), pointed at a model **this cluster is
> serving** rather than at their API. Then use the thing you built.

| | |
|---|---|
| Kind | `agent` — a **client**, not a server |
| Engine | `dsh` (Node) |
| Nodes | 1, and it claims no GPU |
| Endpoint | `http://127.0.0.1:3080` (web UI) |
| Needs | Docker. That is all |
| Provenance | **`verified`** — UI reached on :3080; `dsh` is still a **developer preview** by its own README |

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
ws up vllm-2node-deepseek-v4-flash    # the model, on the cluster
ws up deepseek-harness                # the agent, talking to it
```

### `kind: agent`, and why that is not bookkeeping

This runs no model, claims no GPU, and needs no unified memory. **It coexists
with a serving workspace**, which no two `inference` workspaces do.

### Two decisions in `compose.yml` worth knowing

- **Host networking**, for two reasons. `dsh web` serves on `127.0.0.1:3080` —
  inside a bridge network that is the *container's* loopback, so `-p 3080:3080`
  publishes a port nothing is listening on and the UI appears dead. And the
  model server is also on loopback, so on host networking **the URL in
  `settings.yaml` is the URL you would `curl`**. The cost is real: this
  container has the host's whole network namespace.
- **It runs as you (`1000:1000`), not root.** A container writing into
  `./dsh-home` as root leaves root-owned config you cannot edit without sudo —
  and `.credentials.yaml` is exactly the file you will want to edit.

## Two honest warnings

1. **It is a developer preview** by its own README, with compatibility changes
   ongoing. `latest` is unpinned here deliberately — a month-old pin of a
   preview is its own kind of broken. Pin `DSH_VERSION` once a version works for
   you.
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

## How

```bash
# 1. a model, on the cluster
ws up vllm-2node-deepseek-v4-flash

# 2. config — this is the whole point of the workspace
cd workspaces/agent/deepseek-harness
mkdir -p dsh-home work
cp settings.example.yaml dsh-home/settings.yaml
$EDITOR dsh-home/settings.yaml        # baseURL + the SERVED model name
cd -

# 3. the agent
ws up   deepseek-harness              # -> http://127.0.0.1:3080
ws logs deepseek-harness -f
ws down deepseek-harness
```

**First start downloads the npm tree before it binds anything** — the
healthcheck's `start_period` is 3 minutes for that reason.

### `settings.yaml`, in one look

```yaml
llm-pi-ai:            # providers live under the plugin that owns them
  providers:
    gx10:             # lowercase id, yours to choose; the UI lists it
      apiKeyEnv: LOCAL_API_KEY     # read from the ENV, not stored in this file
      api: openai-completions
      baseURL: http://127.0.0.1:8890/v1
      models:
        - id: deepseek-v4-flash    # the SERVED name, not the HF repo id
```

Two things people get wrong here:

- **`baseURL` must match a running server.** The ports in use:

  | Port | Workspace |
  |---|---|
  | 8888 | [`vllm-qwen3.8-27b-nvfp4`](../../inference/vllm-qwen3.8-27b-nvfp4/README.md), [`vllm-2node-tp2`](../../inference/vllm-2node-tp2/README.md) |
  | 8890 | [`vllm-2node-deepseek-v4-flash`](../../inference/vllm-2node-deepseek-v4-flash/README.md) |
  | 8891 | [`llamacpp-deepseek-v4-flash-gguf`](../../inference/llamacpp-deepseek-v4-flash-gguf/README.md) |
  | 8899 | [`llamacpp-qwen3.8-27b-gguf`](../../inference/llamacpp-qwen3.8-27b-gguf/README.md) |
  | 8900 | [`sglang-qwen3.8-27b-int4`](../../inference/sglang-qwen3.8-27b-int4/README.md) |

- **`models[].id` is the *served* name**, which `--served-model-name` set — not
  the HF repo id. `curl -s localhost:8890/v1/models` prints exactly this.

### Settings, in `.env`

| Variable | Default | Note |
|---|---|---|
| **`DSH_WORKSPACE`** | `./work` | **The one setting worth thinking about.** Point it at a project, not at `$HOME` |
| `LOCAL_API_KEY` | `gx10` | Any non-empty string — a local server ignores the value, but the client library refuses to send a request without one |
| `DEEPSEEK_API_KEY` | unset | Leaving it unset is a reasonable way to guarantee nothing reaches DeepSeek |
| `DSH_VERSION` | `latest` | Pin it once a version works |
| `DSH_UID` / `DSH_GID` | `1000` | Set if `id -u` says otherwise, or `./dsh-home` fills with files you cannot edit |

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| Nothing on :3080, and `ws status` says `unhealthy` | First start is still resolving the npm tree — measured at ~7.5 minutes and ~476 MB here, during which nothing is listening | Wait, and watch `ws logs deepseek-harness -f` for `dsh web: http://127.0.0.1:3080`. `start_period` is 12m for this reason; health does not trigger a restart, so an `unhealthy` first start is not a loop |
| Cannot reach the model | `baseURL`, or an empty API key | It is host networking — **if `curl` works from your shell, the same URL works** |
| UI sits on "Thinking…" until the whole answer lands | A field name, not a stall: these runtimes stream the trace as `reasoning`, OpenAI-compatible clients read `reasoning_content` | Nothing to fix on the server |
| `./dsh-home` files are root-owned | `DSH_UID`/`DSH_GID` do not match you | Set them; `sudo chown -R $(id -u):$(id -g) dsh-home` |
| The agent touched something you did not expect | It has tool access to everything under `/work` | That is what `DSH_WORKSPACE` is for. Scope it |
| It behaves differently after a restart | `latest` moved | Pin `DSH_VERSION` |

## Sources

- <https://github.com/deepseek-ai/deepseek-harness>
- <https://deepseek-harness.github.io/deepseek-harness/en/guide/providers>

See also: [`workspace.yml`](workspace.yml) · [`compose.yml`](compose.yml) ·
[`settings.example.yaml`](settings.example.yaml) ·
[runbook](../../../docs/runbooks/workspaces.md)
