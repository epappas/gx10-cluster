# Runbooks

Each answers **what / when / why / how**, with runnable commands and a failure
table. If you worked something out at 2am, it belongs here.

## By task

| I want to… | Runbook |
|---|---|
| Set up a brand-new GX10 | [provision-node](provision-node.md) |
| Cable two boxes and verify the interconnect | [connect-cluster](connect-cluster.md) |
| Run or serve a model | [serve-models](serve-models.md) |
| Update packages without breaking CUDA | [upgrade-drivers](upgrade-drivers.md) |
| Get back in after an SSH lockout | [recover-ssh-lockout](recover-ssh-lockout.md) |
| Diagnose anything else | [troubleshoot](troubleshoot.md) |

## By symptom

Start with `make verify` — every failure it reports names the runbook that
fixes it. Otherwise:

| Symptom | Go to |
|---|---|
| `no kernel image is available for execution` | [troubleshoot](troubleshoot.md#pytorch--cuda) |
| `Failed to initialize NVML` / no `/dev/nvidia*` | [upgrade-drivers](upgrade-drivers.md#if-you-already-broke-it) |
| `Permission denied (publickey)`, or SSH closes instantly | [recover-ssh-lockout](recover-ssh-lockout.md) |
| `permission denied` on the docker socket | [troubleshoot](troubleshoot.md#docker) |
| `ibv_devices` empty | [connect-cluster](connect-cluster.md) — expected before cabling |
| Interconnect at ~13 Gbps instead of 200 | [connect-cluster](connect-cluster.md#the-13-gbps-trap) |
| Interconnect at half speed | [connect-cluster](connect-cluster.md#reading-the-result) |
| Model OOMs or the box crawls | [serve-models](serve-models.md#when-it-fails) |
| A task reports `changed` every run | [troubleshoot](troubleshoot.md#ansible) |

## Writing one

Open with what it is and when to use it, give the mechanism in two or three
sentences, then numbered steps with expected output and a failure table. State
the risk if there is one, and say plainly when a step is irreversible.

Anything touching sshd or networking must also appear in
[recover-ssh-lockout](recover-ssh-lockout.md) — if a change can lock you out,
the way back in is not optional documentation.

Label anything not verified first-hand. See [provenance](../README.md#provenance).
