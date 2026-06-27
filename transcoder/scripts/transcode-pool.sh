#!/bin/sh
# Nightly transcode worker pool.
# Reads the transcode queue and dispatches up to TRANSCODE_WORKERS jobs in
# parallel. Failed entries are kept in the queue for retry.

QUEUE="/transcoder/queue/transcode-queue.jsonl"
DONE="/transcoder/queue/transcode-queue.done"
LOG="/var/log/transcode-nightly.log"
LOCK="/tmp/transcode-pool.lock"
WORKERS="${TRANSCODE_WORKERS:-1}"

mkdir -p "$(dirname "$LOG")"
: >> "$DONE"

exec 9>"$LOCK"
if ! flock -n 9; then
    echo "$(date -Iseconds) transcode-pool already running" >> "$LOG"
    exit 0
fi

echo "$(date -Iseconds) transcode-pool started (workers=$WORKERS)" >> "$LOG"

if [ ! -f "$QUEUE" ] || [ ! -s "$QUEUE" ]; then
    echo "$(date -Iseconds) queue empty, nothing to do" >> "$LOG"
    echo "$(date -Iseconds) transcode-pool finished" >> "$LOG"
    exit 0
fi

# Atomically drain the queue into a temp file.
cp "$QUEUE" "$QUEUE.tmp"
> "$QUEUE"

export LOG QUEUE DONE

# Process the temp queue with N workers.  Failed entries are written back
# to the original queue via the helper script.
while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    printf '%s\0' "$line"
done < "$QUEUE.tmp" | xargs -0 -P "$WORKERS" -I {} /bin/sh /etc/transcoder/transcode-single.sh '{}'

rm -f "$QUEUE.tmp"

echo "$(date -Iseconds) transcode-pool finished" >> "$LOG"
