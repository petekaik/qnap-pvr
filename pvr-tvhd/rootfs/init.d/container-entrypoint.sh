#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# qnap-pvr fork entrypoint.
#
# The Dockerfile sets WORKDIR /config, so tvheadend already
# finds the right config tree without -c. We exec the binary
# directly; the only deviation from upstream is dropping the
# default tvheadend binary detection in favour of an explicit
# exec, which makes log redirection reliable in compose.

set -eu

exec /usr/local/bin/tvheadend "$@"

exit 0
