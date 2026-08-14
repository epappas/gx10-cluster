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
| `No route to host` | Network config | E |

## A. Your key is being ignored (most common)

OpenSSH `StrictModes` silently ignores **every** key in `authorized_keys` if
the file or `~/.ssh` is group- or world-writable. A non-empty file proves
nothing.

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

This repo is built not to do that — it probes an actual public-key login
first — but if it happened:

```bash
sudo rm /etc/ssh/sshd_config.d/99-gx10.conf
sudo sshd -t && sudo systemctl restart ssh
```

Passwords work again. Then fix the key (A), add it to
`group_vars/all.yml` → `authorized_keys`, and re-run:

```bash
make apply TAGS=remote
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

```bash
sudo ufw status                     # is your source range allowed?
sudo ufw allow from <your-subnet> to any port 22 proto tcp
```

If you have Tailscale up, that path is allowed by interface and should still
work even when the LAN rules are wrong:

```bash
tailscale status
ssh <user>@<tailscale-ip>
```

## Prevention

- Always keep one shell open on the node while changing sshd.
- `make apply TAGS=remote` applies the sshd change immediately
  (`meta: flush_handlers`) rather than at end of play, so a bad config fails
  while you are still connected instead of at the next reboot.
- Keep password auth enabled until `make verify` shows the key path working.
