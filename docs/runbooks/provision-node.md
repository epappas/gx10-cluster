# Runbook: provision a GX10 node

**What** — take a factory GX10 to a working dev/ML node.
**When** — new box, or rebuilding one.
**Time** — 30–60 min per node, mostly the llama.cpp build. Add hours if you let
the `models` role run: ~130 GB of weights.
**Risk** — touches sshd and package state. Run under `tmux`.

## Before you start

- [ ] You can SSH to every node you are about to provision — **including the one
      you are typing on**, which the play reaches over SSH like any other host
      ([why](../decisions.md#ssh-both-nodes))
- [ ] Their addresses match `ansible_host` in `inventory.yml`, and the
      inventory name is the hostname you want the machine to have — the play
      sets it (see [Renaming a node](#renaming-a-node))
- [ ] The cluster admin public key is in `group_vars/all.yml` →
      `authorized_keys`, and you hold its private half
      (see [The cluster admin key](#the-cluster-admin-key))
- [ ] **First run only:** every node accepts the **same** sudo password — `-K`
      prompts once per run, not once per host. After the first successful run
      `sudo_passwordless` has installed a sudoers drop-in and `-K` is no longer
      needed on either box
- [ ] You are **not** running as root. `site.yml` refuses: everything lands in
      the connecting user's home, and under `sudo` that is `/root`

Doing one node at a time is fine and is what the section below assumes — use
`LIMIT=`. Just do not use it for the *final* run; see node 2.

Skipping the key is fine — the playbook then deliberately leaves password SSH
auth on rather than locking you out
([why](../decisions.md#password-auth-is-disabled-only-by-an-explicit-human-decision)).

## How — node 1

`bootstrap.sh` checks `uname -m` and `nvidia-smi`, so the control node is one of
the GX10s. `make lock` has the same constraint, for the same reason.

```bash
git clone <repo> && cd gx10-cluster
./bootstrap.sh          # installs ansible via uv, no sudo
tmux new -s prov
make diff               # optional: preview changes
make apply LIMIT=odysseus SKIP=models
make verify LIMIT=odysseus
```

`SKIP=models` is worth it on the first pass: the weights are the long pole and
`make models` picks them up later, resumably.

Then **log out and back in** — required for the `docker` and `nordvpn` groups,
the zsh login shell, and the shell environment.

## How — node 2

Both nodes are already in `inventory.yml`, so there is nothing to add. Get the
box on the LAN at the address `poseidon` declares, then:

1. `ssh-copy-id <user>@192.168.4.37`, or make sure password auth works.
2. Run the full play — **no `--limit` this time**:

```bash
make apply
```

> Two things a limited run cannot do. The nodes cross-authorize their
> interconnect SSH keys in a second play at the end of `site.yml`, which only
> works once every host has generated one — a limited run establishes trust one
> way and the cluster role warns you about it. And `optional.yml --tags slurm`
> distributes a munge key generated on the controller, which a run excluding it
> cannot produce.

`serial: 1` does the nodes one at a time; `any_errors_fatal` stops before
touching the second box if the first fails.

## Verify

```bash
make verify
```

All required checks must pass. The non-required ones are reported and never
fatal — the cable-dependent trio (`RDMA devices`, `interconnect addressed`,
`both interconnect partitions`) stays red until you
[connect the cluster](connect-cluster.md), `docker without sudo` until you have
re-logged in, and `mesh vpn` until NordVPN has a token.

Run it with **no `--limit`**: the cross-node comparison of driver, kernel and
torch version needs both hosts in the play, and it says so rather than passing
silently when it cannot.

Then confirm nothing churns on a repeat run:

```bash
make idempotence        # second apply must report changed=0
```

## When it fails partway

The play is idempotent — fix the cause and re-run. Nothing needs unwinding.

```bash
make apply TAGS=ml      # re-run just the role that failed
```

## <a name="the-cluster-admin-key"></a>The cluster admin key

`authorized_keys` carries one key by default: `gx10-cluster-admin`, an ed25519
pair generated once for this cluster and used for nothing else. A dedicated key
rather than a reused personal one so that revoking cluster access is a single
line here, with no effect on any other machine you log into.

**Its private half must not stay on a node.** It was generated on `odysseus` at
`~/.ssh/gx10_admin`. Move it to wherever you actually log in from, then remove
it from the cluster:

```bash
# from your laptop
scp epappas@192.168.4.36:.ssh/gx10_admin ~/.ssh/gx10_admin
chmod 600 ~/.ssh/gx10_admin
ssh-keygen -p -f ~/.ssh/gx10_admin        # add a passphrase; it has none

# then, on odysseus
shred -u ~/.ssh/gx10_admin                # the .pub can stay
```

Use it with `ssh -i ~/.ssh/gx10_admin epappas@odysseus`, or give it a `Host`
block in your laptop's `~/.ssh/config`.

Adding your own key alongside it is one line in `group_vars/all.yml`:

```yaml
authorized_keys:
  - "ssh-ed25519 AAAAC3Nza... gx10-cluster-admin"
  - "ssh-ed25519 AAAAC3Nza... you@laptop"
```

then `make apply TAGS=remote`. The list is additive — the module never removes
keys it did not add, which is what stops it wiping the per-node inter-node keys
that `trust.yml` cross-authorizes.

To revoke: delete the line, re-run, and confirm with
`grep gx10-cluster-admin ~/.ssh/authorized_keys` on both nodes — `state:
present` does not remove, so `authorized_key` needs the entry gone *and* the
stale line deleted by hand on a node that already has it.

## <a name="join-the-meshnet"></a>Remote access: join the Meshnet

Provisioning installs the NordVPN client, enables the daemon and opens `ufw` on
`nordlynx`, but it **cannot log in for you** — that needs a token. Until you
supply one, the nodes are reachable on the LAN only, and `make verify` reports
`mesh vpn` as a non-fatal failure.

**1. Get a token.** Nord Account → **NordVPN** → scroll to **Advanced
settings** → **Get access token** → verify the emailed code → **Generate new
token**. Choose non-expiring unless you want to redo this every 30 days. It is
shown once.

**2. Either** log in by hand on each node:

```bash
sudo nordvpn login --token <TOKEN>     # token is POSITIONAL - see below
sudo nordvpn set meshnet on
```

**or** let Ansible do it on both, which is the point of having Ansible. The
token belongs to your Nord *account*, not to a machine, so it goes in
`group_vars` for the whole cluster rather than per host:

```bash
mkdir -p group_vars/gx10
ansible-vault create group_vars/gx10/vault.yml
```

```yaml
nordvpn_token: "<TOKEN>"
```

```bash
make apply TAGS=remote EXTRA='--ask-vault-pass'
```

**The directory form is not cosmetic.** Ansible auto-loads
`group_vars/<group>/*` and `host_vars/<host>/*`, or a single
`group_vars/<group>.yml` — but **not** `host_vars/<host>.vault.yml`, which this
runbook used to tell you to create. A dot in that position makes Ansible read
it as a host named `<host>.vault`, so the file is silently never loaded: you
would set the token, see no error, and Meshnet would stay down.

If you do want a per-node token, the working path is
`host_vars/odysseus/vault.yml` — note the slash.

`group_vars/*/vault.yml` and `host_vars/*/vault.yml` are both in `.gitignore`.
Every task that touches the token is `no_log`.

Rather than typing the vault password each run, put it in `.vault_pass`
(also gitignored) and add `vault_password_file = .vault_pass` to the
`[defaults]` section of `ansible.cfg`.

**3. Confirm:**

```bash
nordvpn meshnet peer list      # the other node and your laptop should appear
ip -4 -br addr show nordlynx   # a 100.64.0.0/10 address
make verify                    # `mesh vpn` should now pass
```

Three things that will bite you:

- **`--token` is a boolean flag; the token is a positional argument.**
  `nordvpn login --token=<TOKEN>` fails with
  `invalid boolean value "<TOKEN>" for -token: parse error`. Use a space.
- **Plain `nordvpn logout` revokes the token.** Use
  `nordvpn logout --persist-token` if you intend to log back in with it.
- **Peers cannot reach containers by default.** Meshnet treats `172.17.0.0/16`
  — docker0 — as local and drops peer traffic to it, so vLLM is invisible over
  the mesh until `nordvpn meshnet peer local allow all` runs. The role does
  this for you; it is listed here because it looks like a firewall problem when
  it is not.

## <a name="renaming-a-node"></a>Renaming a node

The inventory name **is** the hostname. `node_hostname` defaults to it, and
`roles/base` applies it, so the machine's `hostname`, its `/etc/hosts` entry,
its `~/.ssh/config` block, the Slurm `NodeName` and the Prometheus `instance`
label all follow one string.

```bash
# in inventory.yml, rename the host key, then:
make apply TAGS=base,cluster LIMIT=<new-name>
```

Rename **both** the inventory key and nothing else — `ansible_host`,
`cluster_index` and `cluster_rank` stay as they are. Run the `cluster` tag too,
or the *other* node's `/etc/hosts` and `~/.ssh/config` keep pointing at the old
name.

Set `node_hostname` in `host_vars/` only if you genuinely need the Ansible alias
and the system hostname to differ. They should not.

## Your first session

Everything lives where the shell environment points it:

```bash
ml                       # activate the shared venv (~/venvs/ml) - torch lives here
pcore <cmd>              # pin to the performance cores (5-9,15-19)
gpuw                     # watch the GPU
gx10-status              # GPU, throttling, unified memory, swap - no daemon
llama-cli --help         # llama.cpp binaries are on PATH
ollama run <model>       # bound to localhost; tunnel in with ssh -L 11434:localhost:11434
```

`torchrun` is **not** on PATH — it is `~/venvs/ml/bin/torchrun`, or run `ml`
first. Models land in `~/.cache/huggingface` and ollama's own store.

There is no prompt theme and no `eza`; `bat` and `fd` are apt's `batcat` and
`fdfind`, aliased back by the shell fragment
([why](../decisions.md#rust-is-pinned-to-a-toolchain-and-three-clis-are-not-built-from-source)).

## Rollback

No automated rollback, by design: the roles are additive and idempotent. To
undo specific changes:

| Change | Undo |
|---|---|
| Package holds | `sudo apt-mark unhold $(apt-mark showhold)` |
| sysctl | `sudo rm /etc/sysctl.d/90-gx10.conf && sudo sysctl -w vm.swappiness=60 vm.min_free_kbytes=45155` |
| limits | `sudo rm /etc/security/limits.d/90-gx10.conf` |
| sshd | `sudo rm /etc/ssh/sshd_config.d/10-gx10.conf && sudo systemctl restart ssh` |
| firewall | `sudo ufw disable` |
| interconnect | `sudo nmcli con delete gx10-cluster-0 gx10-cluster-1` |
| docker daemon | restore the timestamped `daemon.json.*~` backup the role writes |
| docker group | `sudo gpasswd -d $USER docker` |
| apt policy | `sudo rm /etc/apt/apt.conf.d/51gx10-blacklist /etc/apt/apt.conf.d/20auto-upgrades` |
| NCCL | `sudo rm /etc/nccl.conf` |
| ollama | `sudo systemctl disable --now ollama && sudo rm -rf /etc/systemd/system/ollama.service{,.d} /usr/local/bin/ollama /usr/local/lib/ollama` |
| Meshnet | `sudo nordvpn set meshnet off`, then `sudo nordvpn logout --persist-token` — plain `logout` **revokes** the token |
| ML venv | `rm -rf ~/venvs/ml` — self-contained, lockfile included |
| shell env | `rm ~/.gx10env.sh` and delete the ANSIBLE MANAGED blocks in `~/.bashrc`, `~/.zshrc` |
| hosts / ssh config | delete the ANSIBLE MANAGED blocks in `/etc/hosts` and `~/.ssh/config` |
| login shell | `chsh -s /bin/bash` |

Note `sysctl --system` alone does **not** restore the tuned values — nothing
else on the box sets `vm.swappiness` or `vm.min_free_kbytes`, so they persist
until you set them back explicitly or reboot.
