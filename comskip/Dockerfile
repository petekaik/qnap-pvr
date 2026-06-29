FROM pvr-base:latest

# Comskip container image. Inherits ffmpeg, cron and all comskip
# runtime deps from pvr-base. We deliberately bake only the shell-only
# YAML parser and the worker pool into the image — runtime
# configuration (config.yaml, comskip.ini) is mounted from the host
# so changes take effect on container restart without rebuilding.
#
# Container-internal layout:
#   /usr/local/bin/comskip                    - the comskip binary
#   /usr/local/bin/pvr-config-loader.sh       - shell-only YAML parser
#   /etc/comskip/scripts/comskip-pool.sh      - single-threaded worker
#
# Runtime config and queue files come from the host via compose:
#   comskip/etc       -> /etc/comskip   (config.yaml, comskip.ini)
#   comskip/queue     -> /comskip/queue (queue.jsonl, done, log, errors)

COPY bin/comskip /usr/local/bin/comskip

COPY etc/scripts/pvr-config-loader.sh  /usr/local/bin/pvr-config-loader.sh
COPY etc/scripts/comskip-pool.sh       /etc/comskip/scripts/comskip-pool.sh

RUN chmod +x /usr/local/bin/comskip \
             /usr/local/bin/pvr-config-loader.sh \
             /etc/comskip/scripts/comskip-pool.sh

VOLUME ["/recordings", "/comskip/queue", "/config/dvr/log"]

ENV CONTAINER_ROLE=comskip

ENTRYPOINT ["/etc/comskip/scripts/comskip-pool.sh"]