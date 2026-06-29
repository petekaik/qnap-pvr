#!/bin/sh
# Build all PVR images in the correct order:
#   1. pvr-base:latest       - shared apt layer (debian + ffmpeg + python3 + ...)
#   2. pvr-comskip:latest    - FROM pvr-base, adds comskip binary + pool scripts
#   3. pvr-transcode:latest  - FROM pvr-base, adds transcode pool + generate-nfo
#
# Usage:
#   ./build.sh              # build with cache
#   ./build.sh --no-cache   # full rebuild

set -eu

cd "$(dirname "$0")"
PROJECT_DIR="$(pwd)"

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

echo "[$(date '+%Y-%m-%d %H:%M:%S')] done"
docker images | grep -E "^REPOSITORY|pvr-(base|comskip|transcode)" || true
