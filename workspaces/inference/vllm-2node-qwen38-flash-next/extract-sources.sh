#!/usr/bin/env bash
# Copy the four vLLM source files the patches operate on out of the image.
#
# WHY THIS EXISTS. Two of this workspace's five patches rewrite Python that
# ships INSIDE the serving image, and a patch written against source nobody has
# read is a guess that fails closed at best and applies wrongly at worst. So
# the sources come out first, the patches are written against them, and both
# patches preflight their own anchors before writing.
#
# This is the one step that cannot be done ahead of time on a node that does
# not have the image: it is a ~20.6 GB pull.
#
#   ./extract-sources.sh          -> patches/src/*.py
#
# The image is NOT modified. Files land read-only beside the patches, and
# patches/src/ is gitignored - they are vLLM's sources under Apache-2.0, not
# ours to vendor.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
[[ -f .env ]] && { set -a; . ./.env; set +a; }

IMAGE=${IMAGE:-vllm/vllm-openai:qwen38-flash-next}
PKG=/usr/local/lib/python3.12/dist-packages/vllm
DEST=$PWD/patches/src

# The four files, and what each is wanted for:
#   ple_layer.py  the PLE quant-method resolver      -> ple_fp8_resolver.py
#   modelopt.py   MXFP8 linear kernel selection      -> mxfp8_kernel_fallback.py
#   ops/qsa.py    QSA kernel dtype declaration       -> reference only (fp8 KV)
#   mtp.py        the MTP draft head                 -> reference only
FILES=(
    "models/qwen3_8_flash_next/nvidia/ple_layer.py"
    "model_executor/layers/quantization/modelopt.py"
    "models/qwen3_8_flash_next/nvidia/ops/qsa.py"
    "models/qwen3_8_flash_next/nvidia/mtp.py"
)

docker image inspect "$IMAGE" >/dev/null 2>&1 || {
    echo "==> pulling $IMAGE (~20.6 GB, this is the slow part)"
    docker pull "$IMAGE"
}

mkdir -p "$DEST"
c=$(docker create "$IMAGE" /bin/true)
trap 'docker rm -f "$c" >/dev/null 2>&1 || true' EXIT
for f in "${FILES[@]}"; do
    out=$DEST/$(basename "$f")
    if docker cp "$c:$PKG/$f" "$out" 2>/dev/null; then
        chmod 0444 "$out"
        printf '  %-14s %s\n' "$(basename "$f")" "$(wc -l < "$out") lines"
    else
        # A path that moved between image builds is worth naming loudly: the
        # patches pin these locations too, so a silent miss here becomes a
        # confusing anchor failure later.
        echo "  MISSING  $f - the image layout changed; update FILES and the patches" >&2
    fi
done

echo
echo "sources in $DEST (read-only, gitignored)."
echo "now write the two mandatory patches against them - patches/README.md has"
echo "the exact mechanism each one needs."
