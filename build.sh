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
# pvr-tvhd/Dockerfile expects tvh-src/ inside its build
# context so the builder stage can COPY it. tvh-src/ is
# gitignored and is the working tree where the qnap-pvr
# fork patches live (pvr_queue.c, webui.c, Makefile).
# We rsync it in here so the build is self-contained.
if [ -d "$PROJECT_DIR/tvh-src" ]; then
    rsync -a --delete \
        --exclude='.git' \
        "$PROJECT_DIR/tvh-src/" \
        "$PROJECT_DIR/pvr-tvhd/tvh-src/"
else
    echo "ERROR: $PROJECT_DIR/tvh-src not found." >&2
    echo "  Clone TVH upstream and apply the qnap-pvr fork patches:" >&2
    echo "    git clone --depth 1 https://github.com/tvheadend/tvheadend.git tvh-src" >&2
    echo "    cp -a pvr-tvhd/pvr_queue.{c,h} tvh-src/src/webui/" >&2
    echo "    # then patch Makefile, webui.c, Makefile.webui (see BACKLOG.md FP-1)" >&2
    exit 1
fi
docker build $CACHE_FLAG \
    --build-arg PVR_EXPOSER_LAN_URL="${PVR_EXPOSER_LAN_URL:-http://10.0.10.13:8765}" \
    -t pvr-tvheadend:latest \
    "$PROJECT_DIR/pvr-tvhd"
# Clean up the rsynced source tree so it doesn't pollute
# the next pvr-tvhd edit / commit.
rm -rf "$PROJECT_DIR/pvr-tvhd/tvh-src"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] done"
docker images | grep -E "^REPOSITORY|pvr-(base|comskip|transcode|queue-exposer|tvheadend)" || true
