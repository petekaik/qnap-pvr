#!/bin/sh
# TVHeadend post-recording hook.
# Runs inside the tvheadend container when a recording finishes.
#
# Behaviour is controlled by /pvr/scripts/config.yaml — see that file
# for the list of gates and queue paths.
#
# Required environment variables (set via compose env_file):
#   PVR_HOST_PREFIX    Host path prefix for recordings. Used as fallback
#                      if config.yaml does not set paths.host_prefix.
#   PVR_LOG_PATH       Log file path inside the container. Must be in a
#                      writable directory (TVH /config works).
#
# This script does NOT depend on python or yaml — the upstream TVH
# image is Alpine and ships neither. We parse the config using a tiny
# shell-only helper at /usr/local/bin/config-loader.sh (mounted from
# /pvr/scripts/config-loader.sh via compose).

set -e

CONFIG="${PVR_CONFIG_PATH:-/pvr/scripts/config.yaml}"
LOG="${PVR_LOG_PATH:-/config/dvr/log/post-recording.log}"

# Load config values (shell-only YAML parsing, no python).
# shellcheck disable=SC1090
. /usr/local/bin/config-loader.sh

LOG_PATH="$LOG"
HOST_PREFIX="${PVR_HOST_PREFIX:-/recordings}"
CONT_PREFIX="/recordings"
COMSKIP_QUEUE="/comskip/queue/comskip-queue.jsonl"
TRANSCODE_QUEUE="/transcoder/queue/transcode-queue.jsonl"
COMSKIP_ENABLED="true"
TRANSCODE_ENABLED="true"

if [ -f "$CONFIG" ]; then
    eval "$(load_config_eval "$CONFIG" \
        log.path="$LOG" \
        paths.host_prefix="$HOST_PREFIX" \
        paths.container_prefix="/recordings" \
        steps.comskip.enable=true \
        steps.comskip.queue=/comskip/queue/comskip-queue.jsonl \
        steps.transcode.enable=true \
        steps.transcode.queue=/transcoder/queue/transcode-queue.jsonl)"

    # Re-derive shell vars with our preferred names (config-loader
    # underscored the dots).
    LOG_PATH="${log_path:-$LOG}"
    HOST_PREFIX="${paths_host_prefix:-$HOST_PREFIX}"
    CONT_PREFIX="${paths_container_prefix:-/recordings}"
    COMSKIP_QUEUE="${steps_comskip_queue:-$COMSKIP_QUEUE}"
    TRANSCODE_QUEUE="${steps_transcode_queue:-$TRANSCODE_QUEUE}"
    [ "${steps_comskip_enable}" = "true" ] && COMSKIP_ENABLED="true" || COMSKIP_ENABLED="false"
    [ "${steps_transcode_enable}" = "true" ] && TRANSCODE_ENABLED="true" || TRANSCODE_ENABLED="false"
fi

# Fallback: if config didn't provide a log path, use the env-supplied
# default; if even that is missing, fall back to /pvr/tmp (mounted from host, big volume).
if [ -z "$LOG_PATH" ]; then
    LOG_PATH="$LOG"
fi

mkdir -p "$(dirname "$LOG_PATH")"
exec >> "$LOG_PATH" 2>&1

RECORDING="$1"
TS=$(date -Iseconds)
echo "[$TS] [tvheadend postprocessor] invoked with: $RECORDING"

resolve_ts() {
    local prefix="$1"

    # If the argument is already a valid .ts file, use it as-is.
    if [ -f "$prefix" ]; then
        printf '%s\n' "$prefix"
        return 0
    fi

    # If the prefix points to a directory, pick the largest .ts file there.
    if [ -d "$prefix" ]; then
        local found
        found=$(find "$prefix" -maxdepth 1 -type f -name '*.ts' -printf '%s %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2-)
        if [ -n "$found" ] && [ -f "$found" ]; then
            printf '%s\n' "$found"
            return 0
        fi
    fi

    # Treat the prefix as a truncated path. Search the parent directory for
    # either a matching directory or a .ts file whose name starts with the
    # truncated basename.
    local dir base d found
    dir=$(dirname "$prefix" 2>/dev/null)
    base=$(basename "$prefix" 2>/dev/null)

    if [ -d "$dir" ]; then
        # First: directory whose name starts with the truncated basename.
        d=$(find "$dir" -maxdepth 1 -type d -name "$base*" 2>/dev/null | head -n1)
        if [ -n "$d" ] && [ -d "$d" ]; then
            found=$(find "$d" -maxdepth 1 -type f -name '*.ts' -printf '%s %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2-)
            if [ -n "$found" ] && [ -f "$found" ]; then
                printf '%s\n' "$found"
                return 0
            fi
        fi

        # Second: .ts file whose name starts with the truncated basename.
        found=$(find "$dir" -maxdepth 1 -type f -name "$base*.ts" -printf '%s %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2-)
        if [ -n "$found" ] && [ -f "$found" ]; then
            printf '%s\n' "$found"
            return 0
        fi
    fi

    return 1
}

RESOLVED=$(resolve_ts "$RECORDING") || {
    echo "[$TS] [tvheadend postprocessor] ERROR: could not resolve .ts file from prefix: $RECORDING"
    exit 1
}

if [ ! -f "$RESOLVED" ]; then
    echo "[$TS] [tvheadend postprocessor] ERROR: resolved file does not exist: $RESOLVED"
    exit 1
fi

echo "[$TS] [tvheadend postprocessor] resolved to: $RESOLVED"

mkdir -p "$(dirname "$COMSKIP_QUEUE")" "$(dirname "$TRANSCODE_QUEUE")"

if [ "$COMSKIP_ENABLED" = "true" ]; then
    printf '{"path":"%s","added":"%s"}\n' "$RESOLVED" "$TS" >> "$COMSKIP_QUEUE"
    echo "[$TS] [tvheadend postprocessor] enqueued $RESOLVED for comskip ($COMSKIP_QUEUE)"
else
    echo "[$TS] [tvheadend postprocessor] SKIP comskip (disabled in config)"
fi

if [ "$TRANSCODE_ENABLED" = "true" ]; then
    printf '{"path":"%s","status":"pending","added":"%s"}\n' "$RESOLVED" "$TS" >> "$TRANSCODE_QUEUE"
    echo "[$TS] [tvheadend postprocessor] queued $RESOLVED for transcode ($TRANSCODE_QUEUE)"
else
    echo "[$TS] [tvheadend postprocessor] SKIP transcode (disabled in config)"
fi