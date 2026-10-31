# agentic-replay

The same agentic workload on two models, so long-running coding can be compared
by measurement on this hardware. `provenance: unverified`: see
[What has and has not been run](#what-has-and-has-not-been-run).

## Why this and not the bench next to it

| | Tools in the request | Conversation | Scores coding |
|---|---|---|---|
| `decode-content-mix` | no | one user message | no |
| `vllm-prefill-ladder` | no | no | no |
| `quant-quality-ab` | no | no | answers, not code |
| `deepseek-harness` | yes | yes, but not repeatable | by hand |
| **`agentic-replay`** | **yes** | **yes, deterministic** | **hidden tests** |

Reach for it when the question is which model, or which configuration, holds up
across a long tool conversation. Prompt length alone does not explain the kills on
the DeepSeek server: all seven with rank logs came with the prompt cache at 433 to
497 MiB. So `soak` fills the cache with many distinct conversations.

## Modes

```bash
REV=$(git rev-parse HEAD)
export BASE_URL=http://HOST:8903/v1
LOG=$HOME/.cache/dsv41-tensorfold/logs/memguard.log

ws up agentic-replay replay --corpus-rev "$REV" --label dsv41 --nodes odysseus,poseidon --memguard-log "$LOG"
ws up agentic-replay soak   --corpus-rev "$REV" --label dsv41 --duration 3600 --nodes odysseus,poseidon --memguard-log "$LOG"
ws up agentic-replay task   --corpus-rev "$REV" --label dsv41 --prefix-tokens 100000 --repeats 3
ws up agentic-replay compare DIR_A DIR_B
```

| Mode | Does | Runs from |
|---|---|---|
| `replay` | One scripted tool conversation growing by byte steps, with recall probes on branches. No model output enters a later request | any host |
| `soak` | Short distinct conversations plus periodic long ones, each with a new salt, for `--duration` | any host |
| `task` | One long conversation over `fixtures/ledger`, scored by hidden tests | **devbox only** |
| `compare` | One plain-text table. No winner logic. Refuses different workloads | anywhere |

The memguard log path differs per model, so it is a flag. Without it the report
says `no guard log`, never `no kills`.

## What makes it fair

- Bodies are a function of seed, corpus revision and repo files, apart from `model`.
- Temperature, top_p, top_k and `max_tokens` are set on every body. `seed` is probed
  once per run and the answer is recorded. `compare` refuses any difference.
- The corpus is read from git objects at `--corpus-rev`, tracked text files only.
- There is no per-model branch. No thinking parameter is sent. Assistant messages
  go back as received, under the field that arrived.
- Sizes are bytes, because tokenizers differ. One "token's worth" is 3 bytes, measured
  on this corpus at 2.9 on DeepSeek. Read `usage.prompt_tokens` for the real count.

## Reading the numbers

- **`not_cold`** on a first step means the salt did not defeat the cache.
- **`budget`**: a length stop with empty content. **`tool_call`**: a recall probe
  answered with a tool call. Neither is a wrong answer, and neither is in the fraction.
- **`missing`** is never 0. A reply delivered in one burst has no decode rate, and its
  decode time sits inside `ttft_s`. Tool-call replies did this on the DeepSeek server.
- **A short `--max-turns` scores the budget, not the model.**
- **`window`** comes from any window-like key in the snapshots. The DeepSeek server
  exposes none, so it reads missing there.

## The `task` sandbox

Model code runs only in a container, and only on devbox.

- Scratch is mounted read-only and copied to a tmpfs, so nothing written inside
  reaches a path the host tools read. `write_file` happens on the host.
- Host tools use realpath containment, `O_NOFOLLOW`, regular files only and size limits.
- No network, read-only root, all capabilities dropped, pid, memory and CPU limits.
- Time is enforced by `timeout` inside and `docker kill` by name outside.
- `docker create` then `docker start -a`, not `docker run`: with `run`, a client killed
  during startup left the daemon to start the container after it was confirmed gone.
- The host reads at most 64 KiB, then kills the container.
- Hidden tests run in a fresh container on an allowlisted copy. Their output goes to
  scoring only. A pass needs the exact test count and a bare `OK`.
- Containment probes run at every start, and `task` refuses if any fails.

**Known limit:** the pass check reads the output stream, and model code runs in that
same stream. Code written to forge `Ran N tests` and `OK` would pass. The check stops
accidents such as `sys.exit` at import, not deliberate cheating. Read the scratch copy
in the run directory if a score looks wrong.

Pull the image once, because `task` never pulls:

```bash
docker pull python@sha256:94d3426f1def7db4a106a232ac121bfd975393e5dfd40a619b955fae45fe7913
```

## What has and has not been run

| | Status |
|---|---|
| Offline checks, `make agentic-replay` | run in `make check` |
| Sandbox and containment on live docker | run on devbox; elsewhere prints NOT PROVEN |
| Sampler kill test on a loopback sshd | run; prints NOT PROVEN without sshd |
| `replay` to 20k tokens' worth, DeepSeek | run once, 9 requests, before later fixes |
| `task`, task 1 only, 5 turns, DeepSeek | run once, 6 requests |
| Long `replay`, concurrency above 1, `--interleave`, `--response-format` | **never run on a server** |
| `soak` | **never run on a server** |
| A full `task` run, any GLM run, a real head-to-head | **never run** |
| Request sampling values win over server defaults | **not proven**, only `max_tokens` |

## When it goes wrong

| Symptom | Cause | Next step |
|---|---|---|
| `task refused: task runs on devbox only` | Wrong host | Run it on devbox |
| `task refused: image not pulled` | Image absent | The pull command above |
| `task refused: containment not proven` | A probe failed | Fix it. There is no bypass |
| `refused: different workloads` | Seeds, corpus or sampling differ | Rerun with the same flags |
| Exit 1, `stopped: server died` | The server went away | Partial results are kept. Check the guard log |
| Error text in a stream with status 200 | Server-side refusal | Recorded as `error`. `top_k=0` came back this way on TensorFold |
