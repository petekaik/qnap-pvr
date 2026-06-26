#!/bin/sh
# TVHeadend post-recording hook.
# Runs inside the tvheadend container when a recording finishes.
# Appends the recording path to the shared transcoder queue.

RECORDING="$1"
QUEUE="/transcoder/queue/transcode-queue.jsonl"
LOG="/transcoder/queue/post-recording.log"

TS=$(date -Iseconds)
exec >> "$LOG" 2>&1

echo "[$TS] [tvheadend postprocessor] invoked with: $RECORDING"

if [ -z "$RECORDING" ] || [ ! -f "$RECORDING" ]; then
    echo "[$TS] [tvheadend postprocessor] ERROR: no recording file provided or file missing"
    exit 1
fi

printf '{"path":"%s","status":"pending","added":"%s"}\n' "$RECORDING" "$TS" >> "$QUEUE"
echo "[$TS] [tvheadend postprocessor] queued $RECORDING for transcode"
