FROM pvr-base:latest

# CC-extract container image. Inherits ffmpeg, python3 and all
# runtime deps from pvr-base. We deliberately bake only the shell-
# only YAML parser, the entrypoint and the worker pool into the
# image — runtime configuration (config.yaml) is mounted from the
# host so changes take effect on container restart without
# rebuilding.
#
# CCExtractor installation:
#   Debian Bullseye's ccextractor package (0.87) is adequate for
#   DVB teletext subtitle extraction from TS files. Newer builds
#   exist on GitHub if Bullseye proves insufficient — switch to
#   a binary download by replacing the apt-get line with a wget
#   of the latest Linux static release. The runtime path the pool
#   expects (/usr/bin/ccextractor) is the same either way.
#
# Container-internal layout:
#   /usr/bin/ccextractor                   - the ccextractor binary
#   /usr/local/bin/pvr-config-loader.sh    - shell-only YAML parser
#   /etc/cc-extract/scripts/ccextract-pool.sh   - single-threaded worker
#   /etc/cc-extract/scripts/entrypoint.sh       - drain → prune → watch
#
# Runtime config and queue files come from the host via compose:
#   cc-extract/etc      -> /etc/cc-extract   (config.yaml)
#   cc-extract/queue    -> /cc-extract/queue (queue.jsonl, done, log)
#   comskip/queue       -> /comskip/queue:ro (comskip-queue.done trigger)
#
# Entry sequence on container start (see entrypoint.sh):
#   1. ccextract-pool.sh drain       — process anything already queued
#   2. ccextract-pool.sh prune-done — drop deleted paths from done-list
#   3. ccextract-pool.sh watch       — tail -F comskip-queue.done for new lines
#
# Disable mechanism (operational escape hatch for low-power hosts):
#   Set CC_EXTRACT_ENABLED=false in .env. The entrypoint checks the
#   env var on start and, when false, sleeps forever instead of
#   starting the worker. The container stays up (so it doesn't
#   trigger compose restart-loops) but consumes ~0 CPU and ~30MB RAM.
#   No recordings are processed while disabled. To re-enable, flip
#   the env var to true and restart the container.

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ccextractor && \
    rm -rf /var/lib/apt/lists/*

COPY etc/scripts/pvr-config-loader.sh  /usr/local/bin/pvr-config-loader.sh
COPY etc/scripts/ccextract-pool.sh      /etc/cc-extract/scripts/ccextract-pool.sh
COPY etc/scripts/entrypoint.sh          /etc/cc-extract/scripts/entrypoint.sh

RUN chmod +x /usr/local/bin/pvr-config-loader.sh \
             /etc/cc-extract/scripts/ccextract-pool.sh \
             /etc/cc-extract/scripts/entrypoint.sh

VOLUME ["/recordings", "/comskip/queue", "/cc-extract/queue", "/config/dvr/log"]

ENV CONTAINER_ROLE=cc-extract

ENTRYPOINT ["/etc/cc-extract/scripts/entrypoint.sh"]
