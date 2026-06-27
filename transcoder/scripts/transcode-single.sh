#!/bin/sh
# Process a single transcode queue entry.
# Called by transcode-pool.sh with the JSON line as the first argument.

LINE="$1"
QUEUE="/transcoder/queue/transcode-queue.jsonl"
DONE="/transcoder/queue/transcode-queue.done"
LOG="/var/log/transcode-nightly.log"
HOST_PREFIX="/recordings"
CONT_PREFIX="/recordings"

mkdir -p "$(dirname "$LOG")"

src=$(printf '%s\n' "$LINE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["path"])') 2>/dev/null || {
    echo "$(date -Iseconds) SKIP malformed JSON: $LINE" >> "$LOG"
    exit 1
}

cont_src=$(echo "$src" | sed "s|^${HOST_PREFIX}|${CONT_PREFIX}|")

if [ ! -f "$cont_src" ]; then
    echo "$(date -Iseconds) SKIP missing $cont_src" >> "$LOG"
    exit 2
fi

if grep -qF "$src" "$DONE" 2>/dev/null; then
    echo "$(date -Iseconds) SKIP already done $src" >> "$LOG"
    exit 0
fi

rel="${cont_src#/recordings/}"
rel_dir="$(dirname "$rel")"
mkdir -p "/media/transcoded/$rel_dir"

base="${cont_src%.*}"
filename="$(basename "$base").mp4"
mp4="/media/transcoded/$rel_dir/$filename"

src_edl="${base}.edl"
src_txt="${base}.txt"
src_log="${base}.log"

echo "$(date -Iseconds) Transcoding $cont_src -> $mp4" >> "$LOG"

ffmpeg_log="/tmp/ffmpeg-$$.log"
nice -n 19 ffmpeg -y -hide_banner -loglevel error -threads 2 -i "$cont_src" \
    -vf 'scale=w=1280:h=720:force_original_aspect_ratio=decrease' \
    -c:v libx264 -preset ultrafast -crf 30 -pix_fmt yuv420p \
    -c:a aac -b:a 192k -ac 2 \
    -movflags +faststart "$mp4" > "$ffmpeg_log" 2>&1

rc=$?
if [ $rc -eq 0 ]; then
    echo "$(date -Iseconds) OK $src" >> "$LOG"
    flock "$DONE" -c "printf '%s\n' '$src' >> '$DONE'"

    final_mp4=$(python3 /etc/transcoder/generate-nfo.py "$cont_src" "$mp4" 2>&1)
    echo "$final_mp4" >> "$LOG"

    final_base=$(echo "$final_mp4" | tail -n1 | sed 's|\.mp4$||')
    if [ -f "$src_edl" ]; then
        cp "$src_edl" "${final_base}.edl" && echo "$(date -Iseconds) COPIED edl ${src_edl} -> ${final_base}.edl" >> "$LOG"
    fi
    if [ -f "$src_txt" ]; then
        cp "$src_txt" "${final_base}.txt" && echo "$(date -Iseconds) COPIED txt ${src_txt} -> ${final_base}.txt" >> "$LOG"
    fi
    if [ -f "$src_log" ]; then
        cp "$src_log" "${final_base}.log" && echo "$(date -Iseconds) COPIED log ${src_log} -> ${final_base}.log" >> "$LOG"
    fi

    rm -f "$ffmpeg_log"
else
    echo "$(date -Iseconds) FAIL $src (rc=$rc)" >> "$LOG"
    tail -n 30 "$ffmpeg_log" >> "$LOG" 2>/dev/null || true
    rm -f "$mp4" "$ffmpeg_log"
    exit 1
fi
