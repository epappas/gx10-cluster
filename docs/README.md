# Documentation

Four kinds of document, deliberately separated so each has one job.

| | What it is | Read it when |
|---|---|---|
| [runbooks/](runbooks/) | Task-oriented procedures | You are doing something, or something broke |
| [hardware.md](hardware.md) | Verified GX10 facts, and what DGX OS already owns | You are about to tune something |
| [decisions.md](decisions.md) | Why the repo is the way it is, one entry per choice | You are about to change something and it looks odd |
| [contributing.md](contributing.md) | How to grow this without it rotting | You are adding to the repo |

The split matters: `hardware.md` is facts, `decisions.md` is judgement calls,
runbooks are actions. Mixing them is how a design essay grows where a checklist
was needed.

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

The playbook has been reviewed and statically checked, but **applied
end-to-end on zero machines**. The DGX-OS facts in `hardware.md` are verified
live; the playbook's own behaviour is not.
