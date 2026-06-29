FROM debian:bullseye-slim

# Shared base image for both comskip and transcoder containers.
#
# Provides:
#   - ffmpeg 4.3.x (compatible with comskip 0.83.x)
#   - cron for scheduled transcode jobs
#   - python3 + python3-yaml for config/queue parsing
#   - coreutils for flock
#   - libsdl1.2debian + libargtable2-0 (comskip runtime deps)
#   - procps so `ps` works inside containers (debugging)
#
# Tagged as pvr-base:latest. The two service-specific Dockerfiles in
# ./comskip/ and ./transcoder/ inherit from this image and add their
# own scripts + binaries. The split keeps each container image minimal
# and matches the host-side directory layout.

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ffmpeg \
        cron \
        coreutils \
        bash \
        python3 \
        python3-yaml \
        ca-certificates \
        libargtable2-0 \
        libsdl1.2debian \
        procps && \
    rm -rf /var/lib/apt/lists/*

# Default working directory for both downstream images.
WORKDIR /etc/pvr

# Image metadata. The downstream service Dockerfiles override these
# via their own LABEL blocks.
LABEL org.opencontainers.image.title="pvr-base" \
      org.opencontainers.image.description="Shared base for PVR comskip and transcode containers"