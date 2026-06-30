#!/bin/sh
# Build all PVR images in the correct order:
#   1. pvr-base:latest        - shared apt layer (debian + ffmpeg + python3 + ...)
#   2. pvr-comskip:latest     - FROM pvr-base, adds comskip binary + pool scripts
#   3. pvr-transcode:latest   - FROM pvr-base, adds transcode pool + generate-nfo
#   4. pvr-queue-exposer:latest - Alpine + Python 3.12 HTTP bridge for queue files
#   5. pvr-tvheadend:latest   - qnap-pvr fork of lscr.io/linuxserver/tvheadend
#                              with Post-Processing tab in the webui
#
# Usage:
#   ./build.sh              # build with cache
#   ./build.sh --no-cache   # full rebuild

set -eu

cd "$(dirname "$0")"
PROJECT_DIR="$(pwd)"

# If .env exists in the project root, source the specific
# build-args we need rather than the whole file. .env on some
# hosts has trailing comments on lines, which dot/source
# chokes on; parsing the values we want sidesteps that.
PVR_EXPOSER_LAN_URL=""
if [ -f "$PROJECT_DIR/.env" ]; then
    PVR_EXPOSER_LAN_URL="$(grep -E '^PVR_EXPOSER_LAN_URL=' \
                              "$PROJECT_DIR/.env" \
                            | head -1 | cut -d= -f2-)"
fi
: "${PVR_EXPOSER_LAN_URL:=http://10.0.10.13:8765}"

export PVR_EXPOSER_LAN_URL

CACHE_FLAG=""
for arg in "$@"; do
    case "$arg" in
        --no-cache) CACHE_FLAG="--no-cache" ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

echo "[$(date '+%Y-%m-%d %H:%M:%S')] building pvr-base"
docker build $CACHE_FLAG -t pvr-base:latest "$PROJECT_DIR/pvr-base"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] building pvr-comskip"
docker build $CACHE_FLAG -t pvr-comskip:latest "$PROJECT_DIR/comskip"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] building pvr-transcode"
docker build $CACHE_FLAG -t pvr-transcode:latest "$PROJECT_DIR/transcoder"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] building pvr-queue-exposer"
docker build $CACHE_FLAG -t pvr-queue-exposer:latest "$PROJECT_DIR/pvr-queue-exposer"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] building pvr-tvheadend"
docker build $CACHE_FLAG \
    --build-arg PVR_EXPOSER_LAN_URL="${PVR_EXPOSER_LAN_URL:-http://10.0.10.13:8765}" \
    -t pvr-tvheadend:latest \
    "$PROJECT_DIR/pvr-tvhd"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] done"
docker images | grep -E "^REPOSITORY|pvr-(base|comskip|transcode|queue-exposer|tvheadend)" || true
