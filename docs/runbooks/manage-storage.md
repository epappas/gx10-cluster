# Runbook: manage storage

**What** — find where the 916 GB went, decide what is safe to remove, remove it.
**When** — before `make models`; when a job dies on `ENOSPC`; when `make verify`
reports the disk under the floor; on any box that has ever OOM'd.
**Risk** — low for the reclaim plan, which touches nothing regenerable. High for
the rows it deliberately excludes; read [what is never automatic](#never-automatic).

To *download* weights or budget for them, see [manage-models](manage-models.md).

## Why this is not just `df`

`gx10-status` prints free space and the size of the HF cache. Measured on
odysseus at 660 GB used, that is 175 GB of the answer:

| | |
|---|---|
| `~/.cache/huggingface` | 175 GB — the only line `gx10-status` showed |
| `/var/tmp` | 303 GB — training checkpoints, outside the HF cache |
| `/var/lib/apport` | 63 GB — core dumps |
| `/var/lib/docker` | 44 GB |

485 GB of that is in directories nobody thinks to `du`, and `hf cache scan`
structurally cannot see any of it. So the question is never "how full is it" —
it is **what is that, and can I delete it**, which is what `gx10-storage`
answers.

## Look

```bash
gx10-storage              # pressure, attribution, what is reclaimable
gx10-storage -c           # every node side by side
gx10-storage --top 20     # biggest directories, wherever they are
```

Shape of the report:

```
Disk
  209 GB of 915 GB free (76% used) on /
  109 GB above the 100 GB floor (model_min_free_gb)

Where it went
  weights     303 GB  outside the HF cache             /var/tmp/rl-checkpoints
  weights     174 GB  HF cache (weights)               /home/you/.cache/huggingface/hub
  crash        62 GB  apport core dumps                /var/lib/apport/coredump
  cache        43 GB  docker images + build cache      /var/lib/docker
  fixed        16 GB  swap file                        /swap.img

  accounted for: 604 GB of 706 GB used (102 GB elsewhere - try --top)

Reclaimable
  89 GB without touching a weight or a running job   (gx10-storage --reclaim)
  477 GB more is model data - by hand only, see the rows above
```

The **class** in the first column is the whole point — what you may safely
delete depends on what a thing is, not on how big it is:

| class | what it is | in the reclaim plan? |
|---|---|---|
| `weights` | model data, in the HF cache or anywhere else | **never** |
| `job` | output a run left behind | **never** |
| `image` | a docker image **built here**, existing in no registry | **never** |
| `crash` | core dumps | yes |
| `cache` | build, JIT and package caches; dangling docker layers | yes |
| `system` | journal, apt archives, superseded snap revisions | yes |
| `fixed` | swap | never — it is reported so the arithmetic adds up |

The **accounted for** line is deliberate. It states how much of `used` the rows
above explain, and names the gap, because a report that silently explains 60% of
the disk is how you end up looking in the wrong place. `--top` finds the rest.

The **floor** is the same comparison `roles/models` makes before it downloads
anything (`model_min_free_gb`, default 100 GB). A red line here is `make models`
telling you in advance why it is about to refuse — see
[the disk guard](manage-models.md#the-disk-guard-projects-it-does-not-check-a-floor).

Exit status is meant to be gated on: **0** above the floor, **1** below it.

## Reclaim

```bash
gx10-storage --reclaim            # exactly what would run, and for how much
gx10-storage --reclaim --apply    # run it
```

`--reclaim` on its own **deletes nothing**. It prints the plan, biggest first,
with the literal command for each row, so you can run one by hand instead of all
of them:

```
Reclaim plan
  class          size  command
  crash         62 GB  sudo rm -f /var/lib/apport/coredump/core.*
  cache         20 GB  docker system prune -af --volumes
  cache        5.7 GB  uv cache clean
  system       537 MB  sudo snap set system refresh.retain=2
  system       254 MB  sudo journalctl --vacuum-size=200M

  total: 89 GB
```

<a name="never-automatic"></a>

### What is never automatic

`--apply` touches only categories whose contents are regenerable by definition:
core dumps, build caches, package archives, dangling docker layers, rotated
journal. Deleting one of those costs a recompile or a re-pull, not data.

Model weights and job output are **reported with the command that would remove
them and never removed for you**, listed under `NOT in the plan - model data,
your call`. `hf cache delete` is interactive for the same reason. A tool that
frees 300 GB by deleting a checkpoint you had not finished with is not a tool,
it is an incident.

### <a name="local-images"></a>An image built here is not a cache

`docker system prune -af --volumes` was in the auto-apply tier until this
cluster was checked. Three of six images — `ar-deberta:ctl`,
`ar-deberta:spark`, `split-inference:spark`, 65 GB — had been built locally and
pushed nowhere. A prune would have destroyed them, and `docker pull` cannot
bring them back; only rebuilding from a Dockerfile can, if it still exists.

The test is exact, not a guess at the name: an image that was ever pulled from
or pushed to a registry has a `RepoDigests` entry, and one that was only ever
`docker build`-ed here has none. A registry-shaped tag proves nothing —
`ar-deberta:spark` looks exactly like a public image.

```bash
docker images -q | while read -r i; do
  printf '%-40s %s\n' "$(docker inspect "$i" --format '{{index .RepoTags 0}}')" \
    "$(docker inspect "$i" --format '{{if .RepoDigests}}re-pullable{{else}}LOCAL-ONLY{{end}}')"
done
```

When any unused image is local-only, `gx10-storage` classes the whole docker row
`image` and drops it out of the plan, offering only `docker builder prune -f`
(build cache, always regenerable) instead. When every unused image is
re-pullable it stays a `cache` row, because then a prune costs a download.

For weights specifically, prefer the tidy path — deleting a model directory by
hand works but leaves dangling refs:

```bash
hf cache scan          # per-model, with revisions
hf cache delete        # interactive
```

## <a name="core-dumps"></a>Core dumps are a RAM image, and RAM here is 121 GB

This is the storage failure unique to this hardware. Unified memory means a
crashed 40 GB-resident python writes **40 GB** to the same NVMe that holds the
weights *and* the swap file. Measured on odysseus:

```
-r-------- 1 root root 41100165120 Aug 29 10:46 core._usr_bin_python3_12.0.….4019736.…
-r-------- 1 root root  6402740224 Aug 27 21:20 core._usr_bin_python3_12.0.….259571.…
… 62 GB in five files
```

Three things about that are counter-intuitive:

- **`ulimit -c` says `0` and is irrelevant.** That is your login shell's soft
  limit. What crashes on this box is a systemd unit or a docker container, and
  systemd's `DefaultLimitCORE` is `infinity`.
- **It is not a leak.** `/usr/lib/tmpfiles.d/apport.conf` ages
  `/var/lib/apport/coredump` out after `3d`, and
  `systemd-tmpfiles-clean.timer` runs daily. The disk recovers on its own —
  three days after you needed the space.
- **The cause is usually upstream.** Repeated large cores mean something is
  repeatedly dying, and on this box that is normally the OOM killer. See
  [decisions](../decisions.md#persistence-latch) for what an OOM kill also
  leaves behind on the GPU.

To stop generating them at all, rather than clearing them after the fact:

```bash
sudo systemctl disable --now apport.service      # or: enabled=0 in /etc/default/apport
```

That is a real tradeoff, not a cleanup: you lose the post-mortem for the next
crash. Clear them, keep apport, and fix the OOM.

## <a name="var-tmp"></a>`/var/tmp` never ages out

Ubuntu ships the 30-day rule for it **commented out**:

```
$ grep var/tmp /usr/lib/tmpfiles.d/tmp.conf
#q /var/tmp 1777 root root 30d
```

So anything a job leaves in `/var/tmp` is permanent. It is also the natural
place for a training run to write checkpoints — 303 GB of them is what was
actually there, in eleven 28 GB directories.

`gx10-storage` finds these by **content, not by name**: a directory holding
`*.safetensors`, `*.gguf`, `*.pt` or `pytorch_model*.bin` is model data wherever
it sits, and gets classed `weights` so the reclaim plan will not touch it.

If you want them to expire, that is a policy decision and this repo does not
make it for you. Enable it deliberately:

```bash
printf 'q /var/tmp 1777 root root 30d\n' | sudo tee /etc/tmpfiles.d/var-tmp.conf
sudo systemd-tmpfiles --clean          # dry run first: --clean is not reversible
```

Do not do this on a box where a long run is writing checkpoints there.

## Watch it from the other side

```bash
make verify            # asserts the floor, and flags >10 GB of core dumps
gx10-storage -c        # both nodes, one screen
```

Both checks are `required: false` — a box deliberately packed with weights is
full, not broken, and failing the whole health check for that would train people
to ignore `make verify`.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `gx10-storage` says `no passwordless sudo: root-owned trees are UNMEASURED` | Run before `sudo_passwordless` was applied, or as a user without it | Re-run with sudo. The rows are *missing*, not zero — the tool refuses to report an unreadable 63 GB directory as empty |
| `accounted for` is far below `used` | Something large is in a directory no category names | `gx10-storage --top 20` |
| A checkpoint dir is not listed | It holds no recognised weight file, or is deeper than 4 levels under `/var/tmp` | `--top` finds it by size regardless |
| The docker row plans less than `docker system df` shows | Correct: running containers are using those layers, and prune cannot return them | Stop the container first |
| The docker row is not in the plan at all | An unused image was built here and exists in no registry | [an image built here is not a cache](#local-images) |
| The docker row prints one GB below `docker system df` | Correct: docker reports SI GB, this report is binary | — |
| `--apply` prints `failed - run it by hand` | Usually a prune blocked by a running container, or a missing `sudo` | Run that one command directly to see why |
| `make models` refuses although `gx10-storage` looked fine | The guard *projects* — it subtracts the weights you are about to download | [manage-models](manage-models.md#the-disk-guard-projects-it-does-not-check-a-floor) |
| Disk fills again within days | Something is crash-looping into `/var/lib/apport` | Fix the OOM, not the disk. [capacity-planning](capacity-planning.md) |
| Free space does not return after deleting a huge file | A process still holds the descriptor | `sudo lsof -nP +L1 \| head` and restart the holder |

## A note on the disk

The 916 GB NVMe also holds the 16 GB swap file. Filling it does not merely stop
downloads — it removes the emergency valve on a box where swapping is already a
[performance cliff](../hardware.md#unified-memory), not a slope. The 100 GB
floor is deliberately generous for that reason.

Every figure on this page was measured on odysseus and poseidon on 2026-08-30.
