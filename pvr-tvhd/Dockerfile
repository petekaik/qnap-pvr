# qnap-pvr fork — TVH with postproc-webui extensions.
#
# FP-1 build:
#   - builder: compile TVH from upstream source tree at
#     /src/tvh-src with our pvr_queue.c / webui.c / Makefile
#     patches applied. /src/tvh-src is provided as a build
#     context (see build.sh) so we don't have to COPY the
#     whole TVH tree into this image.
#   - runner:  Alpine base, install the build output and
#     our custom entrypoint that forces --config /config.
#
# Why we don't reuse the upstream Containerfile directly:
#   - It uses `COPY . /src/` to slurp the entire build
#     context. Our build context is just the patches; the
#     source tree lives on the build host.
#   - The runner stage drops `VOLUME /var/lib/tvheadend`
#     and `WORKDIR /var/lib/tvheadend/` and the
#     `USER tvheadend` directives, which is what we want
#     here — pvr-queue-exposer and friends need root to
#     write to /comskip/queue and /transcoder/queue, and
#     docker compose recreates the volume on first boot
#     so a USER-constrained WORKDIR leaves tvheadend
#     config-less.

ARG ALPINE_VERSION="3.20"

# ─── builder ─────────────────────────────────────────────
FROM docker.io/alpine:${ALPINE_VERSION} AS builder

ARG TVH_SRC=/src/tvh-src

WORKDIR /src

RUN apk add --no-cache \
        'avahi-dev' \
        'bash' \
        'bsd-compat-headers' \
        'build-base' \
        'cmake' \
        'coreutils' \
        'dbus-dev' \
        'findutils' \
        'gettext-dev' \
        'git' \
        'gnu-libiconv-dev' \
        'libdvbcsa-dev' \
        'libhdhomerun-dev' \
        'linux-headers' \
        'musl-dev' \
        'openssl-dev>3' \
        'pcre2' \
        'pngquant' \
        'python3' \
        'uriparser-dev' \
        'wget' \
        'zlib-dev'

# TVH_SRC is mounted as a build context (see build.sh).
# We copy the source tree into the build layer so the
# build is self-contained and reproducible.
COPY tvh-src/ /src/tvh-src/

WORKDIR /src/tvh-src

RUN git config --global --add safe.directory '/src/tvh-src/data/dvb-scan' && \
    ./configure \
        --prefix='/usr/local' \
        --disable-doc \
        --disable-execinfo \
        --disable-ffmpeg_static \
        --disable-hdhomerun_static \
        --disable-libfdkaac_static \
        --disable-libmfx_static \
        --disable-libopus_static \
        --disable-libtheora_static \
        --disable-libvorbis_static \
        --disable-libvpx_static \
        --disable-libx264_static \
        --disable-libx265_static \
        --enable-bundle \
        --enable-dvbcsa \
        --enable-hdhomerun_client \
        --enable-kqueue \
        --disable-libav \
        --enable-pngquant \
        --python=python3 && \
    make DESTDIR='/tvheadend' -j$(($(nproc) - 1)) install

# ─── runner ──────────────────────────────────────────────
FROM docker.io/alpine:${ALPINE_VERSION} AS runner

LABEL org.opencontainers.image.source="https://github.com/petekaik/qnap-pvr"
LABEL org.opencontainers.image.description="qnap-pvr fork of Tvheadend with Post-Processing webui tab"

EXPOSE 9981 9982 9983

RUN apk add --no-cache \
        'avahi' \
        'bzip2' \
        'dbus-libs' \
        'gnu-libiconv-libs' \
        'libcrypto3' \
        'libdvbcsa' \
        'libhdhomerun-libs' \
        'libssl3' \
        'liburiparser' \
        'libva' \
        'libvpx' \
        'mesa' \
        'perl-http-entity-parser' \
        'pngquant' \
        'pcre2' \
        'python3' \
        'tini' \
        'xmltv' \
        'zlib'

COPY --from=builder "/tvheadend" "/"
COPY rootfs/init.d/container-entrypoint.sh /init

# The webui bundle (tvh.js.gz) is built by the upstream
# build process when it walks src/webui/static/app/*.js.
# Our postproc.js is added to that list via Makefile.webui
# in tvh-src/, so the bundle step already includes it
# when the builder stage runs. We don't COPY postproc.js
# separately — the bundle ships inside `/tvheadend` and
# is what the web server actually serves.

# Note: NO VOLUME directive here. docker compose binds
# /config and /recordings explicitly. The upstream
# `VOLUME /var/lib/tvheadend` is exactly what breaks the
# healthcheck — declaring it tells docker that the path
# should be a fresh anonymous volume, which overwrites
# the bind mount on recreate.

# Note: NO USER directive either. tvheadend runs as root
# in this image so it can write to /comskip/queue,
# /transcoder/queue, and /config without permission
# surprises. The upstream linuxserver image runs as
# user "abc" via s6-overlay; we keep things simple
# here.

# WORKDIR /config — tvheadend needs to start inside its
# config directory. The upstream Containerfile sets
# WORKDIR /var/lib/tvheadend/ which is empty in our
# build (we never declare the VOLUME), so tvheadend
# exits 78 with no log output. WORKDIR /config gives
# the binary the layout it expects: the config tree
# (accesscontrol, channel, dvr, epgdb, …) lives next
# to the cwd.
WORKDIR /config

ENTRYPOINT [ "/sbin/tini", "--", "/init" ]
