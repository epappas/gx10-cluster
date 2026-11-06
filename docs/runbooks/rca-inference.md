# Runbook: inference stopped, a node froze, or a node restarted

**Purpose:** save evidence, identify which failure occurred, and recover without guessing.
**Applies to:** GLM on `gx10-odysseus` and `poseidon`, container `glm53-flash-tf`.
**Root cause analysis (RCA):** finding why an incident happened, not just restarting it.

## Rules before you start

- Stop sending inference requests. Do not reproduce the incident with another large prompt.
- Collect evidence **before** restarting Docker, inference, or a node.
- Do not disable the memory guards, lower their thresholds, change model settings,
  reset the GPU, or update drivers as a diagnostic shortcut.
- A container exit is not a host reboot. A healthy HTTP status is not proof that inference works.
- Evidence is private. Kernel and optional engine logs can contain host details or request text.
  Do not upload a bundle publicly without reviewing it.

This guide expects `gx10-rca --help` to list `--report`. For provisioning, use
the checkout containing this guide and `container_signal.py`; an older
monitoring checkout can reinstall the legacy collector. The recovery steps
below do not reapply monitoring or change model settings.

## 1. Check whether the host or only inference failed

**Run on your controller/laptop:**

```bash
ssh -o BatchMode=yes -o ConnectTimeout=5 gx10-odysseus \
  'hostname; date -u; uptime -s; cat /proc/sys/kernel/random/boot_id'
```

- A changed boot ID compared with an earlier capture proves a new host boot.
- The same boot ID with an exited/replaced container points to a workload event, not a reboot.
- SSH failure alone proves neither: it can also mean a network or SSH problem.
- `poseidon` is normally reached from the head. If the head is unreachable,
  failure of that route does **not** prove the worker failed. Use an already
  configured independent route or the physical console; never bypass SSH host-key checks.

If the head answers, check the worker:

```bash
ssh gx10-odysseus 'ssh -o BatchMode=yes -o ConnectTimeout=5 poseidon \
  "hostname; date -u; uptime -s; cat /proc/sys/kernel/random/boot_id"'
```

**Stop here if both hosts are inaccessible.** Record the time, power indicators,
network reachability and console output. Follow [SSH recovery](recover-ssh-lockout.md)
or [reboot recovery](reboot-recover.md); do not repeatedly power-cycle the machines.

## 2. Save both nodes' evidence and copy it off the head

**Run on your controller, from this repository's root directory.** This uses the
installed `gx10-rca` on the head; it reads the worker over existing SSH. `--sudo`
allows non-interactive journal reads only, not recovery actions.

```bash
umask 077
case_id="rca-$(date -u +%Y%m%dT%H%M%SZ)-$$"
case_dir="${GX10_INCIDENTS:-$HOME/gx10-incidents}/$case_id"
mkdir -p "$case_dir"
ssh gx10-odysseus "umask 077; mkdir -p .local/state/gx10-incidents; \
  gx10-rca --sudo --peer poseidon --output .local/state/gx10-incidents/$case_id"
scp -r "gx10-odysseus:.local/state/gx10-incidents/$case_id/." "$case_dir/"
python3 -I -B roles/monitoring/files/gx10-rca --report "$case_dir/evidence.json"
```

Expected: a new `evidence.json`, readable only by you, and a plain-text report
with separate host sections. Capture exit `0` means the bundle was written;
it does **not** mean the machine is healthy or every collector succeeded.

The bundle contains boot IDs, memory and pressure counters, guard-log tail,
selected container state, temperature/power, and **current and previous boot**
kernel/Docker journals. It does not collect environment variables, core dumps
or engine logs by default. Commands have deadlines and output limits.

Read each section's `exit`, `timeout`, `truncated` and `reaped` fields:

| Report observation | What it means / next action |
|---|---|
| `timeout=True` | That command did not answer. Do not call its target healthy. |
| `truncated=True` | Only a bounded part was saved. Preserve a targeted larger capture if needed. |
| `reaped=False` | A collector did not exit after bounded signals. Stop repeating captures; preserve its state. |
| Missing previous boot, no entries, or permission denial | Evidence is unavailable; it is not proof that no fault occurred. |
| Peer transport failure | Worker evidence is missing; do not infer that the worker rebooted. |

For a larger targeted capture, use a **new** output directory and
`--max-output-bytes 65536`. Existing directories are refused, not overwritten.
Only add `--include-engine-logs` if needed; the resulting bundle may contain request text.

## 3. Classify the evidence; do not invent a cause

| Evidence | Supported conclusion | Not established by that evidence alone |
|---|---|---|
| Guard says `killed container ... pidfd exit confirmed` | The guard observed its verified target exit after signalling it. | Why memory became low. |
| `kill unconfirmed` | Termination was not confirmed. | That the workload stopped safely. |
| `cached process exited ... cause unconfirmed` | The original process ended. | Who or what ended it. |
| `OOMKilled=true` or an explicit kernel out-of-memory record | An out-of-memory event was reported. | That the whole host rebooted. |
| New host boot ID | The host booted again. | Power loss versus an operator reboot versus a kernel failure. |
| NVIDIA `Xid`, reset failure or `fallen off the bus` | A GPU/driver event needs investigation. | A hardware defect or the cause of the reboot; teardown can also emit errors. |
| `systemd-shutdown` messages | A shutdown sequence ran. | Who requested it or whether an earlier fault prompted it. |
| Exit code 137 | Consistent with SIGKILL (forced termination), not proof by itself. | Who sent a signal, or whether the program explicitly returned that code. |
| Archived engine log exists | Someone or something archived a log. | An operator stop. |

Correlate timestamps from **both** nodes and the guard, kernel and Docker
records. Write `cause unknown` when those records do not establish causality.
The previous-boot journal may already be persistent; the collector reports
configuration observations, not a guarantee that the final messages reached disk.

## 4. Recover through the normal pair wrappers

**From the controller, log into the head:**

```bash
ssh gx10-odysseus
```

**On the head, only after saving the evidence:**

```bash
cd "$HOME/gx10-cluster"
"$HOME/.local/bin/ws" down tensorfold-2node-glm53-flash-exl3 &&
  "$HOME/.local/bin/ws" up tensorfold-2node-glm53-flash-exl3
```

The `&&` prevents startup if the stop command fails.

`ws down` reaches both ranks and archives logs. `ws up` verifies the source/image
and arms both guards before model loading. Do not run the upstream `start.sh`
directly, use `DRY_RUN` with `ws down`, or bypass preparation checks.

**Make one restart attempt.** If it fails, capture the result and stop. Do not
enter a reload loop or change context/cache/parallelism to make the error disappear.
If Docker does not answer, use section 5 instead of repeatedly issuing Docker commands.
If current kernel logs show a continuing driver reset failure, preserve evidence
and stop before loading the model again.

After startup, verify the JSON body and then a real request:

```bash
curl -fsS --max-time 10 http://127.0.0.1:8902/health |
  python3 -I -B -c 'import json,sys; v=json.load(sys.stdin); assert v["ok"] is True; assert v["context_length"]==1048576; assert v["pool_tokens"]==1738752; print("health/profile PASS")' &&
curl -fsS --max-time 60 http://127.0.0.1:8902/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"GLM-5.3-Flash-EXL3","messages":[{"role":"user","content":"Reply with exactly OK."}],"max_tokens":16,"temperature":0,"chat_template_kwargs":{"enable_thinking":false}}' |
  python3 -I -B -c 'import json,sys; c=json.load(sys.stdin)["choices"][0]; assert c["finish_reason"]=="stop"; assert c["message"]["content"].strip()=="OK"; print("real inference PASS")'
```

Do not declare recovery from `/models`, HTTP 200 alone, or a running container.
The memory guard must also be alive and bound to the current container.

## 5. Emergency path when Docker is unresponsive

This path signals **one rank**, not the whole pair, and loses in-flight requests.
It does not restart anything. Use it only after evidence capture when normal
`ws down` cannot complete. The helper validates the full container ID, host PID,
process start time and boot ID, then waits for kernel confirmation of exit.
It refuses stale/reused identities and never searches for a process by name.

**On the affected node, as your normal user**, run this complete block. It
finds exactly one live guard, reads that guard's saved binding, checks the target,
and prints the exact emergency stop command. It does not send a kill signal.

```bash
python3 -I -B - <<'PY'
import json, pathlib, shlex, subprocess
pids = subprocess.check_output(
    ["pgrep", "-f", "[m]emory_guard.py --container glm53-flash-tf"], text=True).split()
if len(pids) != 1:
    raise SystemExit("STOP: expected exactly one live GLM guard; do not guess a PID")
pid = int(pids[0])
argv = pathlib.Path(f"/proc/{pid}/cmdline").read_bytes().decode().split("\0")
status = pathlib.Path(argv[argv.index("--status-file") + 1])
value = json.loads(status.with_name("process.json").read_text())
if value["guard_pid"] != pid or status.read_text().strip() != "guarding " + value["container_id"]:
    raise SystemExit("STOP: saved binding does not match the live guard")
command = ["/usr/bin/sudo", "-n", "/usr/bin/python3", "-I", "-B",
           "/usr/local/libexec/gx10-container-signal", "check"]
for key in ("container_id", "pid", "start_ticks", "boot_id"):
    command += ["--" + key.replace("_", "-"), str(value[key])]
subprocess.run(command, check=True)
command[6] = "kill"
print("ONLY if an emergency stop is intended, run this exact command:")
print(shlex.join(command))
PY
```

- A successful check prints `state: alive`. Review the printed full container ID.
- Run the printed `kill` command only when that rank must be stopped.
- `state: killed`, exit `0`: target exit was confirmed.
- `state: exited`, exit `3`: it had already ended; this is not proof of a guard kill.
- `refused`, `permission-denied` or `unconfirmed`: **STOP**. Do not replace the command
  with `kill -9` on a guessed PID or weaken identity checks.
- A process blocked inside the kernel/driver may not exit after SIGKILL. This helper
  cannot guarantee recovery from that condition. Do not run an automatic reboot loop.

Inspect the other rank too. Once Docker is responsive, use the pair's normal
`ws down` and one `ws up` from section 4; do not leave a single rank serving alone.

## 6. Preserve evidence before the next incident

Store captures on a controller that remains running, not only on a GPU node.
For kernel messages immediately before a freeze, open a separate controller
terminal and run this bounded stream. It stops after 24 hours or 50 MiB:

```bash
umask 077
mkdir -p "$HOME/gx10-incidents"
set -o pipefail
timeout 24h ssh -o BatchMode=yes -o StrictHostKeyChecking=yes \
  -o ServerAliveInterval=5 -o ServerAliveCountMax=2 gx10-odysseus \
  'sudo -n journalctl --kernel --follow --lines=0 --output=short-iso' |
  head -c 52428800 > "$HOME/gx10-incidents/head-kernel-$(date -u +%Y%m%dT%H%M%SZ).log"
```

The stream has no automatic reconnect or host restart. A disconnect can be a
network problem; preserve its time and exit status. A stream through the head
cannot independently prove worker health if the head disappears. Sudden power
loss can still occur before the final message is transmitted.

## 7. Roll back the guard, not the model profile

The initial protection deployment retains the old guard files on the head at
`$HOME/.cache/gx10-node-protection-20261105/rollback/`. If a successor guard
cannot acknowledge its target, the launcher retains the old guard; do not kill
it to force a clean-looking status.

To restore that saved guard implementation, on the head:

```bash
cd "$HOME/gx10-cluster"
cp -p "$HOME/.cache/gx10-node-protection-20261105/rollback/memory_guard.py" \
  "$HOME/.cache/gx10-node-protection-20261105/rollback/memory_guard.sh" \
  workspaces/inference/tensorfold-2node-glm53-flash-exl3/ &&
bash -c 'cd workspaces/inference/tensorfold-2node-glm53-flash-exl3; \
  export CONTAINER_NAME=glm53-flash-tf WORKER="$USER@poseidon"; \
  source ./memory_guard.sh; memory_guard_startup && memory_guard_finish'
```

This replaces guard processes without reloading the model. It removes the new
Docker-independent protection, so record that limitation. Installed nonresident
helper/collector files can remain; no root daemon or sudo rule was added.

## Limits and references

These protections reduce memory-related risk; they cannot prevent every driver
lockup, thermal shutdown, power failure or hardware fault. A host directory named
`/var/log/journal` alone does not prove effective retention. Do not vacuum journals,
remove model/cache files, or change crash/reboot policies before preserving evidence.

See [monitoring](monitoring.md), [reboot recovery](reboot-recover.md),
[GPU failure classification](https://ai-infrastructure.net/reliability-ras/),
and [GB10 shared-memory constraints](https://ai-infrastructure.net/dgx-spark/).
