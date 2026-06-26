#!/usr/bin/env bash
set -euo pipefail

# Example: build a channel list from iptv-org's Finland M3U playlist.
# Adjust M3U_URL to match your country/region.
M3U_URL="https://iptv-org.github.io/iptv/countries/fi.m3u"
EPG_REPO_DIR="/app"
OUTPUT="/app/my-channels.xml"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

echo "$(date -Iseconds) Downloading M3U playlist"
curl -fsSL "$M3U_URL" -o "$WORKDIR/fi.m3u.raw"
tr -d '\r' < "$WORKDIR/fi.m3u.raw" > "$WORKDIR/fi.m3u"

grep -oP 'tvg-id="\K[^"]+' "$WORKDIR/fi.m3u" | sort -u > "$WORKDIR/wanted_ids.txt"

WANTED_COUNT=$(wc -l < "$WORKDIR/wanted_ids.txt")
echo "$(date -Iseconds) Found $WANTED_COUNT unique tvg-ids in M3U"

# Collect all <channel ...> lines from the iptv-org site definitions.
# Using find + xargs avoids shell globbing limits when hundreds of subdirectories exist.
find "$EPG_REPO_DIR/sites" -iname '*.channels.xml' -print0 \
  | xargs -0 grep -h '<channel ' | tr -d '\r' > "$WORKDIR/all_channel_lines.txt" || true

ALL_LINES_COUNT=$(wc -l < "$WORKDIR/all_channel_lines.txt")
echo "$(date -Iseconds) Read $ALL_LINES_COUNT channel lines from site modules"

echo '<?xml version="1.0" encoding="UTF-8"?>' > "$OUTPUT"
echo '<channels>' >> "$OUTPUT"

FOUND_COUNT=0
while IFS= read -r wanted_id; do
  # It is normal that some M3U channels have no EPG source.
  # "|| true" prevents set -e from aborting the loop on a missing match.
  line=$(grep -F "xmltv_id=\"${wanted_id}\"" "$WORKDIR/all_channel_lines.txt" | head -1 || true)
  if [ -n "$line" ]; then
    echo "  $line" >> "$OUTPUT"
    FOUND_COUNT=$((FOUND_COUNT+1))
  fi
done < "$WORKDIR/wanted_ids.txt"

echo '</channels>' >> "$OUTPUT"

echo "$(date -Iseconds) Mapped $FOUND_COUNT / $WANTED_COUNT channels to EPG sources"
echo "$(date -Iseconds) Channels without EPG source:"
comm -23 "$WORKDIR/wanted_ids.txt" <(grep -oP 'xmltv_id="\K[^"]+' "$OUTPUT" | sort -u || true)
