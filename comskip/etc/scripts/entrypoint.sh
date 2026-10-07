#!/bin/sh
# Container entrypoint for the PVR comskip image.
#
# On start:
#   1. Prune done-list: drop paths whose source .ts no longer exists.
#   2. Drain once: process anything already in the queue (left over
#      from before the restart, or queued by TVH post-recording while
#      this container was down).
#   3. Watch the queue with `tail -F` for new lines as they arrive.
#   4. Tail comskip.log so the container stays up and the operator
#      can see activity via `docker logs <container>`.
#
# The tail -F alone (without steps 1-2) would miss lines that were
# queued before this start. tail -F -n 0 only follows newly-appended
# lines; it does not replay existing ones. Restarting a container
# would otherwise leave the queue frozen until the operator manually
# re-runs the pool.
#
# Cron-driven side tasks:
#   The container also runs crond to schedule cleanup-orphans on the
#   CLEANUP_CRON schedule (default "0 4 * * *" — 04:00 daily, when
#   storage is quiet). Crontab is generated at entrypoint time from
#   the env var so the operator can tune the schedule without
#   rebuilding the image. The orphan cleanup deletes .edl/.txt/.sm
#   sidecars whose .ts was removed by TVH's removal-days sweep.

set -e

POOL="/etc/comskip/scripts/comskip-pool.sh"
LOG="/comskip/queue/comskip.log"
# /etc/comskip is bind-mounted read-only from the host (it
# contains the config + the image-baked scripts), so we cannot
# write the crontab there. /comskip/queue is the writable
# runtime directory; put the generated crontab there and
# `crontab <file>` will install it.
CRON_FILE="/comskip/queue/crontab"

echo "[entrypoint] role=comskip"

# Drain and prune BEFORE the tail loop starts. drain_once internally
# calls the pool's own drain routine (same code path as tail mode).
"$POOL" drain >> "$LOG" 2>&1 || echo "[entrypoint] drain returned non-zero (continuing)"
"$POOL" prune-done >> "$LOG" 2>&1 || echo "[entrypoint] prune returned non-zero (continuing)"

# Generate the crontab from CLEANUP_CRON env var. Default is 04:00
# daily — chosen to coincide with the transcode container's schedule
# so both orphan-cleanup runs hit the disk at the same quiet hour.
_CLEANUP_CRON="${CLEANUP_CRON:-0 4 * * *}"
# Run once at container start so we don't wait up to 24h for the
# first cleanup after a long-running container is restarted.
printf 'SHELL=/bin/sh\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n%s /etc/comskip/scripts/comskip-pool.sh cleanup-orphans >> /comskip/queue/comskip.log 2>&1\n' "$_CLEANUP_CRON" > "$CRON_FILE"
# Also run once 60 seconds after start, then on cron schedule. The
# 60s offset lets the watch loop settle so we don't compete for I/O
# during initial drain.
printf '@reboot sleep 60 && /etc/comskip/scripts/comskip-pool.sh cleanup-orphans >> /comskip/queue/comskip.log 2>&1\n' >> "$CRON_FILE"
# Make sure crond is installed (pvr-base ships cron). Start it in
# the background. We do NOT replace the foreground watch — crond
# is a separate long-running daemon, and the watch loop keeps the
# container up. If crond dies, the container restart policy will
# revive the whole container.
crontab "$CRON_FILE" 2>&1 || echo "[entrypoint] crontab install failed (cron disabled)"
crond -f -L /comskip/queue/cron.log &
CROND_PID=$!
echo "[entrypoint] crond started (pid=$CROND_PID, cleanup-orphans cron='$_CLEANUP_CRON')"

# Now watch for new arrivals in the background. Output of `tail -F
# comskip.log` keeps the foreground process alive AND gives the
# operator a single `docker logs` view of the queue activity.
tail -F "$LOG" &
TAIL_PID=$!

"$POOL" watch >> "$LOG" 2>&1 &
WATCH_PID=$!

# Wait on any — if any dies the container should restart. We add
# CROND_PID to the wait list so a crond failure also triggers a
# container restart.
wait "$TAIL_PID" "$WATCH_PID" "$CROND_PID"