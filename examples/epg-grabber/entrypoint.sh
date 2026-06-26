#!/usr/bin/env bash
set -euo pipefail

# Unix socket exposed by TVHeadend for XMLTV EPG injection.
SOCK=/tvh-config/epggrab/xmltv.sock
OUTPUT=/output/guide.xml

# Increase Node heap to fit the iptv-org database in memory.
# Keep this below the container memory limit configured in compose.yml.
export NODE_OPTIONS="--max-old-space-size=768"

run_grab() {
  echo "$(date -Iseconds) Updating iptv-org/epg repository"
  git -C /app pull --ff-only || echo "$(date -Iseconds) WARNING: git pull failed, using existing copy"

  echo "$(date -Iseconds) Regenerating channel list"
  /app/generate-channels.sh

  echo "$(date -Iseconds) Starting EPG grab"
  npm run grab -- \
    --channels=/app/my-channels.xml \
    --output="$OUTPUT" \
    --days=3

  if [ ! -S "$SOCK" ]; then
    echo "$(date -Iseconds) WARNING: TVH socket $SOCK not found, skipping push"
    return 1
  fi

  echo "$(date -Iseconds) Pushing XMLTV data to TVH socket"
  socat -u "$OUTPUT" UNIX-CONNECT:"$SOCK"
  echo "$(date -Iseconds) Done"
}

run_grab || true

while true; do
  sleep "${INTERVAL_SECONDS:-43200}"
  run_grab || true
done
