# Runbook: secrets, tokens and private values

**What** — where each kind of value lives, how to put a real secret in, and how
to rotate or revoke one.
**When** — before your first `make apply` with a gated model, when adding a
token, and whenever you clone this repo somewhere new.
**Risk** — **this is the runbook where a mistake is public and permanent.** A
token committed to a public repo is compromised the moment it is pushed, and
deleting the commit does not un-compromise it.

## Three tiers, and conflating them is the whole problem

| Tier | Where | Tracked? | For |
|---|---|---|---|
| **Default** | `group_vars/all.yml` | **yes** | What the repo does out of the box |
| **Private** | `group_vars/gx10/local.yml` | no | Private but **not secret** — your username, a local override |
| **Secret** | `group_vars/gx10/vault.yml` | no, **and encrypted** | `hf_token`, the NordVPN token |

Ansible loads them in that order and each outranks the last, so a private
override wins **without editing a tracked file** — which is the point
([the reasoning](../decisions.md#private-vars)).

**Note the directory form.** `group_vars/<group>/*` is auto-loaded;
`group_vars/<group>.local.yml` parses as a group named `<group>.local` and is
**silently never read**. The same trap applies to
`host_vars/<host>.vault.yml`.

### Which tier does this value belong in?

| Ask | Answer |
|---|---|
| Would it hurt if this leaked? | → **vault** |
| Is it nobody's business, but harmless? | → **local.yml** |
| Does a fresh clone need it to work? | → **`all.yml`, with a safe default** |

Encrypting a username with vault would be theatre. Committing a HF token would
not be.

**Defaults still live in the tracked file**, even for values you will override.
A private-only value breaks a fresh clone: `ansible_user: "{{ gx10_user }}"`
with `gx10_user` defined nowhere is an undefined-variable error *before the
first connection*.

## What is already kept out of the repo

`.gitignore` covers all of these. Check before you assume.

| Path | Holds |
|---|---|
| `.vault_pass` | The vault password itself |
| `group_vars/*/vault.yml`, `host_vars/*/vault.yml` | Encrypted secrets |
| `group_vars/*/local.yml`, `host_vars/*/local.yml` | Private-not-secret values |
| `inventory.yml` | Your hostnames and management addresses |
| `*.bak`, `*.orig`, `*~` | Editor backups — `inventory.yml.gx10.bak` held real addresses and was untracked but not *ignored*, so any `git add -A` would have published it |
| `workspaces/**/.env` | Per-workspace tokens and host paths |
| `workspaces/agent/*/dsh-home/*` | `dsh` config **and `.credentials.yaml`, a real key store** |
| `workspaces/agent/*/work/*` | Whatever the agent was pointed at — someone else's source tree |

The tracked counterparts are the `*.example` files: `inventory.example.yml`,
`group_vars/gx10/local.yml.example`, every `.env.example`,
`settings.example.yaml`.

## Steps

### 1. Set up the vault password

`ansible.cfg` sets `vault_password_file = .vault_pass`, so nothing has to pass
`--ask-vault-pass`.

```bash
head -c 32 /dev/urandom | base64 > .vault_pass
chmod 600 .vault_pass
```

**A missing `.vault_pass` is a hard error on every Ansible command, not a
fallback to prompting.** If you clone this repo without one, either create it or
comment that line out of `ansible.cfg`.

That is not only about convenience: `make render` renders `slurm.conf.j2`, which
reads hostvars for the `gx10` group — and that forces Ansible to decrypt
`group_vars/gx10/vault.yml`. Without a password **the whole test suite fails**
with "Attempting to decrypt but no vault secrets found", on exactly the machine
the token was set up on.

### 2. Put a real secret in

```bash
ansible-vault create group_vars/gx10/vault.yml     # first time
ansible-vault edit   group_vars/gx10/vault.yml     # after that
```

```yaml
---
hf_token: "hf_..."          # only needed for GATED repos
nordvpn_token: "..."        # a Nord Account access token
```

Read it back without editing:

```bash
ansible-vault view group_vars/gx10/vault.yml
```

### 3. Verify it is actually being used

```bash
make diff ASKPASS=          # a check run; secrets-touching tasks are no_log
```

The `models` role marks every task touching `hf_token` `no_log`, so a real value
never lands in the output — which also means **you cannot confirm it by reading
the log**. Confirm by effect instead: a gated model that previously 401'd now
downloads.

### 4. Values that are private but not secret

```bash
cp group_vars/gx10/local.yml.example group_vars/gx10/local.yml
$EDITOR group_vars/gx10/local.yml
```

```yaml
gx10_user: ubuntu                    # only if the account differs from yours
monitoring_history_interval: 30s     # any committed default, overridden locally
```

For a single run instead of a file:

```bash
make apply EXTRA='-e gx10_user=ubuntu'
```

Not `make apply -e …` — make eats `-e` as its own flag and it never reaches
Ansible.

### 5. Workspace secrets are separate, and per workspace

Workspaces are **not** Ansible and do not read the vault. Each has its own
gitignored `.env`, seeded from a tracked `.env.example`.

```bash
cd workspaces/inference/vllm-2node-deepseek-v4-flash
cp .env.example .env
$EDITOR .env                 # HF_TOKEN=..., PORT=..., MAX_MODEL_LEN=...
```

`ws up` sources `.env` before running the recipe. For the two-node workspaces
**there is only one `.env`, on rank 0** — both ranks are launched from there, so
there is no second file to keep in step
([why](two-node-serving.md)).

### 6. The agent harness holds real credentials

`workspaces/agent/deepseek-harness/dsh-home/.credentials.yaml` is a key store.
The whole `dsh-home/` directory is gitignored except its `.gitkeep`.

Two things about it worth doing deliberately:

- **`settings.yaml` names an environment variable, not a key.** `apiKeyEnv:
  LOCAL_API_KEY` — `compose.yml` supplies the value. A locally served model
  ignores it, but the client library refuses to send a request without
  *something* non-empty.
- **Leaving `DEEPSEEK_API_KEY` unset is a reasonable way to guarantee nothing
  reaches DeepSeek.** If you never configure the hosted provider, there is no
  outward path to misconfigure.

## SSH keys, which are not vault material

| Key | Where | Note |
|---|---|---|
| Cluster admin key | generated at `~/.ssh/gx10_admin` on the node | **Its private half does not belong on the nodes.** Move it to your laptop ([how](provision-node.md#the-cluster-admin-key)) |
| Inter-node key | `~/.ssh/id_gx10_cluster` per node | Generated per node, cross-authorized by the `cluster` role's trust play |
| Your laptop key | added to `authorized_keys` in `group_vars/all.yml` | A **public** key. Committing it is fine and is the intent |

`authorized_keys` in `group_vars/all.yml` is a tracked list of *public* keys.
That is not a leak — it is how a dedicated cluster admin key can be revoked in
one line without touching any other machine you log in to
([why a dedicated key](../decisions.md#a-dedicated-cluster-admin-key-not-a-reused-personal-one)).

**The list is additive.** The `authorized_key` module never removes what it did
not add, which is what keeps the per-node inter-node keys from being wiped on
the next run. The cost: **removing access is manual**. Deleting a line from
`group_vars/all.yml` does not remove the key from the nodes.

## Rotating and revoking

### A leaked HF or NordVPN token

1. **Revoke it at the provider first.** Editing the vault does nothing to a
   token that is already out.
2. `ansible-vault edit group_vars/gx10/vault.yml` — put the new one in.
3. `make apply TAGS=models` (HF) or `make apply TAGS=remote` (NordVPN).

### The vault password itself

```bash
ansible-vault rekey group_vars/gx10/vault.yml     # prompts for old, then new
# then update .vault_pass to the new password
```

### An SSH key

1. Remove the line from `authorized_keys` in `group_vars/all.yml`.
2. **Delete it from `~/.ssh/authorized_keys` on every node by hand** — Ansible
   will not.
3. Confirm from a machine that should no longer have access.

Do this from a session you can afford to lose, and read
[recover-ssh-lockout](recover-ssh-lockout.md) first.

## If a secret was committed

Assume it is compromised. In this order:

1. **Revoke at the provider.** Immediately. This is the only step that actually
   helps.
2. Issue a replacement and put it in the vault.
3. Only then worry about history. `git filter-repo` or a fresh repo — but a
   pushed secret is public regardless of what the history says afterwards.

Prevention, which is cheaper: `.pre-commit-config.yaml` runs on every commit,
and `make check` runs the same checks CI does. Neither is a secret scanner —
they are lint — so the gitignore rules above are the actual guard. **Check
`git status` before `git add -A`.**

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| Every Ansible command: "Attempting to decrypt but no vault secrets found" | No `.vault_pass`, on a repo that has a vault | Create it, or comment the line in `ansible.cfg` |
| `make check` fails on a fresh clone, on `render` | Same cause — `slurm.conf.j2` forces vault decryption | Same fix |
| A vault file is ignored entirely | You used `host_vars/<host>.vault.yml` | Directory form only: `host_vars/<host>/vault.yml` |
| A `local.yml` override does nothing | Same trap: `group_vars/gx10.local.yml` is a group named `gx10.local` | `group_vars/gx10/local.yml` |
| 401/403 downloading a model | `hf_token` empty, or the repo is gated to an account without access | [manage-models](manage-models.md#gated-models) |
| The token is right and it still 401s | You edited `all.yml`, and `vault.yml` overrides it | Check the tier order — later wins |
| `nordvpn login` hangs forever | Unrelated to the token: the client asks about telemetry interactively with no stdin | `nordvpn_analytics` is recorded **before** login by `roles/remote` ([why](../decisions.md#meshnet)) |
| A workspace cannot see `HF_TOKEN` | Workspaces do not read the vault | Put it in that workspace's `.env` |
| `make apply -e foo=bar` has no effect | make ate `-e` | `make apply EXTRA='-e foo=bar'` |
| `dsh-home` fills with root-owned files | `DSH_UID`/`DSH_GID` do not match you | Set them in the workspace `.env` |

## See also

- [decisions: three tiers](../decisions.md#private-vars) — why it is shaped this way
- [SECURITY.md](../../SECURITY.md) — the deliberate posture and accepted risks
- [provision-node](provision-node.md) — the cluster admin key and the Meshnet join
- [recover-ssh-lockout](recover-ssh-lockout.md) — before you touch key access
