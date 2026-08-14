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

echo "==> Checking platform"
arch="$(uname -m)"
if [[ "$arch" != "aarch64" ]]; then
    echo "!! Expected aarch64 (GX10 is ARM). Found: $arch" >&2
    exit 1
fi
command -v nvidia-smi >/dev/null || { echo "!! nvidia-smi not found. Is this DGX OS?" >&2; exit 1; }
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

echo "==> Checking required collections"
for c in community.general ansible.posix community.crypto; do
    if ansible-galaxy collection list 2>/dev/null | grep -q "^$c "; then
        echo "    ok   $c"
    else
        echo "    !!   $c missing" >&2
        exit 1
    fi
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
cat > "$tmp_play" <<'PLAY'
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
  1. Put your laptop's public key in group_vars/all.yml under authorized_keys.
     Until you do, password SSH auth stays ON by design - the playbook proves
     a key login works before it will disable passwords.
  2. Apply:   ansible-playbook site.yml -K
  3. Verify:  ansible-playbook verify.yml
  4. Log out and back in (docker group, zsh, shell environment).

Run it under tmux. The play touches sshd and networking.
EOF
