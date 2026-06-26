#!/bin/sh
# Nightly transcode queue processor.
# Reads pending .ts recordings from the shared queue and transcodes them
# to H.264/AAC MP4 files under /media/transcoded, preserving the source
# directory structure. Keeps the original .ts files intact.

QUEUE="/transcoder/queue/transcode-queue.jsonl"
DONE="/transcoder/queue/transcode-queue.done"
LOG="/var/log/transcode-nightly.log"
LOCK="/tmp/transcode-nightly.lock"

# TVH writes the recording path as seen inside its own container. If TVH runs
# on the host instead, change HOST_PREFIX to match the host mount point.
HOST_PREFIX="/recordings"
CONT_PREFIX="/recordings"

mkdir -p "$(dirname "$LOG")"

# Single-instance lock using flock.
exec 200>"$LOCK"
if ! flock -n 200; then
    echo "$(date -Iseconds) Transcode already running" >> "$LOG"
    exit 0
fi

echo "$(date -Iseconds) Starting transcode run" >> "$LOG"

if [ ! -f "$QUEUE" ]; then
    echo "$(date -Iseconds) Queue missing, nothing to do" >> "$LOG"
    echo "$(date -Iseconds) Transcode run finished" >> "$LOG"
    exit 0
fi

cp "$QUEUE" "$QUEUE.tmp"
> "$QUEUE"

while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue

    # Use Python for correct JSON parsing (unicode, escaped quotes).
    src=$(printf '%s\n' "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin)["path"])') || {
        echo "$(date -Iseconds) SKIP malformed JSON: $line" >> "$LOG"
        continue
    }

    cont_src=$(echo "$src" | sed "s|^${HOST_PREFIX}|${CONT_PREFIX}|")

    if [ ! -f "$cont_src" ]; then
        echo "$(date -Iseconds) SKIP missing $cont_src" >> "$LOG"
        printf '%s\n' "$line" >> "$QUEUE"
        continue
    fi

    # Mirror the source subdirectory under /media/transcoded.
    rel="${cont_src#/recordings/}"
    rel_dir="$(dirname "$rel")"
    mkdir -p "/media/transcoded/$rel_dir"

    base="${cont_src%.*}"
    filename="$(basename "$base").mp4"
    mp4="/media/transcoded/$rel_dir/$filename"

    if grep -qF "$src" "$DONE" 2>/dev/null; then
        echo "$(date -Iseconds) SKIP already done $src" >> "$LOG"
        continue
    fi

    echo "$(date -Iseconds) Transcoding $cont_src -> $mp4" >> "$LOG"

    nice -n 19 ffmpeg -y -hide_banner -loglevel error -threads 1 -i "$cont_src" \
        -vf 'scale=w=1280:h=720:force_original_aspect_ratio=decrease' \
        -c:v libx264 -preset ultrafast -crf 28 -maxrate 4M -bufsize 8M \
        -profile:v main -level 4.1 -pix_fmt yuv420p \
        -c:a aac -b:a 192k -ac 2 \
        -movflags +faststart "$mp4" >> "$LOG" 2>&1

    rc=$?
    if [ $rc -eq 0 ]; then
        echo "$(date -Iseconds) OK $src" >> "$LOG"
        printf '%s\n' "$src" >> "$DONE"
        # Generate Jellyfin-compatible NFO metadata from the TVHeadend DVR log.
        final_mp4=$(python3 /etc/transcoder/generate-nfo.py "$cont_src" "$mp4" 2>&1)
        echo "$final_mp4" >> "$LOG"
    else
        echo "$(date -Iseconds) FAIL $src (rc=$rc)" >> "$LOG"
        printf '%s\n' "$line" >> "$QUEUE"
        rm -f "$mp4"
    fi
done < "$QUEUE.tmp"

rm -f "$QUEUE.tmp"

echo "$(date -Iseconds) Transcode run finished" >> "$LOG"
