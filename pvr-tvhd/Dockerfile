FROM lscr.io/linuxserver/tvheadend:latest

# No-op fork. We reverted to the upstream image after the
# post-processing tab work was paused (see the plan in
# ~/.hermes/plans/postproc-webui.md for the next steps).
# This Dockerfile exists so compose.yml's `build.context:
# ./pvr-tvhd` still resolves, and so we can re-introduce
# patches incrementally in a controlled way.
