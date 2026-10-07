#!/bin/sh
# ccextract worker loop. Single-threaded, POSIX-sh only.
#
# Subcommands (default: watch):
#   watch       Tail the comskip done-list and extract subtitles
#               from any newly-finished recording.
#   drain       Process every line in the cc-extract done-list
#               that has not yet been handled, exit.
#   prune-done  Remove paths from cc-extract-queue.done whose source
#               .ts file no longer exists on disk.
#
# The container's entrypoint runs `drain` then `prune-done` once
# before starting `watch` in the background. This guarantees that
# nothing queued while the container was down is silently skipped,
# and that the done-list does not grow forever with paths for
# deleted recordings.
#
# Trigger source: we do NOT maintain a separate JSONL queue. Instead
# we tail comskip-queue.done — every new line there marks a .ts
# that has just finished commercial-detection and is ready for
# subtitle extraction. This keeps post-recording.sh unaware of
# cc-extract's existence (one-way dependency: cc-extract depends on
# comskip, not vice versa).
#
# For each new line:
#   1. Skip if path is in our own done-list (already processed).
#   2. Skip if the source .ts file is gone.
#   3. Skip if <basename>.srt already exists (manual override or
#      earlier successful run from a different path).
#   4. Run ccextractor to produce <basename>.srt next to the source.
#   5. Append the path to cc-extract-queue.done so it is not
#      re-processed on next container restart.
#
# CCExtractor is fast (a few seconds per hour of source) and I/O
# light — running multiple instances in parallel just thrashes
# the Celeron's already-weak disk subsystem. Single sequential
# worker with flock; same model as comskip-pool.
#
# All configuration (binary path, log path, min-srt threshold) lives
# in /etc/cc-extract/config.yaml.

set -e

CONFIG="/etc/cc-extract/config.yaml"
TRIGGER_DONE="/comskip/queue/comskip-queue.done"
QUEUE_DONE="/cc-extract/queue/cc-extract-queue.done"
LOG="/cc-extract/queue/cc-extract.log"
# Lock file lives under /pvr/tmp, which is a writable mount from
# the host's ${DATA}/tmp. /tmp inside the container is a 64MB
# ramdisk that fills with FFmpeg logs under load.
LOCK="/pvr/tmp/cc-extract-pool.lock"

mkdir -p "$(dirname "$LOG")" "$(dirname "$QUEUE_DONE")" "$(dirname "$LOCK")"
[ -f "$TRIGGER_DONE" ] || : > "$TRIGGER_DONE"
[ -f "$QUEUE_DONE" ] || : > "$QUEUE_DONE"

# Defaults — overridden by config.yaml.
CCEXTRACT_BIN="/usr/bin/ccextractor"
NICE_LEVEL=19
MIN_SRT_BYTES=200

if [ -f "$CONFIG" ]; then
    # shellcheck disable=SC1090
    . /usr/local/bin/pvr-config-loader.sh
    eval "$(load_config_eval "$CONFIG" \
        ccextractor_binary=/usr/bin/ccextractor \
        nice_level=19 \
        min_srt_bytes=200)"
    CCEXTRACT_BIN="${ccextractor_binary:-$CCEXTRACT_BIN}"
    NICE_LEVEL="${nice_level:-$NICE_LEVEL}"
    MIN_SRT_BYTES="${min_srt_bytes:-$MIN_SRT_BYTES}"
fi

# Decide what to do based on the subcommand.
CMD="${1:-watch}"

# -------------------------------------------------------------------
# Common: parse one comskip-queue.done line, decide whether to skip
# or run ccextractor.
# Arguments: $1 = full done-list line (a /recordings/.../foo.ts path)
# Side effects: writes to LOG, may append to QUEUE_DONE, may invoke
# ccextractor.
# -------------------------------------------------------------------
process_line() {
    _line="$1"
    [ -n "$_line" ] || return 0

    # The done-list is plain text, one path per line — no JSON to
    # parse. Still, defensive: if someone hand-edits the file with
    # leading whitespace or extra lines, just skip non-paths.
    case "$_line" in
        /*.ts) ;;
        *) return 0 ;;
    esac

    _path="$_line"

    if [ ! -f "$_path" ]; then
        echo "$(date -Iseconds) SKIP missing source: $_path" >> "$LOG"
        return 0
    fi

    if grep -qF "$_path" "$QUEUE_DONE" 2>/dev/null; then
        echo "$(date -Iseconds) SKIP already done: $_path" >> "$LOG"
        return 0
    fi

    _base="${_path%.*}"
    _outdir="$(dirname "$_path")"
    _srt="${_base}.srt"

    # If an .srt already exists, treat it as already-handled. This
    # covers two cases:
    #   1. Manual placement (operator dropped a hand-crafted .srt
    #      into the recordings tree).
    #   2. A previous cc-extract run from outside this container
    #      (e.g. invoked manually via docker exec) already produced
    #      the file. We don't want to overwrite manual work.
    if [ -f "$_srt" ]; then
        echo "$(date -Iseconds) SKIP .srt exists: $_srt" >> "$LOG"
        printf '%s\n' "$_path" >> "$QUEUE_DONE"
        return 0
    fi

    echo "$(date -Iseconds) RUN ccextractor $_path" >> "$LOG"
    # ccextractor is noisy on stderr (per-stream detection info);
    # we send everything to the log file so the operator can grep
    # for warnings if extraction fails, but the structured RUN/OK/
    # SKIP/EMPTY markers above stay visible at the top.
    nice -n "$NICE_LEVEL" "$CCEXTRACT_BIN" \
        -o "$_srt" \
        "$_path" >> "$LOG" 2>&1 || true

    # Always mark as done (rc!=0 may still mean "no subtitles
    # present" — that is a valid outcome, not a failure).
    printf '%s\n' "$_path" >> "$QUEUE_DONE"

    if [ ! -f "$_srt" ]; then
        # ccextractor returned nothing — no .srt file at all.
        # Nothing to clean up. Log and move on.
        echo "$(date -Iseconds) EMPTY no .srt produced (ccextractor returned nothing): $_path" >> "$LOG"
    elif [ "$(stat -c %s "$_srt" 2>/dev/null || echo 0)" -lt "$MIN_SRT_BYTES" ]; then
        # Sub-threshold file: source had no real DVB subtitles
        # (typically a 3-byte UTF-8 BOM, or a single empty cue).
        # Delete the stub so we don't litter the recordings tree
        # with empty placeholders. The path is still in our
        # done-list, so we won't try again on subsequent drains.
        rm -f "$_srt"
        echo "$(date -Iseconds) EMPTY .srt below ${MIN_SRT_BYTES}B (likely no DVB subs in source) — deleted stub: $_srt" >> "$LOG"
    else
        echo "$(date -Iseconds) OK .srt generated $(stat -c %s "$_srt" 2>/dev/null) bytes: $_srt" >> "$LOG"
    fi
}

# -------------------------------------------------------------------
# watch — tail comskip-queue.done forever, process each new line.
# -------------------------------------------------------------------
watch() {
    exec 9>"$LOCK"
    if ! flock -n 9; then
        echo "$(date -Iseconds) ccextract-pool already running, exiting" >> "$LOG"
        return 0
    fi

    echo "$(date -Iseconds) ccextract-pool started (watch)" >> "$LOG"

    # tail -F -n 0 follows new lines as they are appended. The
    # pipeline's while-loop runs in a subshell because of the pipe;
    # process_line is a POSIX-sh function visible inside the same
    # script, so the subshell copy works without `export -f`.
    tail -F -n 0 "$TRIGGER_DONE" 2>/dev/null | while IFS= read -r line; do
        process_line "$line"
    done
}

# -------------------------------------------------------------------
# drain — read every path that we haven't yet processed from the
# trigger done-list, exit when done.
#
# Why drain the trigger done-list (not a separate queue)? Because
# comskip's done-list IS our queue — every line there is a .ts that
# has finished commercial-detection. We need to know which of those
# we have already processed (cc-extract-queue.done) and which we
# haven't. On a container restart after a QNAP reboot, we may have
# missed lines that arrived while cc-extract was down; drain
# catches up.
# -------------------------------------------------------------------
drain() {
    exec 9>"$LOCK"
    if ! flock -n 9; then
        echo "$(date -Iseconds) ccextract-pool drain: already running, exiting" >> "$LOG"
        return 0
    fi

    if [ ! -f "$TRIGGER_DONE" ]; then
        echo "$(date -Iseconds) ccextract-pool drain: trigger done-list missing" >> "$LOG"
        return 0
    fi

    # Snapshot current trigger done-list length — lines appended
    # after this snapshot will be picked up by the watch loop that
    # entrypoint.sh starts immediately after drain returns.
    _total=$(wc -l < "$TRIGGER_DONE" 2>/dev/null | tr -d ' ')
    _total=${_total:-0}
    if [ "$_total" = "0" ]; then
        echo "$(date -Iseconds) ccextract-pool drain: trigger empty" >> "$LOG"
        return 0
    fi

    # Compute the diff via temp files — dash (Debian Bullseye's
    # /bin/sh) does not support process substitution <(...), so
    # we route through /pvr/tmp scratch space. The temp files are
    # recreated every drain call and removed on exit.
    _diff_tmp="/pvr/tmp/cc-extract-diff.$$"
    trap 'rm -f "$_diff_tmp" "$_diff_tmp.2"' EXIT
    sort -u "$TRIGGER_DONE" > "$_diff_tmp.2" 2>/dev/null || : > "$_diff_tmp.2"
    sort -u "$QUEUE_DONE"   > "$_diff_tmp"   2>/dev/null || : > "$_diff_tmp"
    _unprocessed=$(comm -23 "$_diff_tmp.2" "$_diff_tmp" 2>/dev/null | wc -l | tr -d ' ')
    _unprocessed=${_unprocessed:-0}
    echo "$(date -Iseconds) ccextract-pool drain: trigger $_total total, $_unprocessed unprocessed" >> "$LOG"

    # Iterate the diff. comm gives sorted unique entries; we feed
    # them into process_line in order. Paths appended to the
    # trigger done-list after this snapshot will be picked up by
    # the watch loop that entrypoint.sh starts immediately after.
    #
    # We route through a temp file again because dash does not
    # support <(...) process substitution either.
    comm -23 "$_diff_tmp.2" "$_diff_tmp" 2>/dev/null > "$_diff_tmp.work" || : > "$_diff_tmp.work"
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        process_line "$path"
    done < "$_diff_tmp.work"
    rm -f "$_diff_tmp" "$_diff_tmp.2" "$_diff_tmp.work"
    trap - EXIT

    echo "$(date -Iseconds) ccextract-pool drain: complete" >> "$LOG"
}

# -------------------------------------------------------------------
# prune-done — drop entries from our done-list whose source no
# longer exists. Run on container start so the done-list does not
# grow unboundedly when recordings are deleted by the operator.
#
# Trade-off: pruning allows a later recording with the same path
# to be re-processed. This is intentional — if the user deleted a
# recording and the same path is later reused for a fresh
# recording, we want cc-extract to run on the new file rather than
# silently skip it.
# -------------------------------------------------------------------
prune_done() {
    exec 9>"$LOCK"
    if ! flock -n 9; then
        echo "$(date -Iseconds) ccextract-pool prune-done: already running, exiting" >> "$LOG"
        return 0
    fi

    if [ ! -s "$QUEUE_DONE" ]; then
        echo "$(date -Iseconds) ccextract-pool prune-done: done-list empty" >> "$LOG"
        return 0
    fi

    _tmp="${QUEUE_DONE}.tmp.$$"
    # Touch up-front so the mv below always has a source even when
    # no entries are dropped (otherwise set -e kills the script on
    # an empty $_tmp).
    : > "$_tmp"
    _kept=0
    _dropped=0
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        if [ -f "$path" ]; then
            printf '%s\n' "$path" >> "$_tmp"
            _kept=$((_kept + 1))
        else
            _dropped=$((_dropped + 1))
        fi
    done < "$QUEUE_DONE"

    mv "$_tmp" "$QUEUE_DONE"
    echo "$(date -Iseconds) ccextract-pool prune-done: kept $_kept, dropped $_dropped (source missing)" >> "$LOG"
}

# -------------------------------------------------------------------
# cleanup-orphans — find .srt files under the recordings tree whose
# .ts source is gone, and delete them.
#
# cc-extract writes <basename>.srt next to the .ts it processed.
# When TVH removes the .ts via its removal-days sweep, the .srt
# becomes an orphan that nothing else cleans up. Jellyfin won't
# display subtitles for a missing recording, but the orphan files
# still eat disk space and clutter directory listings.
#
# This subcommand is invoked by cron (see entrypoint.sh + the
# CLEANUP_CRON env var). It runs once and exits. Uses its own
# lock file (CLEANUP_LOCK) so it does not contend with the watch
# loop's LOCK — same reason as comskip's cleanup-orphans.
#
# Scope: only .srt files. Other sidecars (.edl/.txt/.sm) belong
# to comskip and are cleaned by comskip's own cleanup-orphans,
# not here. Keeping the responsibilities split avoids coupling
# the two containers through filesystem state they don't own.
# -------------------------------------------------------------------
cleanup_orphans() {
    _cleanup_lock="/pvr/tmp/cc-extract-cleanup.lock"
    mkdir -p "$(dirname "$_cleanup_lock")"
    exec 9>"$_cleanup_lock"
    if ! flock -n 9; then
        echo "$(date -Iseconds) ccextract-pool cleanup-orphans: already running, exiting" >> "$LOG"
        return 0
    fi

    _root="/recordings"
    if [ ! -d "$_root" ]; then
        echo "$(date -Iseconds) ccextract-pool cleanup-orphans: $_root missing, nothing to do" >> "$LOG"
        return 0
    fi

    # Walk the tree once, pattern-match .srt, stat the sibling .ts,
    # unlink orphans. Same performance characteristics as the
    # comskip equivalent.
    find "$_root" -maxdepth 5 -type f -name '*.srt' 2>/dev/null \
    | while IFS= read -r _sidecar; do
        _base="${_sidecar%.*}"
        _ts="${_base}.ts"
        if [ ! -f "$_ts" ]; then
            _size=$(wc -c < "$_sidecar" 2>/dev/null | tr -d ' ')
            _size=${_size:-0}
            rm -f "$_sidecar"
            echo "$(date -Iseconds) ccextract-pool cleanup-orphans: removed orphan .srt $_sidecar (${_size}B)" >> "$LOG"
        fi
    done

    _removed=$(grep -c "ccextract-pool cleanup-orphans: removed orphan" "$LOG" 2>/dev/null || echo 0)
    _removed=${_removed:-0}
    echo "$(date -Iseconds) ccextract-pool cleanup-orphans: complete (lifetime total: $_removed orphan .srt(s) removed; this run may have added several)" >> "$LOG"
}

# Dispatch.
case "$CMD" in
    watch)         watch ;;
    drain)         drain ;;
    prune-done)    prune_done ;;
    cleanup-orphans) cleanup_orphans ;;
    *)
        echo "$(date -Iseconds) ccextract-pool: unknown subcommand '$CMD' (use watch|drain|prune-done|cleanup-orphans)" >> "$LOG"
        exit 2
        ;;
esac
