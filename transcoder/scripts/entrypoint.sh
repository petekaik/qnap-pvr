#!/bin/sh
# Container entrypoint for the PVR transcoder.
# Builds a crontab from TRANSCODE_CRON and keeps the container alive.

CRON_EXPR="${TRANSCODE_CRON:-0 2 * * *}"
CRON_USER="${TRANSCODE_USER:-root}"

echo "${CRON_EXPR} ${CRON_USER} /bin/sh /etc/transcoder/nightly-transcode.sh" > /etc/crontabs/root

echo "[entrypoint] crontab:"
cat /etc/crontabs/root

mkdir -p /var/log /media/transcoded /transcoder/queue
touch /var/log/cron.log /var/log/transcode-nightly.log

# Start crond in the background so it is not PID 1 (avoids setpgid error).
crond -l 2 -L /var/log/cron.log

# Keep the container alive by following logs.
exec tail -f /var/log/cron.log /var/log/transcode-nightly.log
