#!/bin/sh
# Health check for the TVHeadend container: returns 0 when /dev/dvb
# is present with at least one adapter, otherwise returns 1.
#
# This script is mounted into the TVH container at /usr/local/bin/ and
# referenced by docker-compose healthcheck. Docker restarts the
# container automatically if /healthcheck.sh keeps failing.

set -e

# Wait briefly for the device to appear. Container init may have run
# before USB enumeration finished; 30 s is plenty for em28xx binding.
for i in $(seq 1 30); do
    if [ -d /dev/dvb ] && [ -n "$(ls /dev/dvb 2>/dev/null)" ]; then
        # At least one adapter has a frontend node.
        if find /dev/dvb -maxdepth 2 -name 'frontend*' -print -quit | grep -q .; then
            exit 0
        fi
    fi
    sleep 1
done

echo "healthcheck: /dev/dvb missing or empty after 30s" >&2
ls -la /dev/dvb 2>&1 >&2 || true
exit 1