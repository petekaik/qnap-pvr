#!/bin/sh
# TVHeadend post-recording hook.
# Runs inside the tvheadend container when a recording finishes.
# Enqueues the recording for the comskip worker (immediate commercial
# detection) and the nightly transcode queue.
#
# TVHeadend passes an incomplete path when the filename contains spaces or
# dashes, so we resolve the actual .ts file from the provided prefix.
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

resolve_ts() {
    local prefix="$1"

    # If the argument is already a valid .ts file, use it as-is.
    if [ -f "$prefix" ]; then
        printf '%s\n' "$prefix"
        return 0
    fi

    # If the prefix points to a directory, pick the largest .ts file there.
    if [ -d "$prefix" ]; then
        local found
        found=$(find "$prefix" -maxdepth 1 -type f -name '*.ts' -printf '%s %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2-)
        if [ -n "$found" ] && [ -f "$found" ]; then
            printf '%s\n' "$found"
            return 0
        fi
    fi

    # Treat the prefix as a truncated path. Search the parent directory for
    # either a matching directory or a .ts file whose name starts with the
    # truncated basename.
    local dir
    dir=$(dirname "$prefix" 2>/dev/null)
    local base
    base=$(basename "$prefix" 2>/dev/null)

    if [ -d "$dir" ]; then
        # First: directory whose name starts with the truncated basename.
        local d
        d=$(find "$dir" -maxdepth 1 -type d -name "$base*" 2>/dev/null | head -n1)
        if [ -n "$d" ] && [ -d "$d" ]; then
            local found
            found=$(find "$d" -maxdepth 1 -type f -name '*.ts' -printf '%s %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2-)
            if [ -n "$found" ] && [ -f "$found" ]; then
                printf '%s\n' "$found"
                return 0
            fi
        fi

        # Second: .ts file whose name starts with the truncated basename.
        local found
        found=$(find "$dir" -maxdepth 1 -type f -name "$base*.ts" -printf '%s %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2-)
        if [ -n "$found" ] && [ -f "$found" ]; then
            printf '%s\n' "$found"
            return 0
        fi
    fi

    return 1
}

RESOLVED=$(resolve_ts "$RECORDING") || {
    echo "[$TS] [tvheadend postprocessor] ERROR: could not resolve .ts file from prefix: $RECORDING"
    exit 1
}

if [ ! -f "$RESOLVED" ]; then
    echo "[$TS] [tvheadend postprocessor] ERROR: resolved file does not exist: $RESOLVED"
    exit 1
fi

echo "[$TS] [tvheadend postprocessor] resolved to: $RESOLVED"

# Enqueue for immediate comskip processing in the transcoder container.
printf '{"path":"%s","added":"%s"}\n' "$RESOLVED" "$TS" >> "$COMSKIP_QUEUE"
echo "[$TS] [tvheadend postprocessor] enqueued $RESOLVED for comskip"

# Enqueue for nightly transcoding.
printf '{"path":"%s","status":"pending","added":"%s"}\n' "$RESOLVED" "$TS" >> "$QUEUE"
echo "[$TS] [tvheadend postprocessor] queued $RESOLVED for transcode"
