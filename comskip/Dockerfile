FROM pvr-base:latest

# Comskip container image. Inherits ffmpeg, cron and all comskip
# runtime deps from pvr-base. We deliberately bake only the shell-only
# YAML parser, the entrypoint and the worker pool into the image —
# runtime configuration (config.yaml, comskip.ini) is mounted from
# the host so changes take effect on container restart without
# rebuilding.
#
# Container-internal layout:
#   /usr/local/bin/comskip                    - the comskip binary
#   /usr/local/bin/pvr-config-loader.sh       - shell-only YAML parser
#   /etc/comskip/scripts/comskip-pool.sh      - single-threaded worker
#   /etc/comskip/scripts/entrypoint.sh        - drain → prune → watch
#
# Runtime config and queue files come from the host via compose:
#   comskip/etc       -> /etc/comskip   (config.yaml, comskip.ini)
#   comskip/queue     -> /comskip/queue (queue.jsonl, done, log)
#
# Entry sequence on container start (see entrypoint.sh):
#   1. comskip-pool.sh drain    — process anything already queued
#   2. comskip-pool.sh prune-done — drop deleted paths from done-list
#   3. comskip-pool.sh watch    — tail -F the queue for new lines
# Without steps 1-2, a container restart after a QNAP reboot would
# silently drop everything TVH queued while comskip was down: tail
# -F -n 0 only follows newly appended lines, it does not replay
# the queue.

COPY bin/comskip /usr/local/bin/comskip

COPY etc/scripts/pvr-config-loader.sh  /usr/local/bin/pvr-config-loader.sh
COPY etc/scripts/comskip-pool.sh       /etc/comskip/scripts/comskip-pool.sh
COPY etc/scripts/entrypoint.sh         /etc/comskip/scripts/entrypoint.sh

RUN chmod +x /usr/local/bin/comskip \
             /usr/local/bin/pvr-config-loader.sh \
             /etc/comskip/scripts/comskip-pool.sh \
             /etc/comskip/scripts/entrypoint.sh

VOLUME ["/recordings", "/comskip/queue", "/config/dvr/log"]

ENV CONTAINER_ROLE=comskip

ENTRYPOINT ["/etc/comskip/scripts/entrypoint.sh"]