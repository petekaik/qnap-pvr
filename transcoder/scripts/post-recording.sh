#!/bin/sh
# TVHeadend post-recording hook.
# Runs inside the tvheadend container when a recording finishes.
# Enqueues the recording for the comskip worker (immediate commercial
# detection) and the nightly transcode queue.
#
# YLE channels are commercial-free; the comskip worker skips them
# automatically, but we still enqueue every recording there for consistent
# logging.

RECORDING="$1"
QUEUE="/transcoder/queue/transcode-queue.jsonl"
COMSKIP_QUEUE="/transcoder/queue/comskip-queue.jsonl"
LOG="/transcoder/queue/post-recording.log"

TS=$(date -Iseconds)
exec >> "$LOG" 2>&1

echo "[$TS] [tvheadend postprocessor] invoked with: $RECORDING"

if [ -z "$RECORDING" ] || [ ! -f "$RECORDING" ]; then
    echo "[$TS] [tvheadend postprocessor] ERROR: no recording file provided or file missing"
    exit 1
fi

# Enqueue for immediate comskip processing in the transcoder container.
printf '{"path":"%s","added":"%s"}\n' "$RECORDING" "$TS" >> "$COMSKIP_QUEUE"
echo "[$TS] [tvheadend postprocessor] enqueued $RECORDING for comskip"

# Enqueue for nightly transcoding.
printf '{"path":"%s","status":"pending","added":"%s"}\n' "$RECORDING" "$TS" >> "$QUEUE"
echo "[$TS] [tvheadend postprocessor] queued $RECORDING for transcode"
