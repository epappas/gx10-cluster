# Runbooks

Each answers **what / when / why / how**, with runnable commands and a failure
table. If you worked something out at 2am, it belongs here.

## By task

| I want to… | Runbook |
|---|---|
| Set up a brand-new GX10 | [provision-node](provision-node.md) |
| Cable two boxes and verify the interconnect | [connect-cluster](connect-cluster.md) |
| Work out what the fabric is and whether it works | [diagnose-interconnect](diagnose-interconnect.md) |
| Tune host network settings for the interconnect | [tune-network](tune-network.md) |
| Work out whether a model will fit at all | [capacity-planning](capacity-planning.md) |
| Run or serve a model | [serve-models](serve-models.md) |
| Spin up inference, Ray or RL environments | [workspaces](workspaces.md) |
| **Serve one model across BOTH nodes** | [two-node-serving](two-node-serving.md) |
| Download or clean up model weights | [manage-models](manage-models.md) |
| Work out where the disk went, and get it back | [manage-storage](manage-storage.md) |
| Run a job across both nodes | [run-distributed](run-distributed.md) |
| Measure the cluster and prove it performs | [benchmark](benchmark.md) |
| See what the machine is doing | [monitoring](monitoring.md) |
| Watch both nodes live in one screen | [monitoring](monitoring.md#cluster-wide) |
| Find which container or process is using the GPU | [monitoring](monitoring.md#who-is-on-the-gpu) |
| Add a third node, or replace one | [add-a-node](add-a-node.md) |
| Put a token somewhere safe, or rotate one | [manage-secrets](manage-secrets.md) |
| Update packages without breaking CUDA | [upgrade-drivers](upgrade-drivers.md) |
| Bring the cluster back after a reboot or power loss | [reboot-recover](reboot-recover.md) |
| Get back in after an SSH lockout | [recover-ssh-lockout](recover-ssh-lockout.md) |
| Diagnose anything else | [troubleshoot](troubleshoot.md) |
| Know what a `gx10-*` command is before running it | [tools](../tools.md) — the reference, indexed by command |

## By symptom

Start with `make verify` — every failure it reports names the runbook that
fixes it. Otherwise:

| Symptom | Go to |
|---|---|
| `no kernel image is available for execution` | [troubleshoot](troubleshoot.md#pytorch--cuda) |
| The venv drifted from its lockfile | [troubleshoot](troubleshoot.md#the-venv-does-not-match-its-lockfile) |
| `only requests==2.28.1 is available` from uv | [troubleshoot](troubleshoot.md#uv-pip-install-fails-with-only-requests2281-is-available) |
| `Failed to initialize NVML` / no `/dev/nvidia*` | [upgrade-drivers](upgrade-drivers.md#if-you-already-broke-it) |
| The two nodes disagree on driver, kernel or torch | [upgrade-drivers](upgrade-drivers.md#after-any-driver-or-kernel-change) |
| `Permission denied (publickey)`, or SSH closes instantly | [recover-ssh-lockout](recover-ssh-lockout.md) |
| Reachable on the LAN, not from anywhere else | [recover-ssh-lockout](recover-ssh-lockout.md#f-get-in-over-meshnet) |
| `permission denied` on the docker socket | [troubleshoot](troubleshoot.md#docker) |
| `permission denied` on the nordvpn socket | [troubleshoot](troubleshoot.md#remote-access) |
| `ibv_devices` empty | [connect-cluster](connect-cluster.md) — expected before cabling |
| `ibhosts`/`iblinkinfo` show nothing, link looks absent | [troubleshoot](troubleshoot.md#no-infiniband-visible) — RoCE, not IB |
| Unsure what the fabric physically is, or a tool disagrees | [diagnose-interconnect](diagnose-interconnect.md) |
| Interconnect works but you want more out of it | [tune-network](tune-network.md) |
| Interconnect at ~13 Gbps instead of 200 | [connect-cluster](connect-cluster.md#the-13-gbps-trap) |
| Interconnect at half speed | [connect-cluster](connect-cluster.md#reading-the-result) |
| Model OOMs or the box crawls | [serve-models](serve-models.md#when-it-fails) |
| Unsure whether a model fits before downloading it | [capacity-planning](capacity-planning.md) |
| Throughput collapses as concurrency rises | [capacity-planning](capacity-planning.md) — you are measuring preemption |
| A two-node server hangs at init, or is quietly on TCP | [two-node-serving](two-node-serving.md#the-three-things-that-fail-quietly) |
| `ibv_modify_qp` errno 61 on the *remote* rank, ~60 s in | [two-node-serving](two-node-serving.md#gid-index) — a pinned GID index |
| Correct output at half the expected speed | [two-node-serving](two-node-serving.md#failure-modes) — the draft path, not the hardware |
| Memory is gone right after a reboot | [reboot-recover](reboot-recover.md) — a container restarted itself |
| `Attempting to decrypt but no vault secrets found` | [manage-secrets](manage-secrets.md) |
| A `local.yml` or vault override does nothing | [manage-secrets](manage-secrets.md) — the directory form |
| Collectives hang after adding a node | [add-a-node](add-a-node.md) — ufw on the *other* nodes |
| `No space left on device` pulling weights | [manage-models](manage-models.md#failure-modes) |
| Free space did not return after deleting a big file | [troubleshoot](troubleshoot.md#disk) — a process still holds the descriptor |
| The disk is full and `du ~/.cache` does not explain it | [manage-storage](manage-storage.md) — 485 GB of it was outside `$HOME` |
| Tens of GB appeared in `/var/lib/apport` | [manage-storage](manage-storage.md#core-dumps) — a core dump here is a RAM image |
| `/var/tmp` is enormous and nothing ever clears it | [manage-storage](manage-storage.md#var-tmp) — Ubuntu ships that rule commented out |
| `make verify` says the disk is under the model floor | [manage-storage](manage-storage.md) |
| The models role aborts before downloading anything | [manage-models](manage-models.md#the-disk-guard-projects-it-does-not-check-a-floor) |
| 401/403 downloading a model | [manage-models](manage-models.md#gated-models) |
| A distributed job hangs before step 1 | [run-distributed](run-distributed.md#hangs-before-the-first-step-in-detail) |
| Grafana panels blank, or GPU memory missing | [monitoring](monitoring.md) |
| A remote Prometheus cannot scrape this node | [monitoring](monitoring.md#if-you-want-metrics-over-time) |
| `roles/observability has no default entry point` | [troubleshoot](troubleshoot.md#ansible) |
| A task reports `changed` every run | [troubleshoot](troubleshoot.md#ansible) |
| `make optional TAGS=…` installs nothing but says ok | [troubleshoot](troubleshoot.md#optional-installs-nothing) |
| Benchmarks, or proving the fabric performs | [benchmark](benchmark.md) |

## Writing one

Open with what it is and when to use it, give the mechanism in two or three
sentences, then numbered steps with expected output and a failure table. State
the risk if there is one, and say plainly when a step is irreversible.

Anything touching sshd or networking must also appear in
[recover-ssh-lockout](recover-ssh-lockout.md) — if a change can lock you out,
the way back in is not optional documentation.

Label anything not verified first-hand. See [provenance](../README.md#provenance).
