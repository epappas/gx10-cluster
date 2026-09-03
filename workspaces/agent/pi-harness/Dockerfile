# Pi, containerised. This is upstream's OWN "Plain Docker" recipe from
# packages/coding-agent/docs/containerization.md, with three changes noted
# below - not an invention of this repo.
#
# WHY AN IMAGE AND NOT `npx`. The sibling deepseek-harness runs `npx -y ...`
# on every start and pays ~7.5 minutes of npm resolution the first time. Pi is
# a TUI you start and stop many times a day, so the resolution cost lands on
# every run rather than once. Baking it into a layer moves that to build time.
ARG NODE_IMAGE=node:24-bookworm-slim
FROM ${NODE_IMAGE}

# CHANGE 1: pinned, and the pin is also the image tag (see up.sh). Pi ships
# most weeks; an unpinned image is a different agent every time you rebuild,
# and `pi --version` inside a stale container is then the only way to find out.
ARG PI_VERSION

# ripgrep is upstream's list, not ours: pi's `grep` tool shells out to it.
# git is here because the agent is pointed at a source tree.
RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates git ripgrep \
    && rm -rf /var/lib/apt/lists/*

# --ignore-scripts is upstream's instruction, and their supply-chain section
# explains why: pi needs no lifecycle scripts, so running them only widens what
# a compromised transitive dependency can reach.
RUN npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@${PI_VERSION}"

# CHANGE 2: config directory by ENV rather than by $HOME. Upstream mounts a
# volume at /root/.pi/agent, which forces the container to run as root. Pi
# reads PI_CODING_AGENT_DIR for exactly this, so the state directory is a
# plain, visible, user-owned path on both sides of the mount.
ENV PI_CODING_AGENT_DIR=/pi
# 0777 on an EMPTY container-local directory, so `--user $(id -u):$(id -g)`
# works for any uid without the image having to guess yours. Nothing in the
# image lives here; the real state is the bind mount up.sh puts on top.
RUN install -d -m 0777 /pi

# CHANGE 3: no ENTRYPOINT ["pi"]. `ws up pi-harness -- bash` to look around a
# container that has just misbehaved is worth more than saving five characters,
# and up.sh passes `pi` explicitly.
WORKDIR /work
