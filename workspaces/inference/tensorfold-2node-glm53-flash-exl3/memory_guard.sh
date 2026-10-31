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
    local quoted=${2//\'/\'\\\'\'}
    # The login shell only parses this quoted exec; sh interprets the snippet.
    # shellcheck disable=SC2086
    timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=5 $GUARD_SSH_ARGS "$1" "exec sh -c '$quoted'"
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

guard_check_snippet() {
    cat <<SH
snapshot() {
    value=\$(timeout 3 docker container inspect -f '{{.Id}} {{.State.Running}}' '$GUARD_CONTAINER' 2>"\$run/inspect.err") || {
        grep -qi 'no such container' "\$run/inspect.err" && { echo missing; return 0; }
        return 1
    }
    case "\$value" in *' false') echo stopped ;; *) echo "\${value% true}" ;; esac
}
acknowledged() {
    first=\$(snapshot) || return 1
    case "\$first" in missing|stopped)
        [ "\$(snapshot)" = "\$first" ] || return 1
        echo 'no container running'; return 0 ;;
    esac
    [ -s "\$run/ready" ] && kill -0 "\$(cat "\$run/ready")" 2>/dev/null || return 1
    [ "\$(cat "\$run/status" 2>/dev/null)" = "guarding \$first" ] || return 1
    [ "\$(snapshot)" = "\$first" ] || return 1
    echo "guarding container id=\$first"
}
SH
}

guard_previous_snippet() {
    cat <<SH
: > "\$run/previous"
for ready in "\$dir"/guard-'$GUARD_CONTAINER'-*/ready; do
    [ "\$ready" != "\$run/ready" ] && [ -s "\$ready" ] || continue
    cat "\$ready" >> "\$run/previous"
    printf '\n' >> "\$run/previous"
done
SH
}

guard_retire_snippet() {
    cat <<SH
while read -r old; do
    case "\$old" in ''|*[!0-9]*) continue ;; esac
    [ "\$old" != "\$pid" ] && [ -r "/proc/\$old/cmdline" ] || continue
    if tr '\000' ' ' < "/proc/\$old/cmdline" | grep -F -- "\$dir/memory_guard.py --container $GUARD_CONTAINER " >/dev/null; then
        kill "\$old" 2>/dev/null || true
    fi
done < "\$run/previous"
SH
}

guard_start_snippet() {
    guard_paths
    # shellcheck disable=SC2016
    printf 'set -eu\nmkdir -p "$dir/logs" "$run"\ncat > "$dir/memory_guard.py"\n'
    guard_previous_snippet
    guard_check_snippet
    cat <<SH
: > "\$run/startup"
setsid python3 "\$dir/memory_guard.py" --container '$GUARD_CONTAINER' \
    --startup-file "\$run/startup" --ready-file "\$run/ready" --status-file "\$run/status" \
    --log "\$dir/logs/memguard.log" </dev/null >/dev/null 2>>"\$dir/logs/memguard.log" &
pid=\$!
deadline=\$((\$(date +%s) + 8))
while [ "\$(date +%s)" -le "\$deadline" ]; do
    kill -0 "\$pid" 2>/dev/null || exit 1
    if [ -s "\$run/ready" ] && \
       grep -qF "supervisor started: container $GUARD_CONTAINER, pid=\$pid" "\$dir/logs/memguard.log" && \
       acknowledged; then
SH
    guard_retire_snippet
    cat <<SH
        exit 0
    fi
    sleep 0.1
done
kill "\$pid" 2>/dev/null || true
exit 1
SH
}

guard_start() {
    local rc=0
    [[ $GUARD_CONTAINER =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || return 1
    guard_run "$1" "$(guard_start_snippet)" <"$GUARD_PY" || rc=$?
    (( rc == 0 )) || { echo "memory guard on $2: UNGUARDED successor, startup handshake failed; previous guards not retired ($rc)" >&2; return 1; }
    echo "memory guard on $2: supervisor ready; current container acknowledged"
}

guard_finish_snippet() {
    guard_paths
    printf 'set -eu\n'
    guard_check_snippet
    cat <<SH
deadline=\$((\$(date +%s) + 8))
while [ "\$(date +%s)" -le "\$deadline" ]; do
    if acknowledged; then
        rm -f "\$run/startup"
        exit 0
    fi
    sleep 0.1
done
echo 'handoff unconfirmed; discovery retained' >&2
exit 1
SH
}

guard_finish() {
    guard_run "$1" "$(guard_finish_snippet)" </dev/null \
        || { echo "memory guard on $2: UNGUARDED or state unconfirmed; discovery retained" >&2; return 1; }
}

guard_report() {
    guard_run "$1" "$(guard_paths; guard_check_snippet; printf 'acknowledged\n')" </dev/null \
        || echo "memory guard on $2: state unconfirmed; discovery retained" >&2
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

memory_guard_quiesce() {
    [[ -n ${start_pid:-} ]] || return 0
    kill -TERM -- "-$start_pid" 2>/dev/null || true
    local i
    for ((i=0; i<20; i++)); do
        kill -0 -- "-$start_pid" 2>/dev/null || break
        sleep 0.1
    done
    kill -KILL -- "-$start_pid" 2>/dev/null || true
    if ! kill -0 "$start_pid" 2>/dev/null; then
        wait "$start_pid" 2>/dev/null || true
    fi
}

memory_guard_interrupted() {
    trap - INT TERM
    memory_guard_quiesce
    echo "startup interrupted; local launch-group termination requested; remote/daemon cancellation unconfirmed; discovery retained" >&2
    guard_report "" "rank 0"
    guard_report "$WORKER" "rank 1 ($WORKER)"
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
    setsid ./start.sh "$@" <&0 &
    start_pid=$!
    wait "$start_pid" || status=$?
    memory_guard_finish || guards=$?
    trap - INT TERM
    return $(( status ? status : guards ))
}
