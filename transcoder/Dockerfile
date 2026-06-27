FROM debian:bullseye-slim

# Install ffmpeg for transcoding (Debian bullseye ships ffmpeg 4.3.x which
# is compatible with comskip), cron, and python3 for JSONL parsing.
# Coreutils provides flock.
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ffmpeg \
        cron \
        coreutils \
        bash \
        python3 \
        ca-certificates \
        libargtable2-0 \
        libsdl1.2debian \
        procps && \
    rm -rf /var/lib/apt/lists/*

# comskip binary is built separately and copied from the host build directory
# at image build time. The .so dependencies above must match the build image.
COPY build/comskip /usr/local/bin/comskip

COPY scripts/post-recording.sh         /usr/local/bin/post-recording.sh
COPY scripts/nightly-transcode.sh      /etc/transcoder/nightly-transcode.sh
COPY scripts/entrypoint.sh             /usr/local/bin/entrypoint.sh
COPY scripts/generate-nfo.py           /etc/transcoder/generate-nfo.py
COPY scripts/check-channel.py          /etc/transcoder/check-channel.py
COPY scripts/comskip-worker.sh         /etc/transcoder/comskip-worker.sh
COPY scripts/comskip-pool.sh           /etc/transcoder/comskip-pool.sh
COPY scripts/comskip-single.sh         /etc/transcoder/comskip-single.sh
COPY scripts/transcode-pool.sh         /etc/transcoder/transcode-pool.sh
COPY scripts/transcode-single.sh       /etc/transcoder/transcode-single.sh
COPY comskip/comskip.ini               /etc/transcoder/comskip.ini

RUN chmod +x /usr/local/bin/comskip \
             /usr/local/bin/post-recording.sh \
             /etc/transcoder/nightly-transcode.sh \
             /usr/local/bin/entrypoint.sh \
             /etc/transcoder/generate-nfo.py \
             /etc/transcoder/check-channel.py \
             /etc/transcoder/comskip-worker.sh \
             /etc/transcoder/comskip-pool.sh \
             /etc/transcoder/comskip-single.sh \
             /etc/transcoder/transcode-pool.sh \
             /etc/transcoder/transcode-single.sh

VOLUME ["/recordings", "/media/transcoded", "/transcoder/queue", "/config/dvr/log"]

# Default role; overridden by COMPOSE via environment variable CONTAINER_ROLE.
ENV CONTAINER_ROLE=transcode

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
