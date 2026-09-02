#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Bootstrap a fresh GX10 to the point where Ansible can take over.
# This is the only thing you run by hand.
#
#   node 1:  ./bootstrap.sh && ansible-playbook site.yml -K
#   node 2:  copy this repo over, run the same two commands there - or add it
#            to inventory.yml and drive it from node 1.
# ---------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")"

# inventory.yml is gitignored, so a fresh clone has none - and the play check
# below parses it. Seed from the example rather than failing on a file the
# clone was never going to contain.
if [ ! -f inventory.yml ]; then
  cp inventory.example.yml inventory.yml
  echo "    ok   seeded inventory.yml from inventory.example.yml - EDIT IT"
fi

# ansible.cfg sets vault_password_file, and a MISSING one is a hard error on
# every ansible command - not a fallback to prompting. A fresh clone has none,
# so without this the very next check in this script fails with a vault error
# that has nothing to do with what it was testing.
if [ ! -f .vault_pass ]; then
  umask 077
  printf 'change-me-if-you-add-a-vault\n' >.vault_pass
  echo "    ok   created a placeholder .vault_pass (no vault file to decrypt yet)"
fi

echo "==> Checking platform"
arch="$(uname -m)"
if [[ $arch != "aarch64" ]]; then
  echo "!! Expected aarch64 (GX10 is ARM). Found: $arch" >&2
  exit 1
fi
command -v nvidia-smi >/dev/null || {
  echo "!! nvidia-smi not found. Is this DGX OS?" >&2
  exit 1
}
nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader

echo "==> Installing uv"
if [[ ! -x "$HOME/.local/bin/uv" ]]; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
export PATH="$HOME/.local/bin:$PATH"

echo "==> Installing ansible"
# Note '--with ansible': ansible-core alone provides the ansible-playbook
# binary but no collections, while the 'ansible' package alone provides
# collections but no usable entrypoints. The roles need community.general,
# ansible.posix and community.crypto.
if ! command -v ansible-playbook >/dev/null 2>&1; then
  uv tool install --with ansible ansible-core
fi
ansible --version | head -1

echo "==> Installing the pinned collections"
# Install, not merely check. The `ansible` bundle ships whatever collection
# versions it was built with, which is usually - but not always - inside the
# ranges requirements.yml declares. Checking for presence let a wrong version
# through and made those pins decorative on exactly the machine they exist to
# protect.
ansible-galaxy collection install -r requirements.yml
for c in community.general ansible.posix community.crypto; do
  ansible-galaxy collection list 2>/dev/null | grep -q "^$c " || {
    echo "    !!   $c still missing after install" >&2
    exit 1
  }
done

echo "==> Validating the playbook"
ansible-playbook site.yml --syntax-check >/dev/null
echo "    ok   syntax"

# --syntax-check does NOT load stdout callbacks, so it happily passes on a
# config that aborts every real run. This repo shipped exactly that bug once
# (stdout_callback = yaml, a plugin removed in community.general 12.0.0).
# Execute a trivial play so the whole config path is exercised for real.
tmp_play="$(mktemp -t gx10-probe-XXXXXX.yml)"
trap 'rm -f "$tmp_play"' EXIT
cat >"$tmp_play" <<'PLAY'
- hosts: localhost
  connection: local
  gather_facts: false
  tasks: [{ ansible.builtin.debug: { msg: ok } }]
PLAY
if ansible-playbook "$tmp_play" >/dev/null 2>&1; then
  echo "    ok   ansible.cfg loads and a real play runs"
else
  echo "    !!   ansible.cfg is broken - a real play fails to run:" >&2
  ansible-playbook "$tmp_play" 2>&1 | head -5 >&2
  exit 1
fi

cat <<'EOF'

Bootstrap complete.

Next:
  0. Edit inventory.yml - your hostnames and addresses. It is gitignored and
     was seeded from inventory.example.yml, whose 192.0.2.x addresses are
     RFC 5737 documentation addresses and route nowhere on purpose.
  1. Put your laptop's public key in group_vars/all.yml under authorized_keys.
     Password SSH auth stays ON until you ALSO set ssh_disable_passwords, and
     that is a decision you make after checking from another terminal that key
     login works - nothing on the node can prove that for you.
  2. Apply:   ansible-playbook site.yml -K
  3. Verify:  ansible-playbook verify.yml
  4. Log out and back in (docker and nordvpn groups, zsh, shell environment).

Run it under tmux. The play touches sshd and networking.
EOF
