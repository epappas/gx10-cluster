#!/usr/bin/env python3
"""Drive gx10-storage against a fixture tree and assert what it concludes.

Two halves of this tool can go quietly wrong, and both are invisible on the box
they were written on:

  * classification. A model checkpoint that stops being recognised as `weights`
    lands in the reclaim plan, and `--apply` then deletes 300 GB of somebody's
    training run. Nothing else catches that - on a healthy box the plan simply
    looks a little larger.
  * arithmetic. If the docker row starts contributing its DIRECTORY size rather
    than docker's own reclaimable figure, the tool promises space that pruning
    cannot return, and you free 20 GB while planning around 43.

So this runs the REAL script - not a reimplementation of its rules - against a
tree with known contents, with df/docker/journalctl/snap stubbed on PATH. It
therefore needs no GPU, no sudo and no disk pressure, and runs anywhere.

    python3 tests/check_storage.py
"""

from __future__ import annotations

import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent
TOOL = REPO / "roles" / "monitoring" / "files" / "gx10-storage"

KB = 1024
GB = 1024**3

problems: list[str] = []


def check(cond: bool, msg: str) -> None:
    if not cond:
        problems.append(msg)


def write(path: pathlib.Path, kb: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"\0" * (kb * KB))


def make_fixture(tmp: pathlib.Path) -> pathlib.Path:
    """A tree with one of every category, at sizes the tool must rank correctly."""
    root = tmp / "root"
    home = root / "home" / "u"

    # Weights outside the HF cache - the class `hf cache scan` cannot see.
    write(root / "var/tmp/jobs/ckpt-1/model-00001-of-00002.safetensors", 400)
    write(root / "var/tmp/jobs/ckpt-2/model-00002-of-00002.safetensors", 400)
    # Weights inside it.
    write(home / ".cache/huggingface/hub/models--org--m/blobs/x.safetensors", 300)
    # Regenerable.
    write(root / "var/lib/apport/coredump/core._usr_bin_python3_12.0.abc.1", 250)
    write(root / "var/cache/apt/archives/some.deb", 120)
    write(home / ".cache/uv/archive-v0/wheel", 60)
    # Never a candidate.
    write(root / "swap.img", 200)
    return root


def make_stubs(
    tmp: pathlib.Path, *, avail_gb: int, docker: bool = True, local_only: bool = False
) -> pathlib.Path:
    """df/docker/journalctl/snap replacements, so the fixture drives the report."""
    bindir = tmp / "bin"
    bindir.mkdir(parents=True, exist_ok=True)

    size, avail = 900 * GB, avail_gb * GB
    used = size - avail
    pcent = round(100 * used / size)
    # The real df prints a header line the tool discards with `tail -1`.
    (bindir / "df").write_text(
        "#!/bin/sh\n"
        'echo "size used avail pcent"\n'
        f'echo "{size} {used} {avail} {pcent}%"\n'
    )
    if docker:
        # Total 40 GB, of which only 12 GB is actually reclaimable. The tool
        # must plan around 12, not 40.
        #
        # `local_only` decides whether the unused images can be re-pulled. With
        # it set, `docker inspect --format {{if .RepoDigests}}` prints nothing,
        # which is exactly what a `docker build`-ed image does.
        digests = "" if local_only else "x"
        (bindir / "docker").write_text(
            "#!/bin/sh\n"
            'case "$*" in\n'
            '  *"Build Cache"*|*Type*) printf "Images\\t12GB\\nBuild Cache\\t0B\\n" ;;\n'
            f'  *RepoDigests*)  printf "{digests}\\n" ;;\n'
            '  *"ps -aq"*|"ps -aq") ;;\n'
            '  *images*)       echo sha256:deadbeef ;;\n'
            '  *inspect*)      ;;\n'
            '  *)              printf "40GB\\t12GB (30%%)\\n0B\\t0B\\n" ;;\n'
            'esac\n'
        )
    (bindir / "journalctl").write_text('#!/bin/sh\necho "Archived and active journals take up 4.0G in the file system."\n')
    (bindir / "snap").write_text("#!/bin/sh\nexit 0\n")
    # Enough of sudo to run the plan inside the fixture. Every path-bearing
    # reclaim command is written through GX10_STORAGE_ROOT, so what these
    # actually delete is the tree built above.
    (bindir / "sudo").write_text(
        '#!/bin/sh\n[ "$1" = "-n" ] && shift\nexec "$@"\n'
    )
    (bindir / "uv").write_text("#!/bin/sh\nexit 0\n")
    (bindir / "apt-get").write_text("#!/bin/sh\nexit 0\n")
    for f in bindir.iterdir():
        f.chmod(0o755)
    return bindir


def run(root: pathlib.Path, bindir: pathlib.Path, *args: str) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    env["PATH"] = f"{bindir}:{env['PATH']}"
    env["GX10_STORAGE_ROOT"] = str(root)
    env["GX10_STORAGE_HOME"] = "/home/u"
    env["HF_HOME"] = "/home/u/.cache/huggingface"
    # Fixture files are KB, not GB.
    env["GX10_STORAGE_MIN_BYTES"] = "1024"
    env["GX10_STORAGE_LOOSE_MIN_BYTES"] = "1024"
    return subprocess.run(
        [str(TOOL), *args], capture_output=True, text=True, env=env, timeout=120
    )


def row_for(out: str, needle: str) -> str:
    for line in out.splitlines():
        if needle in line:
            return line
    return ""


def main() -> int:
    if not TOOL.exists():
        print(f"check_storage: {TOOL} is missing", file=sys.stderr)
        return 1
    if shutil.which("du") is None:
        print("check_storage: no du - skipping")
        return 0

    with tempfile.TemporaryDirectory() as td:
        tmp = pathlib.Path(td)
        root = make_fixture(tmp)
        bindir = make_stubs(tmp, avail_gb=400)

        # --- --help ----------------------------------------------------------
        #
        # Cheap, and it caught a real one: the usage extractor was an awk
        # start/end RANGE whose end anchor matched no line, so --help printed
        # the entire 400-line script. A range that fails open looks like it
        # works right up until someone reads the output.
        r = run(root, bindir, "--help")
        lines = [ln for ln in r.stdout.splitlines() if ln.strip()]
        check(r.returncode == 0, f"--help should exit 0, got {r.returncode}")
        check(0 < len(lines) <= 12, f"--help printed {len(lines)} lines - it is dumping the script")
        check(all(ln.startswith("gx10-storage") for ln in lines),
              f"--help is printing something other than usage:\n{r.stdout[:400]}")

        # --- the report ------------------------------------------------------
        r = run(root, bindir)
        out = r.stdout
        check(r.returncode == 0, f"healthy fixture should exit 0, got {r.returncode}")

        loose = row_for(out, "var/tmp/jobs")
        check(bool(loose), "a checkpoint dir outside the HF cache was not reported at all")
        check(loose.strip().startswith("weights"),
              f"checkpoints outside the HF cache must class as weights, got: {loose.strip()}")
        check("/var/tmp/jobs/ckpt-1" not in out and "/var/tmp/jobs/ckpt-2" not in out,
              "shard directories must roll up to the job directory, not list individually")

        hf = row_for(out, "huggingface/hub")
        check(hf.strip().startswith("weights"), f"HF cache must class as weights, got: {hf.strip()}")

        core = row_for(out, "apport/coredump")
        check(core.strip().startswith("crash"), f"core dumps must class as crash, got: {core.strip()}")

        swap = row_for(out, "swap.img")
        check(swap.strip().startswith("fixed"), f"swap must class as fixed, got: {swap.strip()}")

        # --- the plan --------------------------------------------------------
        r = run(root, bindir, "--reclaim")
        plan, _, held = r.stdout.partition("NOT in the plan")
        check(bool(held), "--reclaim must show what it is deliberately NOT touching")

        for weight_path in ("/var/tmp/jobs", "huggingface/hub"):
            check(weight_path not in plan,
                  f"model data {weight_path} appeared IN the reclaim plan - --apply would delete it")
            check(weight_path in held, f"{weight_path} missing from the held-back list")

        check("apport/coredump" in plan, "core dumps must be in the reclaim plan")
        check("swap" not in plan, "swap must never be in the reclaim plan")

        # docker's own reclaimable figure, not the 40 GB total.
        # docker prints SI GB, this report is binary: 12 GB SI is 11 GiB. What
        # matters is that it is docker's reclaimable figure and not the 40 GB
        # image total, which pruning cannot return.
        check("11 GB" in plan and "40 GB" not in plan and "37 GB" not in plan,
              f"the docker row must plan around docker's reclaimable figure, not the image total:\n{plan}")

        # Biggest first - the plan is a list of decisions, and the 12 GB one
        # should not be below the 4 GB one.
        sizes = []
        for ln in plan.splitlines():
            f = ln.split()
            if ln.startswith("  ") and len(f) > 2 and f[0] != "total:" and f[2] in ("GB", "MB"):
                sizes.append(float(f[1]) * (1 if f[2] == "GB" else 1 / 1024))
        check(sizes == sorted(sizes, reverse=True), f"plan is not sorted biggest-first: {sizes}")

        # A dry run must not delete anything. The FILE, not the directory:
        # `rm -f .../core.*` empties the directory and leaves it standing, so
        # checking the directory passes on a dry run that deleted every core.
        check((root / "var/lib/apport/coredump/core._usr_bin_python3_12.0.abc.1").exists(),
              "--reclaim without --apply deleted files")

        # --- the floor -------------------------------------------------------
        tight = make_stubs(tmp / "tight", avail_gb=40)
        r = run(root, tight)
        check(r.returncode == 1, f"below the floor must exit 1, got {r.returncode}")
        check("BELOW the 100 GB floor" in r.stdout,
              "below the floor, the report must say `make models` will refuse")
        check("60 GB BELOW" in r.stdout, f"floor shortfall miscomputed: {row_for(r.stdout, 'floor')}")

        r = run(root, make_stubs(tmp / "ok", avail_gb=400))
        check("300 GB above" in r.stdout, f"headroom miscomputed: {row_for(r.stdout, 'floor')}")

        # --- honesty ---------------------------------------------------------
        nodocker = make_stubs(tmp / "nodk", avail_gb=400, docker=False)
        (nodocker / "docker").write_text("#!/bin/sh\nexit 1\n")
        (nodocker / "docker").chmod(0o755)
        r = run(root, nodocker)
        check(r.returncode == 0 and "Where it went" in r.stdout,
              "a failing docker must cost its row, not the whole report")

        # The unaccounted-for gap is the whole reason this tool exists; it must
        # be stated rather than rounded away.
        r = run(root, bindir)
        check("accounted for:" in r.stdout, "the report must state how much of `used` it explains")

        # --- --apply, the one path where being wrong destroys something ------
        #
        # Run LAST, because it mutates the fixture. Everything above ran
        # against the tree intact.
        core = root / "var/lib/apport/coredump/core._usr_bin_python3_12.0.abc.1"
        weights_hf = root / "home/u/.cache/huggingface/hub/models--org--m/blobs/x.safetensors"
        weights_loose = root / "var/tmp/jobs/ckpt-1/model-00001-of-00002.safetensors"
        check(core.exists() and weights_hf.exists() and weights_loose.exists(),
              "fixture was already mutated before --apply ran - an earlier mode deleted something")

        r = run(root, bindir, "--reclaim", "--apply")
        check(not core.exists(), "--apply did not remove the core dump it planned to")
        check(weights_hf.exists(),
              "--apply DELETED weights from the HF cache - this is the incident this tool must not cause")
        check(weights_loose.exists(),
              "--apply DELETED a checkpoint outside the HF cache")
        check((root / "swap.img").exists(), "--apply removed the swap file")
        check("now" in r.stdout, "--apply must report free space afterwards")

        # --- images built here are not a cache -------------------------------
        #
        # `docker system prune -af` was in the auto-apply tier until this
        # cluster was checked: three of six images, 65 GB, were built locally
        # and published nowhere, so a prune would have destroyed them and
        # `docker pull` could not have brought them back. An image with no
        # RepoDigests must therefore class as `image` and stay out of the plan.
        localonly = make_stubs(tmp / "local", avail_gb=400, local_only=True)
        r = run(root, localonly, "--reclaim")
        plan_l, _, held_l = r.stdout.partition("NOT in the plan")
        check("docker" not in plan_l,
              f"an image built HERE was put in the auto-apply plan:\n{plan_l}")
        check("/var/lib/docker" in held_l,
              "images built here must be listed as needing a decision")

        r = run(root, localonly)
        check("BUILT HERE" in r.stdout,
              "the report must say plainly that an image cannot be re-pulled")
        check(row_for(r.stdout, "BUILT HERE").strip().startswith("image"),
              f"locally-built images must class as `image`, got: {row_for(r.stdout, 'BUILT HERE').strip()}")

        # --- --top -----------------------------------------------------------
        r = run(root, bindir, "--top", "20")
        top = r.stdout
        check("/var/tmp/jobs" in top, "--top missed the largest directory in the fixture")
        check(f"{root}/var/tmp\n" not in top and not any(
            ln.strip().endswith(f"{root}/var/tmp") for ln in top.splitlines()),
            "--top must drop a parent that one child fully explains")

    for p in problems:
        print(f"  {p}", file=sys.stderr)
    if problems:
        print(f"\ncheck_storage: {len(problems)} problem(s)", file=sys.stderr)
        return 1
    print("check_storage: classification, plan safety, floor arithmetic and rollup all hold")
    return 0


if __name__ == "__main__":
    sys.exit(main())
