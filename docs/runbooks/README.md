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
| Run or serve a model | [serve-models](serve-models.md) |
| Download or clean up model weights | [manage-models](manage-models.md) |
| Run a job across both nodes | [run-distributed](run-distributed.md) |
| Measure the cluster and prove it performs | [benchmark](benchmark.md) |
| See what the machine is doing | [monitoring](monitoring.md) |
| Update packages without breaking CUDA | [upgrade-drivers](upgrade-drivers.md) |
| Get back in after an SSH lockout | [recover-ssh-lockout](recover-ssh-lockout.md) |
| Diagnose anything else | [troubleshoot](troubleshoot.md) |

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
| `No space left on device` pulling weights | [manage-models](manage-models.md#failure-modes) |
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
