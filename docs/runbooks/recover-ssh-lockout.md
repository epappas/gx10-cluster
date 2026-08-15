# Runbook: recover from an SSH lockout

**Symptom:** `Permission denied (publickey)` or the connection closes
immediately, and you cannot get back into a node.

## First: are you actually locked out?

From another machine on the LAN:

```bash
ssh -v <user>@<node>  2>&1 | tail -20
```

| What you see | Cause | Fix |
|---|---|---|
| `Permission denied (publickey)` | Password auth off, your key not accepted | A, B |
| `Connection closed by ... port 22` right after auth | Login shell missing/invalid | C |
| `Connection refused` | sshd not listening | D |
| `Connection timed out` from off-LAN, fine from the LAN | ufw source range | E, F |
| `No route to host` | Network config | E, F |

## A. Your key is being ignored (most common)

OpenSSH `StrictModes` can silently ignore **every** key in `authorized_keys`
when the file or `~/.ssh` is group- or world-writable. A non-empty file proves
nothing, and nothing is logged when it happens.

Note the "can". On these boxes it is measurably *not* happening: they shipped
with `~/.ssh/authorized_keys` at 0664 and public-key login works anyway
([the measurement](../decisions.md#authorized_keys-is-forced-to-0600-as-hygiene-not-as-a-fix)).
The repo tightens the permissions as hygiene, and this step is still the first
thing to try, but if it changes nothing then this was not your fault — go to B.

At the console (keyboard + monitor on the node):

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
sudo systemctl restart ssh
```

Confirm it took:

```bash
sudo journalctl -u ssh -n20 | grep Accepted    # want "Accepted publickey"
```

## B. Password auth was disabled without a working key

`ssh_disable_passwords` is an assertion **you** make. The repo refuses the
unrecoverable combination — `true` with an empty `authorized_keys` — and
otherwise takes you at your word. It does **not** probe your key first; it
cannot, because the private half is on your laptop
([why](../decisions.md#password-auth-is-disabled-only-by-an-explicit-human-decision)).
So this is reachable, and here is the way back:

```bash
sudo rm /etc/ssh/sshd_config.d/10-gx10.conf
sudo sshd -t && sudo systemctl restart ssh
```

Passwords work again. Then fix the key (A), add it to
`group_vars/all.yml` → `authorized_keys`, and re-run:

```bash
make apply TAGS=remote LIMIT=<node>
```

## C. Login shell is missing

If `default_shell` points at a binary that does not exist, sshd authenticates
you and then cannot exec a shell, so the connection closes instantly.

```bash
# at the console
chsh -s /bin/bash <user>
# or, as root
sudo usermod -s /bin/bash <user>
```

Then `sudo apt install -y zsh` before re-running the shell role.

## D. sshd is not listening

Ubuntu 24.04 socket-activates sshd. Check the **socket**, not the service:

```bash
systemctl status ssh.socket
sudo systemctl enable --now ssh.socket
```

`ssh.service` showing `disabled` is normal — it is triggered by the socket.

Also verify the merged config parses; an invalid fragment stops sshd starting
after a reboot:

```bash
sudo sshd -t
```

## E. Firewall or network

`ufw_ssh_sources` is `192.168.0.0/16` **and nothing else**. `10.0.0.0/8` and
`172.16.0.0/12` were removed deliberately — no traffic from those ranges reaches
a box on `192.168.4.0/22`, and 172.16/12 covered docker0's `172.17.0.0/16`,
handing every container a route to the host's sshd
([why](../decisions.md#ufw_ssh_sources-is-the-lan-and-nothing-else)). If you are
coming from a 10.x jump host, that is your answer.

```bash
sudo ufw status                     # is your source range allowed?
sudo ufw allow from <your-subnet> to any port 22 proto tcp
```

## F. Get in over Meshnet

NordVPN Meshnet is the out-of-LAN path, and ufw allows it by **interface**
(`nordlynx`), so it keeps working when the LAN source rules are wrong. This box
runs Meshnet only — it never calls `nordvpn connect`.

From your laptop, with both devices in the same Nord Account mesh:

```bash
nordvpn meshnet peer list           # find the node's meshnet name/IP
ssh <user>@<meshnet-ip>
```

On the node, to check the path exists at all:

```bash
ip -4 -br addr show nordlynx        # an address here means Meshnet is up
sudo nordvpn account                # "not logged in" means it is not
```

If it is not logged in, at the console:

```bash
sudo nordvpn login --token <TOKEN>  # POSITIONAL. --token=<TOKEN> fails
sudo nordvpn set meshnet on
```

Three traps, none of which announces itself:

- `--token` is a boolean flag. `--token=<TOKEN>` fails with
  `invalid boolean value`. The token goes after it, as its own argument.
- Plain `nordvpn logout` **revokes** the token. Use
  `nordvpn logout --persist-token` if you want to log back in with the same one.
- The `nordvpn` CLI needs group membership (`/run/nordvpn/nordvpnd.sock` is
  `root:nordvpn` 0660). The remote role adds you, but a group added mid-play is
  not in your current session — log out and back in, or use `sudo`.

Generate a token in Nord Account → NordVPN → Advanced settings → Get access
token. To persist it, put `nordvpn_token` in `group_vars/gx10/vault.yml` — the
directory form, which is the one ansible actually loads — never in
`group_vars/all.yml`. Full steps in
[provision-node](provision-node.md#join-the-meshnet).

## Prevention

- Always keep one shell open on the node while changing sshd.
- `make apply TAGS=remote` applies the sshd change immediately
  (`meta: flush_handlers`) rather than at end of play, so a bad config fails
  while you are still connected instead of at the next reboot. Note it flushes
  *all* pending handlers, so a docker restart notified earlier fires there too.
- Keep password auth enabled until you have verified, from another terminal,
  that `ssh -o PreferredAuthentications=publickey <user>@<node>` works. Nothing
  on the node can prove that for you.
- `make verify` reports `mesh vpn` as a non-required check. A node that is
  LAN-only is healthy, but it has exactly one way in.
