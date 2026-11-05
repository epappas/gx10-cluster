ARG BASE_IMAGE=ghcr.io/miaai-lab/glm-5.3-flash-exl3-2x-dgx-sparks-tensorfold@sha256:14b5072e8e9918f1080153f57321415a387bc7d78cf9c9b44a7aeae2d4399ccf
FROM ${BASE_IMAGE}
ARG BASE_IMAGE
ARG KIT_SHA
COPY apply.py manifest.json LICENSE NOTICE /opt/tf-backports/
COPY patches/ /opt/tf-backports/patches/
RUN python3 -I -B /opt/tf-backports/apply.py apply --kit-sha "${KIT_SHA}" \
    && python3 -I -B /opt/tf-backports/apply.py verify --kit-sha "${KIT_SHA}"
LABEL tf.patches="cf77716d4733" \
    gx10.glm.parent="${BASE_IMAGE}" \
    gx10.glm.kit="${KIT_SHA}" \
    gx10.glm.fix.0118="1a24d84e15a6aa0082706be66a97e8a59e7bba71" \
    gx10.glm.fix.0121="813dafb92065267ff97c1d8c0a2bbf4f056ee9cb"
