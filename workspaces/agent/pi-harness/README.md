# pi-harness

> [Pi](https://pi.dev) — a terminal coding harness — in a container, pointed at
> a model **this cluster is serving**. The sibling of
> [`deepseek-harness`](../deepseek-harness/README.md), in the terminal you are
> already in.

| | |
|---|---|
| Kind | `agent` — a **client**, not a server |
| Engine | `pi` (Node, `@earendil-works/pi-coding-agent`) |
| Nodes | 1, and it claims no GPU |
| Endpoint | your terminal. `ws up pi-harness -p '…'` for print mode |
| Needs | Docker. That is all |
| Provenance | **`verified`** — image built and a prompt round-tripped on a GB10 |

## What

`node:24-bookworm-slim` with pi installed globally, run as **you** on host
networking, with two mounts: `./pi-agent` for config, credentials and sessions,
and `./work` for whatever the agent is allowed to touch.

The image is **upstream's own** `Dockerfile.pi` from
[`docs/containerization.md`](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/containerization.md),
with three changes, each commented in [`Dockerfile`](Dockerfile): a pinned
version that is also the image tag, `PI_CODING_AGENT_DIR` instead of `$HOME`
games so the container need not run as root, and no `ENTRYPOINT` so
`ws up pi-harness -- bash` can look around.

## Why, when `deepseek-harness` already exists

Both are agents pointed at your own server. They are not the same tool:

| | [`deepseek-harness`](../deepseek-harness/README.md) | `pi-harness` |
|---|---|---|
| Shape | Web UI on `:3080` | **TUI**, in your terminal |
| Release | Developer preview, `npx` on every start | Published npm package, baked into a layer |
| Start cost | ~7.5 min first run, npm resolution | ~40 s once, then instant |
| Scriptable | No | **`-p`, `--mode json`, `--mode rpc`** |

That last row is the reason to have both:

```bash
ws up pi-harness -p 'summarise what changed in this repo this week' | tee report.md
```

**And the pairing is still the point — no token leaves the house:**

```bash
ws up vllm-qwen3.8-27b-nvfp4    # the model, on the cluster
ws up pi-harness                # the agent, talking to it
```

### `kind: agent`, and why that is not bookkeeping

It runs no model, claims no GPU, and needs no unified memory. **It coexists
with a serving workspace**, which no two `inference` workspaces do.

## Two honest warnings

1. **Pi ships no permission system.** That is upstream's own wording, not a
   caveat this repo invented: `read`, `write`, `edit` and `bash` run with the
   process's full rights. **The container is the boundary**, and `PI_WORKSPACE`
   is the whole of it — which is why it defaults to an empty `./work` rather
   than to `$HOME`. Give it a project.
2. **Host networking** gives the container the host's entire network namespace.
   It buys the thing that makes this work at all: `127.0.0.1:8888` means the
   same address on both sides of the mount, so **the URL in `models.json` is
   the URL you would `curl`**.

## When to use it — and when not

| Use it when | Use something else when |
|---|---|
| You want an agent **in the terminal**, or in a pipe | You want a browser UI → [`deepseek-harness`](../deepseek-harness/README.md) |
| You want agentic tool use with nothing leaving the house | You want to measure the server → [`vllm-bench-serve`](../../bench/vllm-bench-serve/README.md) |
| You want a pinned, published harness | You want the agent to rewrite **itself** → [`exo-harness`](../exo-harness/README.md) |

## How

```bash
# 1. a model, on the cluster
ws up vllm-qwen3.8-27b-nvfp4

# 2. optional: which model, and what the agent may touch
cd workspaces/agent/pi-harness && cp .env.example .env && $EDITOR .env && cd -

# 3. the agent
ws up pi-harness                      # the TUI
ws up pi-harness -p 'hello'           # one answer, then exit
ws up pi-harness --list-models        # is the binding right?
ws down pi-harness                    # only needed if a session detached
```

**The first `ws up` builds the image** — about 40 seconds, once per
`PI_VERSION` — and **seeds `pi-agent/models.json`** from your `.env`.

### `models.json`, in one look

`up.sh` writes it on the first run and then never touches it again; delete it
to re-seed. There is deliberately **no tracked `models.example.json`**: the
port and the model name already live in `.env`, and two files saying the same
thing drift apart.

```json
{
  "providers": {
    "gx10": {
      "baseUrl": "http://127.0.0.1:8888/v1",
      "api": "openai-completions",
      "apiKey": "$LOCAL_API_KEY",
      "compat": {
        "supportsDeveloperRole": false,
        "supportsReasoningEffort": false
      },
      "models": [{ "id": "qwen3.8-27b" }]
    }
  }
}
```

Four things people get wrong here:

- **`compat` is not optional for these servers.** Upstream names vLLM, SGLang
  and Ollama specifically: they do not understand the `developer` role that pi
  sends for reasoning-capable models, and `reasoning_effort` goes the same way.
  Both are off by default here.
- **`models[].id` is the *served* name**, which `--served-model-name` set — not
  the HF repo id. `curl -s localhost:8888/v1/models` prints exactly this. (The
  llama.cpp workspaces are the exception: they serve under the HF repo id.)
- **`apiKey` must be something.** A local server ignores the value, but pi
  hides a provider with **no configured auth** from `/model` entirely — so the
  models load, never appear, and `models.json` looks broken.
- **`baseURL` must match a running server.** The ports in use:

  | Port | Workspace |
  |---|---|
  | 8888 | [`vllm-qwen3.8-27b-nvfp4`](../../inference/vllm-qwen3.8-27b-nvfp4/README.md), [`vllm-2node-tp2`](../../inference/vllm-2node-tp2/README.md) |
  | 8890 | [`vllm-2node-deepseek-v4-flash`](../../inference/vllm-2node-deepseek-v4-flash/README.md) |
  | 8891 | [`llamacpp-deepseek-v4-flash-gguf`](../../inference/llamacpp-deepseek-v4-flash-gguf/README.md) |
  | 8899 | [`llamacpp-qwen3.8-27b-gguf`](../../inference/llamacpp-qwen3.8-27b-gguf/README.md) |
  | 8900 | [`sglang-qwen3.8-27b-int4`](../../inference/sglang-qwen3.8-27b-int4/README.md) |

  `up.sh` checks it for you and names what the server *does* serve when the
  model id is wrong — a warning, not a gate, because a two-node recipe that is
  still loading is worth starting an agent against.

### Settings, in `.env`

| Variable | Default | Note |
|---|---|---|
| **`PI_WORKSPACE`** | `./work` | **The one setting worth thinking about.** Point it at a project, not at `$HOME` |
| `PI_BASE_URL` | `http://127.0.0.1:8888/v1` | Seeds `models.json`; ignored once it exists |
| `PI_MODEL_ID` | `qwen3.8-27b` | The **served** name |
| `LOCAL_API_KEY` | `gx10` | Any non-empty string — the same variable `deepseek-harness` uses |
| `PI_OFFLINE` | `1` | Startup network calls only: update checks, package updates, telemetry. Model requests are unaffected |
| `PI_VERSION` | `0.84.4` | Also the image tag, so a bump rebuilds rather than reusing the layer |
| `PI_CONTAINER` | `ws-pi-harness` | Change it to run two sessions at once |

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `/model` is empty, or `--list-models` prints nothing | The provider has no auth, so pi hides it | `LOCAL_API_KEY` must be non-empty and `models.json` must reference it as `"$LOCAL_API_KEY"` |
| 400s mentioning `developer` or `reasoning_effort` | The `compat` block is missing | Both flags are `false` in the seeded file; if you rewrote it, put them back |
| `container 'ws-pi-harness' already exists` | A session was detached with Ctrl-P Ctrl-Q, or its terminal died | `ws down pi-harness`, or set `PI_CONTAINER` for a second session |
| Files in `work/` are root-owned | You edited `up.sh` to drop `--user` | It passes `$(id -u):$(id -g)`; put it back |
| Model answers, but knows nothing about your project | `PI_WORKSPACE` still points at the empty `./work` | That is the default, and it is the security design. Point it at the project |
| It behaves differently after a rebuild | `PI_VERSION` moved | It is pinned in `.env.example`; pin yours |

## Sources

- <https://github.com/earendil-works/pi>
- <https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/models.md>
- <https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/containerization.md>
- <https://www.npmjs.com/package/@earendil-works/pi-coding-agent>

See also: [`workspace.yml`](workspace.yml) · [`Dockerfile`](Dockerfile) ·
[`up.sh`](up.sh) · [`.env.example`](.env.example) ·
[runbook](../../../docs/runbooks/workspaces.md)
