# Runbook: update packages without breaking CUDA

**The hazard:** a plain `apt upgrade` on this box wants to install
`nvidia-modprobe` **610** against driver **580**. That is the setuid helper
that creates `/dev/nvidia*`, it is version-locked to the kernel driver, and
DGX's pin file does not cover it. The result is `Failed to initialize NVML` on
next boot: no CUDA, no torch, no GPU containers.

Verify for yourself before believing it:

```bash
apt-get upgrade -s --with-new-pkgs | grep -i nvidia
```

## Normal path: let DGX do it

DGX OS ships its own OTA mechanism which applies an updated pin set *first*:

```bash
sudo systemctl status nvidia-spark-run-apt-upgrade-once
# or the DGX dashboard / OTA update flow
```

Prefer this. It is the path NVIDIA tests.

## Security updates only

`unattended-upgrades` is enabled and blacklisted for the driver and kernel
stack (`/etc/apt/apt.conf.d/51gx10-blacklist`), so routine security patching
happens without risking the driver.

Check what it would do:

```bash
sudo unattended-upgrade --dry-run --debug 2>&1 | tail -30
```

## Manual upgrade, deliberately

The playbook holds the driver stack, so a manual upgrade is safe *as long as
the holds are in place*:

```bash
apt-mark showhold            # must list nvidia-modprobe et al.
make apply TAGS=base         # (re)applies the holds
sudo apt update && sudo apt upgrade
```

Or via the playbook, which is the same thing plus the holds:

```bash
make apply TAGS=base EXTRA='-e allow_apt_upgrade=true'
```

## After any driver or kernel change

```bash
cat /var/run/reboot-required   # exists? reboot before trusting anything
sudo reboot
make verify                    # asserts nvcc, torch, and a real kernel launch
```

**Upgrade both nodes, and verify them together.** `make verify` with no
`--limit` compares driver and kernel version *across* the nodes and fails if
they disagree — two ranks on different drivers abort or hang at NCCL init with
an error that reads like a fabric problem, while each node verifies clean on its
own. A one-node upgrade is a two-node outage waiting for the next distributed
run.

## If you already broke it

Symptom: `nvidia-smi` reports `Failed to initialize NVML: Driver/library
version mismatch`, or `/dev/nvidia*` is missing.

```bash
# see what got skewed
dpkg -l | grep -E "nvidia-modprobe|nvidia-driver|nvidia-kernel"
nvidia-smi --query-gpu=driver_version --format=csv,noheader

# pin the helper back to the driver branch
sudo apt install --allow-downgrades \
  nvidia-modprobe=$(apt-cache madison nvidia-modprobe | awk '/ 580\./{print $3; exit}')
sudo apt-mark hold nvidia-modprobe
sudo reboot
```

If the kernel module itself is mismatched, reinstall the matching driver
metapackage for your branch rather than the newest one, then reboot.
