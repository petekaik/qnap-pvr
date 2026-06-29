FROM pvr-base:latest

# Transcode container image. Inherits ffmpeg, python3 (for
# generate-nfo.py), cron, etc. from pvr-base. We bake only the shell-
# only YAML parser, the worker pool script, the NFO generator, and a
# small entrypoint that runs the pool once on container start and
# then again on TRANSCODE_CRON schedule via crond.
#
# Container-internal layout:
#   /usr/local/bin/entrypoint.sh
#   /usr/local/bin/pvr-config-loader.sh
#   /etc/transcoder/transcode-pool.sh
#   /etc/transcoder/generate-nfo.py
#
# Runtime config and queue files come from the host via compose:
#   transcoder/scripts -> /etc/transcoder
#   transcoder/queue   -> /transcoder/queue

COPY scripts/entrypoint.sh             /usr/local/bin/entrypoint.sh
COPY scripts/pvr-config-loader.sh      /usr/local/bin/pvr-config-loader.sh
COPY scripts/transcode-pool.sh         /etc/transcoder/transcode-pool.sh
COPY scripts/generate-nfo.py           /etc/transcoder/generate-nfo.py

RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/pvr-config-loader.sh \
             /etc/transcoder/transcode-pool.sh \
             /etc/transcoder/generate-nfo.py

VOLUME ["/recordings", "/media/transcoded", "/transcoder/queue", "/config/dvr/log"]

ENV CONTAINER_ROLE=transcode

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]