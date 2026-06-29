#!/bin/sh
# Container entrypoint for the PVR transcode image.
#
# Single role: transcode. On start:
#   1. Recover orphaned tmp: if a previous run died mid-flight
#      (FFmpeg SIGKILL on `docker compose restart`, host reboot,
#      OOM kill), the drain step left a jsonl.tmp on disk with
#      untouched lines. Re-append those to the queue so the
#      initial run picks them up.
#   2. Prune done-list: drop paths whose source recording no
#      longer exists on disk. Keeps the done-list from growing
#      forever as recordings are deleted in TVH, and lets a
#      reused path be re-processed (instead of silently skipped).
#   3. Run the transcode pool once (drains whatever is already
#      queued, including any lines recovered in step 1).
#   4. Install a crontab that runs the transcode pool every
#      TRANSCODE_CRON.
#   5. Tail the cron + transcode logs in the foreground so the
#      container stays up and logs are visible via docker logs.
#
# Step ordering matters: recover-orphaned-tmp must come BEFORE
# the initial run, so the recovered lines are part of the same
# drain cycle. Prune-done is called AFTER recover but BEFORE run,
# so a recovered line whose source has since been deleted does
# not waste an FFmpeg attempt.
#
# After the cron tick is installed, every subsequent invocation
# is `run` only (no recover, no prune) to avoid surprising the
# operator by deleting done-list entries or re-running jobs mid-day.

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

# Best-effort recovery and prune. A failure here does not block
# the cron tick or the container — the next scheduled run will
# retry the same recovery.
echo "[entrypoint] recover orphaned tmp"
/bin/sh /etc/transcoder/transcode-pool.sh recover-orphaned-tmp >> /var/log/transcode-nightly.log 2>&1 || \
    echo "[entrypoint] recover returned non-zero (continuing)"

echo "[entrypoint] prune done-list"
/bin/sh /etc/transcoder/transcode-pool.sh prune-done >> /var/log/transcode-nightly.log 2>&1 || \
    echo "[entrypoint] prune returned non-zero (continuing)"

echo "[entrypoint] initial pool run"
/bin/sh /etc/transcoder/transcode-pool.sh run >> /var/log/transcode-nightly.log 2>&1 || \
    echo "[entrypoint] initial pool run returned non-zero (will retry on schedule)"

service cron start >/dev/null 2>&1 || cron >/dev/null 2>&1

exec tail -F /var/log/cron.log /var/log/transcode-nightly.log