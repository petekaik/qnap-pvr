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

set -e

POOL="/etc/comskip/scripts/comskip-pool.sh"
LOG="/comskip/queue/comskip.log"

echo "[entrypoint] role=comskip"

# Drain and prune BEFORE the tail loop starts. drain_once internally
# calls the pool's own drain routine (same code path as tail mode).
"$POOL" drain >> "$LOG" 2>&1 || echo "[entrypoint] drain returned non-zero (continuing)"
"$POOL" prune-done >> "$LOG" 2>&1 || echo "[entrypoint] prune returned non-zero (continuing)"

# Now watch for new arrivals in the background. Output of `tail -F
# comskip.log` keeps the foreground process alive AND gives the
# operator a single `docker logs` view of the queue activity.
tail -F "$LOG" &
TAIL_PID=$!

"$POOL" watch >> "$LOG" 2>&1 &
WATCH_PID=$!

# Wait on either — if either dies the container should restart.
wait "$TAIL_PID" "$WATCH_PID"