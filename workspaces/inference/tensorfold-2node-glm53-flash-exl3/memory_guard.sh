#!/usr/bin/env bash
# Source from up/down. No exports: start.sh receives its original environment.
GUARD_PY=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/memory_guard.py
GUARD_CONTAINER=${CONTAINER_NAME:-glm53-flash-tf}
GUARD_SESSION=$$
# Tests use a real loopback sshd, never a replacement ssh binary.
GUARD_SSH_ARGS=${GUARD_SSH_ARGS:-}

guard_run() {  # $1 = ssh target, empty for this node; $2 = POSIX snippet
    if [[ -z $1 ]]; then
        sh -c "$2"
        return
    fi
    # shellcheck disable=SC2086
    timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=5 $GUARD_SSH_ARGS "$1" "$2"
}

guard_paths() {
    # shellcheck disable=SC2016
    printf 'dir="$HOME/.cache/tensorfold-glm53"; run="$dir/guard-%s-%s"\n' \
        "$GUARD_CONTAINER" "$GUARD_SESSION"
}

guard_stop_snippet() {
    # Brackets prevent matching the shell carrying this command. HOME scopes rank 1.
    # shellcheck disable=SC2016
    printf 'pattern=$(printf "%%s" "$HOME/.cache/tensorfold-glm53/" | sed "s/[.]/\\\\./g"); '
    printf "pkill -f \"\${pattern}[m]emory_guard.py --container %s( |\$)\" || true\n" \
        "${GUARD_CONTAINER//./\\.}"
}

guard_start_snippet() {
    guard_paths
    cat <<SH
set -eu
mkdir -p "\$dir/logs"
cat > "\$dir/memory_guard.py"
mkdir -p "\$run"
: > "\$run/startup"
setsid python3 "\$dir/memory_guard.py" --container '$GUARD_CONTAINER' \
    --startup-file "\$run/startup" --ready-file "\$run/ready" --status-file "\$run/status" \
    --log "\$dir/logs/memguard.log" </dev/null >/dev/null 2>>"\$dir/logs/memguard.log" &
pid=\$!
i=0
while [ "\$i" -lt 60 ]; do
    if [ -s "\$run/ready" ] && kill -0 "\$pid" 2>/dev/null; then
        grep -F "supervisor started: container $GUARD_CONTAINER, pid=\$pid" "\$dir/logs/memguard.log" && exit 0
    fi
    kill -0 "\$pid" 2>/dev/null || exit 1
    sleep 0.1
    i=\$((i + 1))
done
kill "\$pid" 2>/dev/null || true
exit 1
SH
}

guard_start() {
    local rc=0
    [[ $GUARD_CONTAINER =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || return 1
    guard_run "$1" "$(guard_stop_snippet)" </dev/null || rc=$?
    (( rc == 0 )) || { echo "memory guard on $2: UNGUARDED, unreachable" >&2; return 1; }
    guard_run "$1" "$(guard_start_snippet)" <"$GUARD_PY" || rc=$?
    (( rc == 0 )) || { echo "memory guard on $2: UNGUARDED, startup handshake failed ($rc)" >&2; return 1; }
    echo "memory guard on $2: supervisor ready; waiting for or watching the named container"
}

guard_finish_snippet() {
    guard_paths
    cat <<SH
set -eu
rm -f "\$run/startup"
i=0
while [ "\$i" -lt 40 ]; do
    id=\$(timeout 3 docker container inspect -f '{{.Id}} {{.State.Running}}' '$GUARD_CONTAINER' 2>"\$run/inspect.err") || {
        grep -qi 'no such container' "\$run/inspect.err" && { echo 'no container; supervision finished'; exit 0; }
        exit 1
    }
    case "\$id" in *' false') echo 'container stopped; supervision finished'; exit 0 ;; esac
    id=\${id% true}
    if [ -s "\$run/ready" ] && kill -0 "\$(cat "\$run/ready")" 2>/dev/null && \
       [ "\$(cat "\$run/status" 2>/dev/null)" = "guarding \$id" ]; then
        echo "guarding container id=\$id"
        exit 0
    fi
    sleep 0.1
    i=\$((i + 1))
done
exit 1
SH
}

guard_finish() {
    guard_run "$1" "$(guard_finish_snippet)" </dev/null \
        || { echo "memory guard on $2: UNGUARDED or state unconfirmed" >&2; return 1; }
}

memory_guard_startup() {
    local rc=0
    guard_start "" "rank 0" || rc=1
    guard_start "$WORKER" "rank 1 ($WORKER)" || rc=1
    return "$rc"
}

memory_guard_finish() {
    local rc=0
    guard_finish "" "rank 0" || rc=1
    guard_finish "$WORKER" "rank 1 ($WORKER)" || rc=1
    return "$rc"
}

guard_stop() {
    guard_run "$1" "$(guard_stop_snippet)" </dev/null \
        && echo "memory guard on $2: stopped" \
        || echo "memory guard on $2: unreachable; guard state unconfirmed" >&2
}

memory_guard_down() {
    guard_stop "" "rank 0"
    [[ -n ${WORKER:-} ]] && guard_stop "$WORKER" "rank 1 ($WORKER)"
    return 0
}

memory_guard_interrupted() {
    trap - INT TERM
    echo "startup interrupted; signalling start.sh and checking guard state" >&2
    [[ -z ${start_pid:-} ]] || { kill -TERM "$start_pid" 2>/dev/null || true; wait "$start_pid" || true; }
    memory_guard_finish || true
    exit "$1"
}

memory_guard_launch() {
    local status=0 guards=0 start_pid=
    if [[ ${DRY_RUN:-0} == 1 ]]; then
        ./start.sh "$@"
        return
    fi
    trap 'memory_guard_interrupted 130' INT
    trap 'memory_guard_interrupted 143' TERM
    memory_guard_startup || { memory_guard_finish || true; trap - INT TERM; return 1; }
    ./start.sh "$@" <&0 &
    start_pid=$!
    wait "$start_pid" || status=$?
    memory_guard_finish || guards=$?
    trap - INT TERM
    return $(( status ? status : guards ))
}
