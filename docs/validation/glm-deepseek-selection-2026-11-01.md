# GLM / DeepSeek selection on a two-node GB10 pair

2026-11-01. **Decision: prefer GLM for operational stability and concurrent long
runs on this measured pair, not as a universally better coding model.** DeepSeek
had better fixture quality and faster coding. The operator confirmed
non-commercial use; the DFlash2 drafter remains **CC BY-NC-ND 4.0**.

This is a bounded publication of saved measurements, not a new benchmark or a
fresh live-service check. Source code baseline: `e24d2f9` (functional changes
already merged in PRs 20 and 21). The [machine-readable receipt](glm-deepseek-selection-2026-11-01.json)
contains exact numeric results, workload manifests, model revisions and SHA256s
of the private inputs. Source labels identify originals for a local audit;
they are not links to published raw files. Deployment addresses, identities,
transcripts, generated projects and reasoning are deliberately excluded.

## Models and matched work

| | GLM | DeepSeek |
|---|---|---|
| Served variant | GLM-5.3-Flash-EXL3 | DeepSeek-V4.1-Flash-1017 |
| Weights | `Mia-AiLab/GLM-5.3-Flash-EXL3-4bpw-TensorFold` | `Mia-AiLab/DeepSeek-V4.1-Flash-1017-EXL3-EAQ-v1-2.9-bpw` |
| Quantization | EXL3 4 bpw, dense q4, fp8 KV | EXL3 EAQ-v1 2.9 bpw |
| Weight revision | `078455ffe6472f9a52fbc1139f58b9db2881b25c` | `45ee5d0fd106c94a3d77f721e09cbb2f50e5a16b` |
| Engine | TensorFold v0.6.0, digest-pinned image | TensorFold, locally built |

GLM uses kit revision `3fd60dfc836fab0f1ed0fd4f0afaf2a1d62b2aab`, image digest
`sha256:14b5072e8e9918f1080153f57321415a387bc7d78cf9c9b44a7aeae2d4399ccf`,
and `incoai/GLM-5.3-Flash-DFlash2` revision
`bf582e4eacc1810f76656d1811693ff6c6737d2a`. Saved health confirms context
1,048,576 and shared pool 1,738,752 token rows; the tested profile has four
streams. Configured context is **not** proof of 1M-token quality.
DeepSeek's saved deployment configuration records build kit reference
`abe07c7d509a0199cc7fec15263be2aa52ac652f`; the receipt records its engine,
build-input and Engram revisions. These are saved build references, not a
reconstructed image attestation.

The **complete workload objects match exactly** between the models for both
replay profiles and coding: corpus revision
`75a3e7bca4a6807155734e147edf2a2acc09b6f0`, corpus SHA256
`3d8a7da038e7ff29a34750747b05d2fd5b77594ea0ebfa296a236723dfd5ee20`,
and coding fixture SHA256
`edb4165c442c1afe4a926ec42903031637939868f023446b009db982024b7dbd`.
The receipt also preserves code/system/tools hashes, seeds, budgets and sampling.
Replay used seeds 1009 / 2003, 12 steps to 975,000 bytes, and probes at
162,500 / 325,000 / 650,000 / 975,000 bytes. Coding used seeds 3001 / 4001 /
5003, nine tasks each, at most 30 turns/task, 32,768 output tokens, temperature
0.7, top_p 1 and top_k 40. No timeout extension, rescoring or rerun is part of
this publication.

## Results and limitations

| Measured profile | DeepSeek | GLM |
|---|---|---|
| Single replay, official strict recall | 23/23 | **20/23** |
| Four-stream replay | Incomplete: 58 records, four one-hour timeouts; 34/35 observed recall probes passed | **All 12 steps in all four streams**, 141 records, zero errors; **80/92** strict recall |
| Coding, 27 tasks | **26/27**, zero invalid emissions, zero budget stops | **24/27**, eight invalid emissions, zero budget stops |
| Coding passes by seed | 8/9, 9/9, 9/9 | 8/9, 8/9, 8/9 |
| Coding requests, including one seed probe | 313, zero errors | 236, zero errors |
| First-repeat sum of task wall times | **34.6310364043 minutes** | 44.3911788329 minutes |
| Maximum observed coding prompt | 292,591 tokens | 292,588 tokens |

GLM passed every single-fact and combination recall probe. Its failed absent
probes recognized absence but included other codes, violating the scorer's
format. **Keep the official 20/23 and 80/92 scores; do not silently credit them.**
The eight coding invalids were XML-like calls to an unavailable `edit` tool in
plain assistant content, with empty structured `tool_calls`. They are real
protocol/unknown-tool emissions, not HTTP errors. Excessive reasoning has not
been established as their cause. GLM failed task 9 in all three seeds; DeepSeek
failed it in the first seed. Final regression statuses agree with those scores.

DeepSeek's four-stream runner stopped with `server died` after four unchanged
one-hour request timeouts. Its saved operator account says the worker was later
found exited; the cause is unknown. This is an observed operational failure,
not a diagnosis or a universal comparison of the model families. DeepSeek
refused the response-format probe; GLM served JSON successfully. A single
successful probe is not universal structured-output assurance.

### Latency and sampled memory

Times below are seconds, shown to three decimals; exact values are in the
receipt. Seed probes, response-format checks, separate sampling checks and
failed/dead requests are excluded. Replay mixes steps and probes, not matched
prompt-size timing. Median uses the middle pair; p95 uses nearest rank.

| Profile | Total latency median / p95 | Time to first token median / p95 | Lowest available memory, head / worker (KiB) |
|---|---|---|---|
| DeepSeek single replay | 5.154 / 17.282 | 3.144 / 15.596 | 2,967,788 / 5,408,112 |
| GLM single replay | 4.379 / 16.652 | 2.312 / 16.180 | 7,700,348 / 9,313,152 |
| DeepSeek four-stream replay, successful subset only | 19.741 / 93.572 | 13.699 / 90.462 | 2,749,852 / 4,837,168 |
| GLM four-stream replay | 13.870 / 94.258 | 5.741 / 89.232 | 5,989,176 / 8,815,920 |
| DeepSeek coding | 11.091 / 53.941 | 3.813 / 29.389 | 2,640,672 / 5,713,972 |
| GLM coding | 15.668 / 167.128 | 3.242 / 14.863 | 5,631,520 / 9,261,196 |
| GLM soak | 10.414 / 39.424 | 6.640 / 36.175 | 6,376,964 / 9,298,712 |

Memory is sampled, not a between-sample minimum. GLM summaries contain zero
sampler errors; DeepSeek's four-stream worker sampler recorded one error,
while its other node/phase summaries recorded zero. All phases recorded zero
sampled kill records. The missing DeepSeek four-stream worker guard
sub-summary is represented as unknown, not as proven guard coverage. Streaming
decode rates in the receipt may reflect burst delivery, not engine throughput.

### Completed GLM soak: low steady cache occupancy, not full-cache proof

Four streams ran the unchanged nominal three-hour workload: **3,204 workload
requests** (3,124 short, 80 long) **plus one seed probe**, zero recorded errors,
zero dead replies and four length stops. Four separate sampling-check requests
are not in that count. Recorded request span was **10,816.115958690643 seconds**,
including the seed probe and final in-flight completions. The workload used
seed 6007, short prompts of 6,500 bytes and long prompts of 195,000 bytes every
40 requests; maximum observed prompt was 61,034 tokens.

Shared-pool occupancy is `100 * (1 - pool_free_tokens / pool_tokens)`, not the
per-stream context-usage metric. There were 358 health samples within the
recorded span, 348 after five minutes. Sampled maximum including inherited
start state was 98.7043580683%; **after five minutes the sampled range was
8.4805653710% to 16.9611307420%**. No maximum between samples is asserted.
This is **not sustained full-cache stability proof**. The unchanged runner
verdict is `no death in window; cache fill not shown by this tool`. No matching
DeepSeek soak was run.

After the soak, saved proofs show an actual `OK` response in **1.589 s**, a real
`add` call with 19 and 23 in **0.951 s**, computed result 42, and final `42` in
**0.348 s**. Both rank guards were alive and bound to their current rank;
zero kill records were observed. This establishes responsiveness at that
check, not automatic recovery or indefinite uptime.

## Selection boundary

Use GLM as the operational choice for concurrent long runs on this pair under
the validated non-commercial profile. Keep DeepSeek's better fixture score and
coding speed visible. Do not generalize this to universally better coding,
indefinite uptime, 1M-token quality, full-cache stability, public security
hardening or automatic recovery. No inference setting, model service or guard
behavior was changed to publish this report.
