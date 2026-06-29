#!/bin/sh
# Container entrypoint for the PVR transcode image.
#
# Single role: transcode. On start:
#   1. Run transcode-pool.sh once (drains whatever is already queued).
#   2. Install a crontab that runs transcode-pool.sh every TRANSCODE_CRON.
#   3. Tail the cron + transcode logs in the foreground so the
#      container stays up and logs are visible via docker logs.

set -e

echo "[entrypoint] role=transcode"

CRON_EXPR="${TRANSCODE_CRON:-0 * * * *}"

mkdir -p /transcoder/queue /media/transcoded /var/log

cat > /etc/cron.d/transcoder <<EOF
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
SHELL=/bin/sh
MAILTO=""
$CRON_EXPR root /bin/sh /etc/transcoder/transcode-pool.sh >> /var/log/transcode-nightly.log 2>&1
EOF
chmod 0644 /etc/cron.d/transcoder

echo "[entrypoint] crontab:"
cat /etc/cron.d/transcoder

touch /var/log/cron.log /var/log/transcode-nightly.log

# Run the pool once on startup so anything already queued is processed.
echo "[entrypoint] initial pool run"
/bin/sh /etc/transcoder/transcode-pool.sh || echo "[entrypoint] initial pool run returned non-zero (will retry on schedule)"

service cron start >/dev/null 2>&1 || cron >/dev/null 2>&1

exec tail -F /var/log/cron.log /var/log/transcode-nightly.log