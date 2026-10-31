#!/usr/bin/env bash
# Start and stop memory_guard.py on both ranks. Sourced by up.sh and down.sh.
#
# Only unexported names here: start.sh's environment must not change.
#
# The worker has no checkout of this repo, so the script travels over ssh's
# stdin. The two snippets are POSIX sh and run by the node's login shell.
# They stay separate: a remote shell whose command line held both the pkill
# pattern and the guard's path would match, and kill, itself.

GUARD_PY=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/memory_guard.py
GUARD_CONTAINER=${CONTAINER_NAME:-glm53-flash-tf}
GUARD_NO_CONTAINER=3
# Set by tests/check_memory_guard.py to reach a loopback sshd. Word split on purpose.
GUARD_SSH_ARGS=${GUARD_SSH_ARGS:-}

# Under the kit's cache: its LOG_DIR default, and the same path on both nodes.
guard_start_snippet() {
    local name; name=$(printf '%q' "$GUARD_CONTAINER")
    cat <<SH
set -eu
dir=\$HOME/.cache/tensorfold-glm53
mkdir -p "\$dir/logs"
cat > "\$dir/memory_guard.py"
[ "\$(docker container inspect -f '{{.State.Running}}' $name 2>/dev/null)" = true ] || exit $GUARD_NO_CONTAINER
setsid python3 "\$dir/memory_guard.py" --container $name --log "\$dir/logs/memguard.log" \
    </dev/null >/dev/null 2>>"\$dir/logs/memguard.log" &
pid=\$!
sleep 2
kill -0 "\$pid"
SH
}

# The bracket keeps this pattern from matching the shell that carries it.
guard_stop_snippet() {
    printf "pkill -f '[m]emory_guard.py --container %s( |\$)' || true\n" "$GUARD_CONTAINER"
}

guard_run() {  # $1 = ssh target, empty for this node; $2 = snippet
    if [[ -z $1 ]]; then
        sh -c "$2"
        return
    fi
    # shellcheck disable=SC2086
    ssh -o BatchMode=yes -o ConnectTimeout=5 $GUARD_SSH_ARGS "$1" "$2"
}

guard_start() {  # $1 = ssh target, empty for this node; $2 = label
    local rc=0
    guard_run "$1" "$(guard_stop_snippet)" </dev/null || rc=$?
    (( rc == 0 )) || { echo "memory guard on $2: UNGUARDED, unreachable (ssh $rc)" >&2; return 1; }
    guard_run "$1" "$(guard_start_snippet)" <"$GUARD_PY" || rc=$?
    case $rc in
        0) echo "memory guard on $2: running" ;;
        "$GUARD_NO_CONTAINER") echo "memory guard on $2: no running $GUARD_CONTAINER, nothing to guard" ;;
        *) echo "memory guard on $2: UNGUARDED, it did not start (exit $rc)" >&2; return 1 ;;
    esac
}

guard_stop() {  # $1 = ssh target, empty for this node; $2 = label
    guard_run "$1" "$(guard_stop_snippet)" </dev/null \
        && echo "memory guard on $2: stopped" \
        || echo "memory guard on $2: unreachable, it exits by itself with the container" >&2
}

memory_guard_up() {
    local rc=0
    guard_start "" "rank 0" || rc=1
    guard_start "$WORKER" "rank 1 ($WORKER)" || rc=1
    (( rc == 0 )) || echo "a rank is running without its memory guard: fix that, then run ws up again" >&2
    return "$rc"
}

memory_guard_down() {
    guard_stop "" "rank 0"
    [[ -n ${WORKER:-} ]] && guard_stop "$WORKER" "rank 1 ($WORKER)"
    return 0
}
