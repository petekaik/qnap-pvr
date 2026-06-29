#!/bin/sh
# Container entrypoint for the PVR transcode image.
#
# Single role: transcode. On start:
#   1. Prune done-list: drop paths whose source recording no longer
#      exists on disk. Keeps the done-list from growing forever as
#      recordings are deleted in TVH, and lets a reused path be
#      re-processed (instead of silently skipped).
#   2. Run the transcode pool once (drains whatever is already queued).
#   3. Install a crontab that runs the transcode pool every TRANSCODE_CRON.
#   4. Tail the cron + transcode logs in the foreground so the
#      container stays up and logs are visible via docker logs.
#
# Steps 1-2 mirror comskip/etc/scripts/entrypoint.sh: prune first,
# then drain. After the cron tick is installed, every subsequent
# invocation is `run` only (no prune, to avoid surprising the
# operator by deleting done-list entries mid-day).

set -e

echo "[entrypoint] role=transcode"

CRON_EXPR="${TRANSCODE_CRON:-0 * * * *}"

mkdir -p /transcoder/queue /media/transcoded /var/log

cat > /etc/cron.d/transcoder <<EOF
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
SHELL=/bin/sh
MAILTO=""
$CRON_EXPR root /bin/sh /etc/transcoder/transcode-pool.sh run >> /var/log/transcode-nightly.log 2>&1
EOF
chmod 0644 /etc/cron.d/transcoder

echo "[entrypoint] crontab:"
cat /etc/cron.d/transcoder

touch /var/log/cron.log /var/log/transcode-nightly.log

# Prune the done-list, then run the pool once so anything already
# queued is processed. Both are best-effort: a failure here does
# not block the cron tick or the container.
echo "[entrypoint] prune done-list"
/bin/sh /etc/transcoder/transcode-pool.sh prune-done >> /var/log/transcode-nightly.log 2>&1 || \
    echo "[entrypoint] prune returned non-zero (continuing)"

echo "[entrypoint] initial pool run"
/bin/sh /etc/transcoder/transcode-pool.sh run >> /var/log/transcode-nightly.log 2>&1 || \
    echo "[entrypoint] initial pool run returned non-zero (will retry on schedule)"

service cron start >/dev/null 2>&1 || cron >/dev/null 2>&1

exec tail -F /var/log/cron.log /var/log/transcode-nightly.log