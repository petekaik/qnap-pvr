FROM lscr.io/linuxserver/tvheadend:latest

# qnap-pvr fork — Post-Processing tab.
#
# FP-1 status (2026-06-30):
#   - pvr_queue.c / pvr_queue.h / webui.c patches / Makefile
#     changes exist in tvh-src/ and produce a working
#     pvr-tvheadend:built binary.
#   - However, the resulting image fails the docker compose
#     healthcheck because the upstream Containerfile declares
#     `VOLUME /var/lib/tvheadend` — when docker compose
#     recreates the container, the working directory is empty
#     and TVH has no config to read on first boot.
#   - Until the custom entrypoint.sh that bypasses the
#     VOLUME is added, we keep compose pointing at the
#     stock upstream image. See the plan in
#     ~/.hermes/plans/postproc-webui.md for the rebuild
#     sequence.
#
# When ready to switch to the fork, change the FROM line to
# the multi-stage TVH build (or use a separate build target)
# and update compose.yml. The postproc.js webui module
# already lives in pvr-tvhd/rootfs/ and is referenced by
# Makefile.webui, so the build is the only remaining step.
