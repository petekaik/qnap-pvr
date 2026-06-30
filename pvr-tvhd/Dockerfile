FROM lscr.io/linuxserver/tvheadend:latest

# PVR fork of linuxserver/tvheadend that adds a Post-Processing
# tab to the DVR view and a Post-Processing panel to the Status
# view.
#
# Implementation
# --------------
# The linuxserver image serves every *.js file in
# /usr/share/tvheadend/src/webui/static/app/ via the standard
# webui bundle path. We drop a new module (`postproc.js`) into
# that directory, plus tiny patches to `dvr.js` and `status.js`
# that call into it. No re-compilation required.
#
# postproc.js fetches queue JSON from `pvr-queue-exposer`
# (defined in compose.yml). The exposer publishes its API on
# the macvlan `eth1` network with a fixed LAN IP
# (PVR_EXPOSER_IP in .env), and at browser scope
# `pvr-queue-exposer` is not resolvable, so we hardcode the
# LAN URL via the build argument PVR_EXPOSER_LAN_URL. Override
# at runtime with `window.PVR_EXPOSER_URL = '...'` before the
# bundle loads.

ARG PVR_EXPOSER_LAN_URL="http://10.0.10.13:8765"

# 1. Drop in our new module and replace the two files we patch.
COPY rootfs/usr/share/tvheadend/src/webui/static/app/dvr.js \
     /usr/share/tvheadend/src/webui/static/app/dvr.js
COPY rootfs/usr/share/tvheadend/src/webui/static/app/status.js \
     /usr/share/tvheadend/src/webui/static/app/status.js
COPY rootfs/usr/share/tvhd-postproc-template.js \
     /usr/share/tvheadend/src/webui/static/app/postproc.js.template

# 2. Substitute the build-time LAN URL into the module template
#    so the baked-in image carries our exposer's LAN address.
#    The template has `__PVR_EXPOSER_LAN_URL__` as a sentinel.
RUN sed "s|__PVR_EXPOSER_LAN_URL__|${PVR_EXPOSER_LAN_URL}|g" \
        /usr/share/tvheadend/src/webui/static/app/postproc.js.template \
        > /usr/share/tvheadend/src/webui/static/app/postproc.js \
    && rm /usr/share/tvheadend/src/webui/static/app/postproc.js.template

# 3. Tag this fork so the webui can show "Post-Processing by
#    qnap-pvr fork" in the About panel.
RUN echo "qnap-pvr fork 2026-06-30" > /etc/pvr-tvheadend-fork
