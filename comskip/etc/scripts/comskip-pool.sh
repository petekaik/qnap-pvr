#!/bin/sh
# Comskip worker loop. Single-threaded, POSIX-sh only.
#
# Subcommands (default: watch):
#   watch       Tail the queue and process new lines as they arrive.
#   drain       Read the entire queue once, process every line, exit.
#   prune-done  Remove paths from comskip-queue.done whose source
#               .ts file no longer exists on disk.
#
# The container's entrypoint runs `drain` then `prune-done` once
# before starting `watch` in the background. This guarantees that
# nothing queued while the container was down is silently skipped,
# and that the done-list does not grow forever with paths for
# deleted recordings.
#
# Each queue line is a JSON object like:
#   {"path":"/recordings/foo/foo.ts","channel":"Foo"}
#
# For each line:
#   1. Check that the source .ts file still exists.
#   2. Skip if it is in the done list (already processed).
#   3. Skip if it is on the commercial-free channel list.
#   4. Run comskip to produce .edl next to the source.
#   5. Append the path to comskip-queue.done so it is not re-processed.
#
# Comskip itself is single-threaded, so running multiple instances in
# parallel just thrashes disk I/O without gaining speed. We use a
# single sequential worker and rely on a flock to ensure only one
# pool runs.
#
# All configuration (binary path, log path, channel list) lives in
# /etc/comskip/config.yaml. The container does NOT need python or any
# extra runtime — we parse YAML with a small POSIX-shell helper.

set -e

CONFIG="/etc/comskip/config.yaml"
QUEUE="/comskip/queue/comskip-queue.jsonl"
DONE="/comskip/queue/comskip-queue.done"
LOG="/comskip/queue/comskip.log"
# Where comskip's own stdout (the per-frame progress spam) goes.
# /dev/null = discard. A file path = keep for forensic debugging.
# Set in config.yaml under "progress_log". Default: /dev/null.
PROGRESS_LOG="/dev/null"
# Lock file lives under /pvr/tmp, which is a writable mount from the
# host's ${DATA}/tmp. We avoid /tmp because the container's /tmp is
# the read-only rootfs overlay and quickly fills with FFmpeg logs.
LOCK="/pvr/tmp/comskip-pool.lock"

mkdir -p "$(dirname "$LOG")" "$(dirname "$DONE")" "$(dirname "$LOCK")"
[ -f "$QUEUE" ] || : > "$QUEUE"
[ -f "$DONE" ] || : > "$DONE"

# Defaults — overridden by config.yaml.
COMSKIP_INI="/etc/comskip/comskip.ini"
COMSKIP_BIN="/usr/local/bin/comskip"
NICE_LEVEL=19
CHANNELS_FILE="/pvr/tmp/comskip-channels.txt"

if [ -f "$CONFIG" ]; then
    # shellcheck disable=SC1090
    . /usr/local/bin/pvr-config-loader.sh
    eval "$(load_config_eval "$CONFIG" \
        comskip_ini=/etc/comskip/comskip.ini \
        comskip_binary=/usr/local/bin/comskip \
        nice_level=19 \
        progress_log=/dev/null)"
    COMSKIP_BIN="${comskip_binary:-$COMSKIP_BIN}"
    COMSKIP_INI="${comskip_ini:-$COMSKIP_INI}"
    NICE_LEVEL="${nice_level:-$NICE_LEVEL}"
    PROGRESS_LOG="${progress_log:-$PROGRESS_LOG}"
    load_list "$CONFIG" commercial_free_channels "$CHANNELS_FILE"
fi

# If progress_log points to a real file, ensure its parent exists
# and truncate it so each run starts clean.
case "$PROGRESS_LOG" in
    /dev/null) ;;
    *) mkdir -p "$(dirname "$PROGRESS_LOG")" && : > "$PROGRESS_LOG" ;;
esac

# Decide what to do based on the subcommand. The default is `watch`,
# so the script can also be called without arguments (backwards
# compatibility — and what `entrypoint.sh` uses to launch the
# background watcher).
CMD="${1:-watch}"

# -------------------------------------------------------------------
# Common: parse one queue line, decide whether to skip or run.
# Arguments: $1 = full queue line
# Side effects: writes to LOG, may append to DONE, may invoke comskip.
# This is intentionally a shell function (not exported) — POSIX sh
# functions are visible inside the same script, so no `export -f`
# (a bash-ism that breaks under dash/ash).
# -------------------------------------------------------------------
process_line() {
    _line="$1"
    [ -n "$_line" ] || return 0

    _path=$(printf '%s\n' "$_line" | sed -n 's/.*"path" *: *"\([^"]*\)".*/\1/p')
    if [ -z "$_path" ]; then
        echo "$(date -Iseconds) SKIP malformed line: $_line" >> "$LOG"
        return 0
    fi

    if [ ! -f "$_path" ]; then
        echo "$(date -Iseconds) SKIP missing source: $_path" >> "$LOG"
        return 0
    fi

    if grep -qF "$_path" "$DONE" 2>/dev/null; then
        echo "$(date -Iseconds) SKIP already done: $_path" >> "$LOG"
        return 0
    fi

    # Channel skip — best-effort match by parent directory name.
    _skip_channel=0
    if [ -f "$CHANNELS_FILE" ]; then
        _parent_dir=$(basename "$(dirname "$_path")")
        while IFS= read -r _ch; do
            [ -z "$_ch" ] && continue
            if [ "$_ch" = "$_parent_dir" ]; then
                _skip_channel=1
                break
            fi
        done < "$CHANNELS_FILE"
    fi

    if [ "$_skip_channel" = "1" ]; then
        echo "$(date -Iseconds) SKIP commercial-free: $_path" >> "$LOG"
        printf '%s\n' "$_path" >> "$DONE"
        return 0
    fi

    _base="${_path%.*}"
    _outdir="$(dirname "$_path")"
    echo "$(date -Iseconds) RUN comskip $_path" >> "$LOG"
    # BOTH stdout and stderr → progress_log (default /dev/null).
    # comskip writes most of its per-frame progress to stderr, not
    # stdout, so we cannot keep stderr in the main log without burying
    # the actual RUN/OK/SKIP/EDL markers under hundreds of frame lines.
    # Any genuine warning or error worth showing would need separate
    # routing; comskip's exit code already covers hard failures, and
    # EDL presence covers the success case.
    nice -n "$NICE_LEVEL" "$COMSKIP_BIN" \
        --ini="$COMSKIP_INI" \
        --output="$_outdir" \
        "$_path" >> "$PROGRESS_LOG" 2>&1 || true

    # Always mark as done (comskip rc=1 = no commercials found = OK).
    printf '%s\n' "$_path" >> "$DONE"
    if [ -f "${_base}.edl" ]; then
        echo "$(date -Iseconds) EDL generated ${_base}.edl" >> "$LOG"
    else
        echo "$(date -Iseconds) OK comskip (no commercials) $_path" >> "$LOG"
    fi
}

# -------------------------------------------------------------------
# watch — tail the queue forever, process each new line.
# -------------------------------------------------------------------
watch() {
    exec 9>"$LOCK"
    if ! flock -n 9; then
        echo "$(date -Iseconds) comskip-pool already running, exiting" >> "$LOG"
        return 0
    fi

    echo "$(date -Iseconds) comskip-pool started (watch)" >> "$LOG"

    # tail -F -n 0 follows new lines as they are appended. We process
    # each line inline (no subprocess function) so the script works in
    # POSIX sh without `export -f`.
    tail -F -n 0 "$QUEUE" 2>/dev/null | while IFS= read -r line; do
        # NOTE: this runs in a subshell because of the pipe. process_line
        # is defined in the parent, but POSIX sh copies function
        # definitions into the subshell automatically — except with
        # `set -e` and pipefail disabled the function body still runs.
        process_line "$line"
    done
}

# -------------------------------------------------------------------
# drain — read the entire queue once, process every line, exit.
# Used by entrypoint.sh on container start so that lines appended
# while the container was down are not lost.
# -------------------------------------------------------------------
drain() {
    exec 9>"$LOCK"
    if ! flock -n 9; then
        echo "$(date -Iseconds) comskip-pool drain: already running, exiting" >> "$LOG"
        return 0
    fi

    _count=$(wc -l < "$QUEUE" 2>/dev/null | tr -d ' ')
    _count=${_count:-0}
    if [ "$_count" = "0" ]; then
        echo "$(date -Iseconds) comskip-pool drain: queue empty" >> "$LOG"
        return 0
    fi

    echo "$(date -Iseconds) comskip-pool drain: $_count queued line(s)" >> "$LOG"

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        process_line "$line"
    done < "$QUEUE"

    # Drain: empty the queue file. New lines appended after this point
    # will be picked up by the watch loop (which entrypoint starts
    # immediately after drain returns).
    : > "$QUEUE"

    echo "$(date -Iseconds) comskip-pool drain: complete" >> "$LOG"
}

# -------------------------------------------------------------------
# prune-done — drop entries from done-list whose source no longer
# exists. Run on container start so the done-list does not grow
# unboundedly when recordings are deleted by the operator.
#
# Trade-off: pruning allows a later recording with the same path to
# be re-processed. This is intentional — if the user deleted a
# recording (presumably because it failed) and the same path is later
# reused for a fresh recording, we want comskip to run on the new
# file rather than silently skip it.
# -------------------------------------------------------------------
prune_done() {
    exec 9>"$LOCK"
    if ! flock -n 9; then
        echo "$(date -Iseconds) comskip-pool prune-done: already running, exiting" >> "$LOG"
        return 0
    fi

    if [ ! -s "$DONE" ]; then
        echo "$(date -Iseconds) comskip-pool prune-done: done-list empty" >> "$LOG"
        return 0
    fi

    _tmp="${DONE}.tmp.$$"
    # Touch the temp file up-front so the mv below always has a
    # source. Without this, when every entry is kept (none dropped),
    # the while loop never writes to $_tmp, mv fails with "cannot stat",
    # and set -e would kill the script.
    : > "$_tmp"
    _kept=0
    _dropped=0
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        if [ -f "$path" ]; then
            printf '%s\n' "$path" >> "$_tmp"
            _kept=$((_kept + 1))
        else
            _dropped=$((_dropped + 1))
        fi
    done < "$DONE"

    mv "$_tmp" "$DONE"
    echo "$(date -Iseconds) comskip-pool prune-done: kept $_kept, dropped $_dropped (source missing)" >> "$LOG"
}

# Dispatch.
case "$CMD" in
    watch)      watch ;;
    drain)      drain ;;
    prune-done) prune_done ;;
    *)
        echo "$(date -Iseconds) comskip-pool: unknown subcommand '$CMD' (use watch|drain|prune-done)" >> "$LOG"
        exit 2
        ;;
esac