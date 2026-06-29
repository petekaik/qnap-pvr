FROM lscr.io/linuxserver/tvheadend:latest

# PVR fork of linuxserver/tvheadend that adds a Post-Processing
# tab to the DVR view and a Post-Processing panel to the Status
# view. The new tab reads the comskip / transcode queue files
# directly via a small HTTP bridge (`pvr-queue-exposer`) on the
# PVR internal network, since TVH itself cannot read those files
# (they live on a host volume that the upstream image does not
# mount).
#
# Approach
# --------
# We *replace* `/usr/share/tvheadend/src/webui/static/app/dvr.js`
# and `status.js` with patched versions that call into our new
# `postproc.js` module. We also drop `postproc.js` next to them.
# TVH's webui loads every `*.js` file in this directory via its
# `<script>` tags in the HTML shell, so registering a new tab
# is just a matter of adding a function on the `tvheadend.*`
# namespace — no plugin manifest required.
#
# Why a separate image (vs. mounting a host directory into the
# upstream container)
# ----------------------------------------------------------------
# TVH's webui is loaded by its internal HTTP server from
# /usr/share/tvheadend/src/webui/static/app/. Mounting host files
# over that directory works but creates a chicken-and-egg problem
# on first boot (the files must exist before the container reads
# them). Baking them into the image means a fresh container is
# usable immediately, and a re-build cleanly reproduces the
# changes.
#
# Build context note
# ------------------
# `rootfs/` holds files that are COPY'd into the image. We use
# a leading `.` so the paths in COPY match the in-image paths
# exactly (Docker requires relative paths in COPY).
#
# Update strategy
# ---------------
# When upstream TVH ships a new release with a tvheadend.js or
# status.js rewrite, rebuild this image and re-apply the small
# patches (dvr.js, status.js) against the new upstream sources.
# The patch surface is small (~10 lines per file) so a
# three-way merge is cheap.

# 1. Replace the two files we patch, and add the new module.
COPY rootfs/usr/share/tvheadend/src/webui/static/app/dvr.js \
     /usr/share/tvheadend/src/webui/static/app/dvr.js
COPY rootfs/usr/share/tvheadend/src/webui/static/app/status.js \
     /usr/share/tvheadend/src/webui/static/app/status.js
COPY rootfs/usr/share/tvheadend/src/webui/static/app/postproc.js \
     /usr/share/tvheadend/src/webui/static/app/postproc.js

# 2. Tag this fork so the webui can show "Post-Processing by
#    qnap-pvr fork" in the About panel. We use a config file
#    (not an env var) because TVH does not pass arbitrary env
#    vars into the JS bundle.
RUN echo "qnap-pvr fork 2026-06-30" \
    > /etc/pvr-tvheadend-fork

# 3. Bust the upstream image's webui cache so the browser pulls
#    the new files on first load. TVH's webui caches static
#    assets aggressively on the client side; we don't need to
#    clear anything on disk because the cache key is the URL
#    itself (we are not changing the URL, but the next page
#    reload after the user pulls the new image will fetch the
#    fresh content). If a user reports stale UI, a hard reload
#    (Ctrl+Shift+R) is enough.

# No entrypoint override — the upstream image's init system
# already runs tvheadend and serves /static from disk. Our
# files replace what was there.