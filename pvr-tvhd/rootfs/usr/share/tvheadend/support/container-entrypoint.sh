#!/bin/sh
# Custom container entrypoint for pvr-tvheadend fork.
#
# The upstream TVH Dockerfile declares VOLUME /var/lib/tvheadend
# so Compose will create an anonymous Docker volume there and start
# TVH with an empty runtime configuration (no accesscontrol entries,
# no DVR config, no EPG). The /config bind mount we set up in
# compose.yml is unused, and the webui returns 403 Forbidden because
# of "No access entries loaded".
#
# Tvheadend itself supports a --config flag that points it at any
# directory. We use it to point TVH at /config (where compose.yml
# has bound our persistent config tree).
#
# This entrypoint also sets $HOME for completeness, although TVH
# does not use it.

set -eu

if [ -d /config ]; then
    exec tvheadend --config /config "$@"
else
    exec tvheadend "$@"
fi
