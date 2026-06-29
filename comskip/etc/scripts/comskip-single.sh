#!/bin/sh
# Process a single comskip queue entry.
# Called by comskip-pool.sh with the JSON line as the first argument.
#
# Configuration (comskip binary path, comskip.ini path, channel skip list,
# retry policy) is read from /etc/comskip/config.yaml.

set -e

LINE="$1"
CONFIG="/etc/comskip/config.yaml"
LOG="/comskip/queue/comskip.log"
QUEUE="/comskip/queue/comskip-queue.jsonl"
ERRORS="/comskip/queue/errors.jsonl"

# Defaults — overridden by config.yaml.
COMSKIP_INI="/etc/comskip/comskip.ini"
COMSKIP_BIN="/usr/local/bin/comskip"
NICE_LEVEL=19
MAX_RETRIES=3
CHANNELS_FILE="/tmp/comskip-channels.txt"  # written by cfg load

mkdir -p "$(dirname "$LOG")"

# Load config.yaml.
if [ -f "$CONFIG" ]; then
    eval "$(python3 -c "
import yaml
with open('$CONFIG') as f:
    data = yaml.safe_load(f) or {}
print('COMSKIP_INI=' + repr(data.get('comskip_ini', '$COMSKIP_INI')))
print('COMSKIP_BIN=' + repr(data.get('comskip_binary', '$COMSKIP_BIN')))
print('NICE_LEVEL=' + repr(data.get('worker', {}).get('nice_level', $NICE_LEVEL)))
print('MAX_RETRIES=' + repr(data.get('worker', {}).get('max_retries', $MAX_RETRIES)))
channels = data.get('commercial_free_channels', [])
with open('$CHANNELS_FILE', 'w') as cf:
    for c in channels:
        cf.write(c + '\n')
")"
fi

path=$(printf '%s\n' "$LINE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["path"])') 2>/dev/null || {
    echo "$(date -Iseconds) SKIP malformed comskip JSON: $LINE" >> "$LOG"
    exit 1
}

[ -f "$path" ] || {
    echo "$(date -Iseconds) SKIP missing $path" >> "$LOG"
    exit 2
}

# Channel check uses the channels file written by config load.
channel=$(python3 /etc/comskip/check-channel.py "$path" "$CHANNELS_FILE" 2>/dev/null) || {
    rc=$?
    if [ $rc -eq 0 ]; then
        echo "$(date -Iseconds) SKIP comskip for $path (channel '$channel' is commercial-free)" >> "$LOG"
        exit 0
    fi
    # rc != 0 and rc != 1 means check-channel failed; proceed with comskip.
    channel=""
}

base="${path%.*}"
outdir="$(dirname "$path")"
echo "$(date -Iseconds) RUN comskip $path (channel '$channel')" >> "$LOG"
nice -n "$NICE_LEVEL" "$COMSKIP_BIN" --ini="$COMSKIP_INI" --output="$outdir" "$path" >> "$LOG" 2>&1
rc=$?
if [ $rc -eq 0 ]; then
    echo "$(date -Iseconds) OK comskip $path" >> "$LOG"
    if [ -f "${base}.edl" ]; then
        echo "$(date -Iseconds) EDL generated ${base}.edl" >> "$LOG"
    fi
elif [ $rc -eq 1 ]; then
    # rc=1 from comskip = "Commercials were not found" — treat as success.
    echo "$(date -Iseconds) OK comskip $path (no commercials detected)" >> "$LOG"
else
    echo "$(date -Iseconds) FAIL comskip $path (rc=$rc)" >> "$LOG"
    exit 1
fi