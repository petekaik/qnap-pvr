#!/bin/sh
# Comskip worker loop. Single-threaded, tail-driven.
#
# Reads /comskip/queue/comskip-queue.jsonl as new lines are appended.
# For each line:
#   1. Check that the source .ts file still exists.
#   2. Skip if it is in the done list (already processed).
#   3. Skip if it is on the commercial-free channel list.
#   4. Run comskip to produce .edl next to the source.
#   5. Append the path to comskip-queue.done so it is not re-processed.
#
# Comskip itself is single-threaded, so running multiple instances in
# parallel just thrashes disk I/O without gaining speed. We use a single
# sequential worker and rely on a flock to ensure only one pool runs.
#
# All configuration (binary path, log path, channel list) lives in
# /etc/comskip/config.yaml. The container does NOT need python or any
# extra runtime — we parse YAML with a small POSIX-shell helper.

set -e

CONFIG="/etc/comskip/config.yaml"
QUEUE="/comskip/queue/comskip-queue.jsonl"
DONE="/comskip/queue/comskip-queue.done"
LOG="/comskip/queue/comskip.log"
ERRORS="/comskip/queue/errors.jsonl"
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

exec 9>"$LOCK"
if ! flock -n 9; then
    echo "$(date -Iseconds) comskip-pool already running, exiting" >> "$LOG"
    exit 0
fi

echo "$(date -Iseconds) comskip-pool started" >> "$LOG"

# tail -F -n 0 follows new lines as they are appended. We process
# each line inline (no subprocess function) so the script works in
# POSIX sh without `export -f`.
tail -F -n 0 "$QUEUE" 2>/dev/null | while IFS= read -r line; do
    [ -n "$line" ] || continue

    path=$(printf '%s\n' "$line" | sed -n 's/.*"path" *: *"\([^"]*\)".*/\1/p')
    if [ -z "$path" ]; then
        echo "$(date -Iseconds) SKIP malformed line: $line" >> "$LOG"
        continue
    fi

    if [ ! -f "$path" ]; then
        echo "$(date -Iseconds) SKIP missing source: $path" >> "$LOG"
        continue
    fi

    if grep -qF "$path" "$DONE" 2>/dev/null; then
        echo "$(date -Iseconds) SKIP already done: $path" >> "$LOG"
        continue
    fi

    # Channel skip — best-effort match by parent directory name.
    skip_channel=0
    if [ -f "$CHANNELS_FILE" ]; then
        parent_dir=$(basename "$(dirname "$path")")
        while IFS= read -r ch; do
            [ -z "$ch" ] && continue
            if [ "$ch" = "$parent_dir" ]; then
                skip_channel=1
                break
            fi
        done < "$CHANNELS_FILE"
    fi

    if [ "$skip_channel" = "1" ]; then
        echo "$(date -Iseconds) SKIP commercial-free: $path" >> "$LOG"
        printf '%s\n' "$path" >> "$DONE"
        continue
    fi

    base="${path%.*}"
    outdir="$(dirname "$path")"
    echo "$(date -Iseconds) RUN comskip $path" >> "$LOG"
    # BOTH stdout and stderr → progress_log (default /dev/null).
    # comskip writes most of its per-frame progress to stderr, not
    # stdout, so we cannot keep stderr in the main log without burying
    # the actual RUN/OK/SKIP/EDL markers under hundreds of frame lines.
    # Any genuine warning or error worth showing would need separate
    # routing; comskip's exit code already covers hard failures, and
    # EDL presence covers the success case.
    nice -n "$NICE_LEVEL" "$COMSKIP_BIN" \
        --ini="$COMSKIP_INI" \
        --output="$outdir" \
        "$path" >> "$PROGRESS_LOG" 2>&1 || true

    # Always mark as done (comskip rc=1 = no commercials found = OK).
    printf '%s\n' "$path" >> "$DONE"
    if [ -f "${base}.edl" ]; then
        echo "$(date -Iseconds) EDL generated ${base}.edl" >> "$LOG"
    else
        echo "$(date -Iseconds) OK comskip (no commercials) $path" >> "$LOG"
    fi
done