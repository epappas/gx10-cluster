# Documentation

Five kinds of document, deliberately separated so each has one job.

| | What it is | Read it when |
|---|---|---|
| [runbooks/](runbooks/) | Task-oriented procedures | You are doing something, or something broke |
| [tools.md](tools.md) | Every command this repo adds, and how to read its output | You typed `gx10-<tab>`, or a runbook named a tool you do not know |
| [hardware.md](hardware.md) | Verified GX10 facts, and what DGX OS already owns | You are about to tune something |
| [decisions.md](decisions.md) | Why the repo is the way it is, one entry per choice | You are about to change something and it looks odd |
| [contributing.md](contributing.md) | How to grow this without it rotting | You are adding to the repo |

The split matters: `hardware.md` is facts, `decisions.md` is judgement calls,
runbooks are actions, `tools.md` is the interface. Mixing them is how a design
essay grows where a checklist was needed.

Runbooks are indexed by **task** and by **symptom**; `tools.md` is indexed by
**command**. If you know what you want to achieve, start with a runbook. If you
have a command in front of you and want to know what it is before you run it,
start with tools.

## Provenance

Most GX10 information online is community-written, some machine-generated and
some wrong. Every claim here is labelled:

| Label | Means |
|---|---|
| *(unlabelled)* | Verified on our hardware — the command is in the doc |
| **NVIDIA docs** | From `docs.nvidia.com` or NVIDIA's own playbooks |
| **Confidence: community-reported** | Forum or blog. A lead to test, not a fact |

A community claim must ship with a way to *measure* whether it applied to you,
so a non-fix can be recognised as one. When you verify or disprove something on
the hardware, upgrade or delete the label — stale "reportedly" text is how slop
propagates.

## Status

Provisioning is **applied end-to-end on both nodes** — `make verify` passes and
a full `make diff` reports zero changes. The GB10 facts in `hardware.md` and the
interconnect measurements in `decisions.md` are first-hand.

Three things are deliberately not proven: the **benchmark suite has never been
run** (statically checked only, and [labelled as such](runbooks/benchmark.md)),
the tier-2 items in [tune-network](runbooks/tune-network.md) are unmeasured
hypotheses rather than results, and **every workspace is `unverified`** —
written from vendor documentation and the sources cited in each manifest, not
from a completed run. `ws list` renders that in yellow.

The serving runbooks inherit that split. The **fabric** measurements they quote
are first-hand; the **serving** numbers are not. That is stated in
[two-node-serving](runbooks/two-node-serving.md#provenance) and
[capacity-planning](runbooks/capacity-planning.md) rather than left to be
inferred.

The top-level [README](../README.md#status) is the single source of truth for
this; if the two ever disagree, that one is right.
