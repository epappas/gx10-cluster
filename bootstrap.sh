#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Bootstrap a fresh GX10 to the point where Ansible can take over.
#
# This is the only thing you run by hand. Everything after it is declarative.
#
#   node 1 (this box):  ./bootstrap.sh && ansible-playbook site.yml -K
#   node 2 (new box):   scp -r gx10-cluster/ user@node2:  then the same two
#                       commands there, or drive it from node 1 over SSH:
#                       ansible-playbook site.yml --limit gx10-b -K
# ---------------------------------------------------------------------------
set -euo pipefail

echo "==> Checking platform"
arch="$(uname -m)"
if [[ "$arch" != "aarch64" ]]; then
    echo "!! Expected aarch64 (GX10 is ARM). Found: $arch" >&2
    exit 1
fi

if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "!! nvidia-smi not found. Is this a DGX OS install?" >&2
    exit 1
fi
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader

echo "==> Installing uv"
# uv ships with DGX OS on GX10, but install it if this is a rebuilt box.
if [[ ! -x "$HOME/.local/bin/uv" ]]; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi
export PATH="$HOME/.local/bin:$PATH"

echo "==> Installing ansible"
# Deliberately via uv, not apt: Ubuntu 24.04 ships ansible-core 2.16, and no
# sudo is needed. Note the '--with ansible' - the ansible-core package alone
# provides the ansible-playbook binary but none of the collections, while the
# 'ansible' package alone provides collections but no usable entrypoints.
# The roles need community.general, ansible.posix and community.crypto.
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

echo "==> Syntax check"
cd "$(dirname "$0")"
ansible-playbook site.yml --syntax-check

cat <<'EOF'

Bootstrap complete.

Next:
  1. Put your laptop's public key in group_vars/all.yml under authorized_keys
     (otherwise password SSH auth stays on, by design, to avoid a lockout).
  2. Dry run:   ansible-playbook site.yml -K --check --diff
  3. Apply:     ansible-playbook site.yml -K
  4. Verify:    ansible-playbook verify.yml

Note: --check on a fresh box reports failures for tasks that inspect things
the earlier tasks have not created yet. That is expected; it is not a reason
to skip step 3.

EOF
