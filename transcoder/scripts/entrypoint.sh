#!/bin/sh
# Container entrypoint for the PVR transcoder.
# Builds a crontab from TRANSCODE_CRON, starts the comskip worker, and keeps
# the container alive.

CRON_EXPR="${TRANSCODE_CRON:-0 2 * * *}"
CRON_USER="${TRANSCODE_USER:-root}"

# Debian uses /etc/cron.d/ instead of /etc/crontabs/.
mkdir -p /etc/cron.d
printf '%s %s /bin/sh /etc/transcoder/nightly-transcode.sh\n' "$CRON_EXPR" "$CRON_USER" > /etc/cron.d/transcoder
chmod 0644 /etc/cron.d/transcoder

# Forward cron output to docker logs if available.
printf 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\nSHELL=/bin/sh\nMAILTO=""\n'

echo "[entrypoint] crontab:"
cat /etc/cron.d/transcoder

mkdir -p /var/log /media/transcoded /transcoder/queue

touch /var/log/cron.log /var/log/transcode-nightly.log

# Start crond in the background so it is not PID 1.
service cron start >/dev/null 2>&1 || cron >/dev/null 2>&1

# Start the comskip worker in the background; it processes recordings
# immediately after the post-recording hook enqueues them.
/bin/sh /etc/transcoder/comskip-worker.sh >/dev/null 2>&1 &

# Keep the container alive by following logs.
exec tail -f /var/log/cron.log /var/log/transcode-nightly.log
