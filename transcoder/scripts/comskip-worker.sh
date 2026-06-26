#!/bin/sh
# Comskip worker that processes new .ts recordings immediately after they are
# queued by the TVHeadend post-recording hook.
#
# It tails the comskip queue and runs comskip (nice -n 19) on each pending
# recording unless it originates from a commercial-free channel (YLE).
#
# This runs as a background service inside the transcoder container.

QUEUE="/transcoder/queue/comskip-queue.jsonl"
LOG="/transcoder/queue/comskip.log"
LOCK="/tmp/comskip-worker.lock"

mkdir -p "$(dirname "$LOG")" "$(dirname "$QUEUE")"

# Ensure the queue file exists.
: >> "$QUEUE"

# Single-instance lock.
exec 9>"$LOCK"
if ! flock -n 9; then
    echo "$(date -Iseconds) comskip-worker already running" >> "$LOG"
    exit 0
fi

echo "$(date -Iseconds) comskip-worker started" >> "$LOG"

# Process existing entries, then follow the queue forever.
# Using 'tail -F' gives an immediate wake-up whenever a new line is appended.
tail -F -n 0 "$QUEUE" | while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue

    # Parse JSON with python3 for unicode safety.
    path=$(printf '%s\n' "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin)["path"])') 2>/dev/null || {
        echo "$(date -Iseconds) SKIP malformed comskip JSON: $line" >> "$LOG"
        continue
    }

    [ -f "$path" ] || {
        echo "$(date -Iseconds) SKIP missing $path" >> "$LOG"
        continue
    }

    # Skip commercial-free channels (YLE) using the shared helper.
    channel=$(python3 /etc/transcoder/check-channel.py "$path" 2>/dev/null)
    if [ $? -eq 0 ]; then
        echo "$(date -Iseconds) SKIP comskip for $path (channel '$channel' is commercial-free)" >> "$LOG"
        continue
    fi

    base="${path%.*}"
    outdir="$(dirname "$path")"
    echo "$(date -Iseconds) RUN comskip $path (channel '$channel')" >> "$LOG"
    nice -n 19 /usr/local/bin/comskip --ini=/etc/transcoder/comskip.ini --output="$outdir" "$path" >> "$LOG" 2>&1
    rc=$?
    if [ $rc -eq 0 ]; then
        echo "$(date -Iseconds) OK comskip $path" >> "$LOG"
        if [ -f "${base}.edl" ]; then
            echo "$(date -Iseconds) EDL generated ${base}.edl" >> "$LOG"
        fi
    else
        echo "$(date -Iseconds) FAIL comskip $path (rc=$rc)" >> "$LOG"
    fi
done

echo "$(date -Iseconds) comskip-worker stopped" >> "$LOG"
