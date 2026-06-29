#!/bin/sh
# Process a single transcode queue entry.
# Called by transcode-pool.sh with the JSON line as the first argument.
#
# FFmpeg encoding parameters and other settings are read from
# /etc/transcoder/config.yaml.

set -e

LINE="$1"
CONFIG="/etc/transcoder/config.yaml"
QUEUE="/transcoder/queue/transcode-queue.jsonl"
DONE="/transcoder/queue/transcode-queue.done"
LOG="/var/log/transcode-nightly.log"
ERRORS="/transcoder/queue/errors.jsonl"

# Defaults.
THREADS=2
NICE_LEVEL=19
VCODEC="libx264"
PRESET="ultrafast"
CRF=30
PIXFMT="yuv420p"
SCALE="w=1280:h=720:force_original_aspect_ratio=decrease"
ACODEC="aac"
ABITRATE="192k"
ACHANNELS=2
MOVFLAGS="+faststart"
CAPTURE_LINES=30
COPY_EDL="true"
COPY_TXT="true"
COPY_LOG="false"
NFO_GENERATOR="/etc/transcoder/generate-nfo.py"
HOST_PREFIX="/recordings"
CONT_PREFIX="/recordings"

mkdir -p "$(dirname "$LOG")"

if [ -f "$CONFIG" ]; then
    eval "$(python3 << 'PYEOF'
import yaml, os, sys
with open('/etc/transcoder/config.yaml') as f:
    data = yaml.safe_load(f) or {}
ff = data.get('ffmpeg', {})
nfo = data.get('nfo', {})
# Use Python booleans, then emit shell-side 'true'/'false' strings explicitly.
# Anything truthy -> 'true', anything falsy (None/False/0/''/{}) -> 'false'.
def b(v):
    return 'true' if v else 'false'
print('THREADS=' + repr(ff.get('threads', 2)))
print('NICE_LEVEL=' + repr(ff.get('nice_level', 19)))
print('VCODEC=' + repr(ff.get('video', {}).get('codec', 'libx264')))
print('PRESET=' + repr(ff.get('video', {}).get('preset', 'ultrafast')))
print('CRF=' + repr(ff.get('video', {}).get('crf', 30)))
print('PIXFMT=' + repr(ff.get('video', {}).get('pix_fmt', 'yuv420p')))
print('SCALE=' + repr(ff.get('video', {}).get('scale', 'w=1280:h=720:force_original_aspect_ratio=decrease')))
print('ACODEC=' + repr(ff.get('audio', {}).get('codec', 'aac')))
print('ABITRATE=' + repr(ff.get('audio', {}).get('bitrate', '192k')))
print('ACHANNELS=' + repr(ff.get('audio', {}).get('channels', 2)))
print('MOVFLAGS=' + repr(ff.get('movflags', '+faststart')))
print('CAPTURE_LINES=' + repr(ff.get('capture_stderr_lines', 30)))
cs = nfo.get('copy_sidecars', {})
print('COPY_EDL=' + b(cs.get('edl', True)))
print('COPY_TXT=' + b(cs.get('txt', True)))
print('COPY_LOG=' + b(cs.get('log', False)))
print('NFO_GENERATOR=' + repr(nfo.get('generator', '/etc/transcoder/generate-nfo.py')))
print('HOST_PREFIX=' + repr(data.get('paths', {}).get('host_prefix', '/recordings')))
print('CONT_PREFIX=' + repr(data.get('paths', {}).get('container_prefix', '/recordings')))
PYEOF
)"
fi

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
nice -n "$NICE_LEVEL" ffmpeg -y -hide_banner -loglevel error -threads "$THREADS" -i "$cont_src" \
    -vf "$SCALE" \
    -c:v "$VCODEC" -preset "$PRESET" -crf "$CRF" -pix_fmt "$PIXFMT" \
    -c:a "$ACODEC" -b:a "$ABITRATE" -ac "$ACHANNELS" \
    -movflags "$MOVFLAGS" "$mp4" > "$ffmpeg_log" 2>&1

rc=$?
if [ $rc -eq 0 ]; then
    echo "$(date -Iseconds) OK $src" >> "$LOG"
    flock "$DONE" -c "printf '%s\n' '$src' >> '$DONE'"

    final_mp4=$(python3 "$NFO_GENERATOR" "$cont_src" "$mp4" 2>&1)
    echo "$final_mp4" >> "$LOG"

    final_base=$(echo "$final_mp4" | tail -n1 | sed 's|\.mp4$||')
    if [ "$COPY_EDL" = "true" ] && [ -f "$src_edl" ]; then
        cp "$src_edl" "${final_base}.edl" && echo "$(date -Iseconds) COPIED edl ${src_edl} -> ${final_base}.edl" >> "$LOG"
    fi
    if [ "$COPY_TXT" = "true" ] && [ -f "$src_txt" ]; then
        cp "$src_txt" "${final_base}.txt" && echo "$(date -Iseconds) COPIED txt ${src_txt} -> ${final_base}.txt" >> "$LOG"
    fi
    if [ "$COPY_LOG" = "true" ] && [ -f "$src_log" ]; then
        cp "$src_log" "${final_base}.log" && echo "$(date -Iseconds) COPIED log ${src_log} -> ${final_base}.log" >> "$LOG"
    fi

    rm -f "$ffmpeg_log"
else
    echo "$(date -Iseconds) FAIL $src (rc=$rc)" >> "$LOG"
    tail -n "$CAPTURE_LINES" "$ffmpeg_log" >> "$LOG" 2>/dev/null || true
    rm -f "$mp4" "$ffmpeg_log"
    exit 1
fi