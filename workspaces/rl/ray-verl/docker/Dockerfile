# verl on a GB10, built on the vLLM image THIS REPO ALREADY RUNS.
#
# WHY NOT verlai/verl. Two independent reasons, both measured on this hardware:
#
#   1. No verlai/verl image CONTAINS verl - that is by design, their install
#      docs say "you only need to install verl itself without dependencies".
#   2. The arm64 ones cannot execute on GB10. verl's vLLM rollout dies with
#        CUDA error: no kernel image is available for execution on the device
#      and it is NOT the torch arch list, which is identical in both images
#      (sm_80..sm_120, device sm_121 - binary compatible, as this repo has
#      documented since the DeepSeek port). It is vLLM's own CUDA extensions,
#      built there without an sm_121-capable target and built here with one.
#
# So the base is the image every other vLLM workspace in this repo serves
# from, which is verified on sm_121, and verl is installed on top of it.
ARG BASE=vllm/vllm-openai:nightly-aarch64
FROM ${BASE}

# verl's runtime deps that the vLLM image does not already carry. --no-deps for
# verl itself so it cannot drag in a torch or vllm that undoes the whole point.
RUN pip3 install --no-cache-dir \
        "ray[default]" tensordict codetiming hydra-core datasets peft \
        torchdata pylatexenc accelerate dill pybind11 \
 && rm -rf /root/.cache/pip

# The source is MOUNTED, not copied: it is pinned by VERL_VERSION in up.sh and
# a mount keeps the image independent of which verl you are running.
WORKDIR /workspace/verl
ENTRYPOINT []
CMD ["bash"]
