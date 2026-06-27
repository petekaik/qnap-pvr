#!/bin/sh
# Process a single comskip queue entry.
# Called by comskip-pool.sh with the JSON line as the first argument.

LINE="$1"
LOG="/transcoder/queue/comskip.log"

mkdir -p "$(dirname "$LOG")"

path=$(printf '%s\n' "$LINE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["path"])') 2>/dev/null || {
    echo "$(date -Iseconds) SKIP malformed comskip JSON: $LINE" >> "$LOG"
    exit 1
}

[ -f "$path" ] || {
    echo "$(date -Iseconds) SKIP missing $path" >> "$LOG"
    exit 2
}

channel=$(python3 /etc/transcoder/check-channel.py "$path" 2>/dev/null)
if [ $? -eq 0 ]; then
    echo "$(date -Iseconds) SKIP comskip for $path (channel '$channel' is commercial-free)" >> "$LOG"
    exit 0
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
    exit 1
fi
