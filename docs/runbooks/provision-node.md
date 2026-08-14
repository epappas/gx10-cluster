# Runbook: provision a GX10 node

**What** — take a factory GX10 to a working dev/ML node.
**When** — new box, or rebuilding one.
**Time** — 30–60 min, mostly the llama.cpp build.
**Risk** — touches sshd and package state. Run under `tmux`.

## Before you start

- [ ] Node is on the network and you can log in
- [ ] Your public key is in `group_vars/all.yml` → `authorized_keys`
- [ ] You know the sudo password (`make apply` prompts for it)

Skipping the key is fine — the playbook then deliberately leaves password SSH
auth on rather than locking you out ([why](../decisions.md)).

## How — node 1

```bash
git clone <repo> && cd gx10-cluster
./bootstrap.sh          # installs ansible via uv, no sudo
tmux new -s prov
make diff               # optional: preview changes
make apply
make verify
```

Then **log out and back in** — required for the docker group, the zsh login
shell, and the shell environment.

## How — node 2

> Do **not** use `--limit`. The nodes exchange interconnect SSH keys with each
> other during the run; a limited run establishes trust one way only, and the
> cluster role will warn you about it.

1. Get node 2 on the LAN; note its address.
2. `ssh-copy-id <user>@<node-2-address>`
3. Add the `gx10-b` block to `inventory.yml` (the header shows the shape),
   setting `ansible_host`, `ansible_user`, `cluster_index: 11`.
4. Run the full play:

```bash
make apply
```

`serial: 1` does them one at a time; `any_errors_fatal` stops before touching
the second box if the first fails.

## Verify

```bash
make verify
```

All checks must pass except the three cable-dependent ones, which stay red
until you [connect the cluster](connect-cluster.md).

Then confirm nothing churns on a repeat run:

```bash
make idempotence        # second apply must report changed=0
```

## When it fails partway

The play is idempotent — fix the cause and re-run. Nothing needs unwinding.

```bash
make apply TAGS=ml      # re-run just the role that failed
```

## Your first session

Everything lives where the shell environment points it:

```bash
ml                       # activate the shared venv (~/venvs/ml) - torch lives here
pcore <cmd>              # pin to the performance cores (5-9,15-19)
gpuw                     # watch the GPU
llama-cli --help         # llama.cpp binaries are on PATH
ollama run <model>       # bound to localhost; tunnel in with ssh -L 11434:localhost:11434
```

`torchrun` is **not** on PATH — it is `~/venvs/ml/bin/torchrun`, or run `ml`
first. Models land in `~/.cache/huggingface` and ollama's own store.

## Rollback

No automated rollback, by design: the roles are additive and idempotent. To
undo specific changes:

| Change | Undo |
|---|---|
| Package holds | `sudo apt-mark unhold $(apt-mark showhold)` |
| sysctl | `sudo rm /etc/sysctl.d/90-gx10.conf && sudo sysctl -w vm.swappiness=60 vm.min_free_kbytes=45155` |
| limits | `sudo rm /etc/security/limits.d/90-gx10.conf` |
| sshd | `sudo rm /etc/ssh/sshd_config.d/99-gx10.conf && sudo systemctl restart ssh` |
| firewall | `sudo ufw disable` |
| interconnect | `sudo nmcli con delete gx10-cluster-0 gx10-cluster-1` |
| docker daemon | restore the timestamped `daemon.json.*~` backup the role writes |
| docker group | `sudo gpasswd -d $USER docker` |
| apt policy | `sudo rm /etc/apt/apt.conf.d/51gx10-blacklist /etc/apt/apt.conf.d/20auto-upgrades` |
| NCCL / ollama | `sudo rm /etc/nccl.conf /etc/systemd/system/ollama.service.d/override.conf` |
| shell env | `rm ~/.gx10env.sh` and delete the ANSIBLE MANAGED blocks in `~/.bashrc`, `~/.zshrc` |
| hosts / ssh config | delete the ANSIBLE MANAGED blocks in `/etc/hosts` and `~/.ssh/config` |
| login shell | `chsh -s /bin/bash` |

Note `sysctl --system` alone does **not** restore the tuned values — nothing
else on the box sets `vm.swappiness` or `vm.min_free_kbytes`, so they persist
until you set them back explicitly or reboot.
