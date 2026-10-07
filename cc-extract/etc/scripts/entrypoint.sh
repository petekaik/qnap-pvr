#!/bin/sh
# Container entrypoint for the PVR cc-extract image.
#
# On start:
#   1. Prune done-list: drop paths whose source .ts no longer exists.
#   2. Drain once: process anything still unprocessed in the
#      comskip trigger done-list (paths that comskip finished
#      while this container was down).
#   3. Watch the trigger done-list with `tail -F` for new lines.
#   4. Tail cc-extract.log so the container stays up and the
#      operator can see activity via `docker logs <container>`.
#
# The tail -F alone (without steps 1-2) would miss lines that
# arrived before this start. tail -F -n 0 only follows newly-
# appended lines; it does not replay existing ones. Restarting a
# container would otherwise leave anything queued in comskip's
# done-list unprocessed until the operator manually re-runs the
# pool.
#
# Operational disable (CC_EXTRACT_ENABLED=false):
#   When set, the entrypoint prints a notice to the log once and
#   sleeps forever. The container stays up (so compose does not
#   trigger restart-loops) but consumes essentially no CPU and
#   ~30MB RAM. The trigger tail never runs, so no subtitles are
#   extracted. Flip the env var to true and restart the container
#   to re-enable.
#
# Cron-driven side tasks:
#   The container also runs crond to schedule cleanup-orphans on
#   the CLEANUP_CRON schedule (default "0 4 * * *" — 04:00 daily,
#   when storage is quiet). The orphan cleanup deletes .srt
#   sidecars whose .ts was removed by TVH's removal-days sweep.
#   Crontab is generated at entrypoint time from the env var so
#   the schedule can be tuned without rebuilding the image.

set -e

POOL="/etc/cc-extract/scripts/ccextract-pool.sh"
LOG="/cc-extract/queue/cc-extract.log"
# /etc/cc-extract is bind-mounted read-only from the host (it
# contains the config + the image-baked scripts), so we cannot
# write the crontab there. /cc-extract/queue is the writable
# runtime directory; put the generated crontab there.
CRON_FILE="/cc-extract/queue/crontab"

mkdir -p "$(dirname "$LOG")"

echo "[entrypoint] role=cc-extract"

# Generate crontab regardless of enable state, so a later
# re-enable via container restart picks up the schedule
# immediately.
_CLEANUP_CRON="${CLEANUP_CRON:-0 4 * * *}"
printf 'SHELL=/bin/sh\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n%s /etc/cc-extract/scripts/ccextract-pool.sh cleanup-orphans >> /cc-extract/queue/cc-extract.log 2>&1\n' "$_CLEANUP_CRON" > "$CRON_FILE"
printf '@reboot sleep 60 && /etc/cc-extract/scripts/ccextract-pool.sh cleanup-orphans >> /cc-extract/queue/cc-extract.log 2>&1\n' >> "$CRON_FILE"

# Operational escape hatch. If the operator has set CC_EXTRACT_ENABLED
# to anything other than "true" (case-sensitive), sleep forever and
# do nothing. This is the path to take when the Celeron is overtaxed
# and cc-extract needs to be offloaded to silence without removing
# the container definition from compose.
case "${CC_EXTRACT_ENABLED:-true}" in
    true)
        # Normal start.
        "$POOL" drain      >> "$LOG" 2>&1 || echo "[entrypoint] drain returned non-zero (continuing)"
        "$POOL" prune-done >> "$LOG" 2>&1 || echo "[entrypoint] prune returned non-zero (continuing)"

        # Start crond in the background. Even when the pool is
        # disabled we still want cleanup-orphans to run — orphan
        # .srt files should be cleaned up regardless of whether
        # new extraction is happening.
        crontab "$CRON_FILE" 2>&1 || echo "[entrypoint] crontab install failed (cron disabled)"
        crond -f -L /cc-extract/queue/cron.log &
        CROND_PID=$!
        echo "[entrypoint] crond started (pid=$CROND_PID, cleanup-orphans cron='$_CLEANUP_CRON')"

        # Tail the log so docker logs shows live activity AND so
        # the foreground process stays alive (which keeps the
        # container up without a separate no-op loop).
        tail -F "$LOG" &
        TAIL_PID=$!

        "$POOL" watch >> "$LOG" 2>&1 &
        WATCH_PID=$!

        # Wait on any — if any dies the container should restart.
        wait "$TAIL_PID" "$WATCH_PID" "$CROND_PID"
        ;;
    *)
        # Disabled. Still run crond so cleanup-orphans keeps
        # happening even while extraction is paused.
        crontab "$CRON_FILE" 2>&1 || echo "[entrypoint] crontab install failed (cron disabled)"
        crond -f -L /cc-extract/queue/cron.log &
        CROND_PID=$!
        echo "[entrypoint] crond started (pid=$CROND_PID) — cc-extract disabled, but cleanup-orphans still runs"
        echo "[entrypoint] To re-enable, set CC_EXTRACT_ENABLED=true in .env and restart the container."

        # Wait on crond only. The pool stays idle, but the cron
        # schedule still sweeps orphan .srt files. If crond dies
        # the container will restart and re-evaluate enable state.
        wait "$CROND_PID"
        ;;
esac
