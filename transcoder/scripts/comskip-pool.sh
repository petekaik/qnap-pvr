#!/bin/sh
# Comskip worker pool. Reads the comskip queue and dispatches up to
# COMSKIP_WORKERS jobs in parallel. Each job processes one recording.

QUEUE="/transcoder/queue/comskip-queue.jsonl"
LOG="/transcoder/queue/comskip.log"
LOCK="/tmp/comskip-pool.lock"
WORKERS="${COMSKIP_WORKERS:-1}"

mkdir -p "$(dirname "$LOG")" "$(dirname "$QUEUE")"
: >> "$QUEUE"

exec 9>"$LOCK"
if ! flock -n 9; then
    echo "$(date -Iseconds) comskip-pool already running" >> "$LOG"
    exit 0
fi

echo "$(date -Iseconds) comskip-pool started (workers=$WORKERS)" >> "$LOG"

# Export for xargs subshells.
export LOG QUEUE

# Use tail -F to follow new lines, then dispatch to N parallel workers.
# xargs -P runs up to N instances concurrently.  Each instance processes
# one line and exits, so the queue file is consumed as fast as capacity allows.
tail -F -n 0 "$QUEUE" | xargs -0 -P "$WORKERS" -I {} /bin/sh /etc/transcoder/comskip-single.sh '{}'

echo "$(date -Iseconds) comskip-pool stopped" >> "$LOG"
