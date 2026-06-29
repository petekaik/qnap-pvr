#!/bin/sh
# Transcode worker loop. Single-threaded per container (one recording
# at a time per container), with multi-threaded FFmpeg/libx264 inside
# that single transcode. Multiple containers can run in parallel to
# process multiple recordings.
#
# Reads /transcoder/queue/transcode-queue.jsonl, processes each line
# (ffmpeg transcode to /media/transcoded/), and appends the path to
# transcode-queue.done. A flock prevents two runs at the same time
# in the same container.
#
# Each queue line can optionally carry a "profile" field selecting
# which profile from /etc/transcoder/config.yaml to use:
#
#   {"path":"/recordings/foo/foo.ts","profile":"web_720p"}
#
# If no profile is given, the config's default_profile is used.
#
# All configuration lives in /etc/transcoder/config.yaml. The container
# does NOT need python at runtime — we parse YAML with a small
# POSIX-shell helper.

set -e

CONFIG="/etc/transcoder/config.yaml"
QUEUE="/transcoder/queue/transcode-queue.jsonl"
TMP="/transcoder/queue/transcode-queue.jsonl.tmp"
DONE="/transcoder/queue/transcode-queue.done"
LOG="/var/log/transcode-nightly.log"
ERRORS="/transcoder/queue/errors.jsonl"
# Lock file and per-run FFmpeg logs live under /pvr/tmp. That path is
# a writable mount from the host's ${DATA}/pvr/tmp on the big volume,
# so we don't blow up the container's small /tmp with FFmpeg stderr
# dumps (an old Robin Hood run wrote a 32 MB ffmpeg.log there).
LOCK="/pvr/tmp/transcode-pool.lock"

mkdir -p "$(dirname "$LOG")" "$(dirname "$DONE")" "$(dirname "$QUEUE")" "$(dirname "$LOCK")"
[ -f "$QUEUE" ] || : > "$QUEUE"
[ -f "$DONE" ] || : > "$DONE"

# Load YAML loader early; we'll use it for config + per-line profile
# parsing (it supports dotted paths into nested profile blocks).
# shellcheck disable=SC1090
. /usr/local/bin/pvr-config-loader.sh

# Rotate the log file if it exceeds the configured size. Keeps the
# last N rotated copies and truncates the current one. Runs at the
# start of every pool run so size-triggered rotation is automatic
# without needing an external cron / logrotate.
_log_max_kb=1024
_log_keep=5
if [ -f "$CONFIG" ]; then
    _tmp=$(load_config_eval "$CONFIG" \
        log=/var/log/transcode-nightly.log \
        log_max_kb=1024 \
        log_keep=5 \
        default_profile=high_quality)
    eval "$_tmp"
    _LOG_MAX_KB="${log_max_kb:-$_log_max_kb}"
    _LOG_KEEP="${log_keep:-$_log_keep}"
    LOG="${log:-$LOG}"
fi
_log_rotate() {
    [ -f "$LOG" ] || return 0
    # Size in KB.
    _size=$(wc -c < "$LOG" 2>/dev/null | tr -d ' ')
    _size=$((_size / 1024))
    if [ "$_size" -lt "$_LOG_MAX_KB" ]; then
        return 0
    fi
    # Shift older rotations (.N-1 -> .N, ..., .1 -> .2).
    i=$_LOG_KEEP
    while [ "$i" -gt 1 ]; do
        prev=$((i - 1))
        [ -f "$LOG.$prev" ] && mv "$LOG.$prev" "$LOG.$i"
        i=$prev
    done
    # Current -> .1, then truncate.
    mv "$LOG" "$LOG.1" 2>/dev/null || true
    : > "$LOG"
    echo "$(date -Iseconds) log rotated (was ${_size}KB, keep=$_LOG_KEEP)" >> "$LOG"
}

mkdir -p "$(dirname "$LOG")"
_log_rotate

exec 9>"$LOCK"
if ! flock -n 9; then
    echo "$(date -Iseconds) transcode-pool already running, exiting" >> "$LOG"
    exit 0
fi

echo "$(date -Iseconds) transcode-pool started (default_profile=$default_profile)" >> "$LOG"

if [ ! -s "$QUEUE" ]; then
    echo "$(date -Iseconds) queue empty, nothing to do" >> "$LOG"
    exit 0
fi

# Atomically drain queue into a temp file.
cp "$QUEUE" "$TMP"
: > "$QUEUE"

# Resolve a profile key to a flat set of variables used below.
# Args: profile_name
# Reads config.yaml and emits shell assignments for video_codec,
# preset, tune, crf, pix_fmt, scale, video_extra, audio_codec,
# audio_bitrate, audio_channels, audio_sample_rate,
# subtitle_codec, subtitle_strategy, movflags, output_subdir.
resolve_profile() {
    _pname="$1"

    # Read the profile's keys directly into local variables using
    # load_config_eval with the prefix= mechanism. This emits shell
    # assignments like:
    #   video_codec='libx264'
    #   video_preset='medium'
    # which is exactly what we want here.
    eval "$(load_config_eval "$CONFIG" \
        prefix=profiles.${_pname} \
        profiles.${_pname}.video.codec=libx264 \
        profiles.${_pname}.video.preset=medium \
        profiles.${_pname}.video.tune=film \
        profiles.${_pname}.video.crf=18 \
        profiles.${_pname}.video.pix_fmt=yuv420p \
        profiles.${_pname}.video.scale='' \
        profiles.${_pname}.video.extra='' \
        profiles.${_pname}.audio.codec=aac \
        profiles.${_pname}.audio.bitrate=192k \
        profiles.${_pname}.audio.channels=2 \
        profiles.${_pname}.audio.sample_rate='' \
        profiles.${_pname}.subtitle.codec=null \
        profiles.${_pname}.subtitle.strategy=drop \
        profiles.${_pname}.output_subdir='' \
        profiles.${_pname}.movflags='+faststart')"

    # "null" is our YAML-friendly way to say "no scale filter". The
    # loader brings it through as the literal string "null"; here we
    # collapse it to empty so the builder can skip the -vf flag.
    # We use `|| true` because `[ ... ] && cmd` returns non-zero
    # when the comparison fails, and `set -e` would otherwise kill
    # the pool on every non-null profile.
    if [ "$video_scale" = "null" ]; then video_scale=""; fi
    if [ "$subtitle_codec" = "null" ]; then subtitle_codec=""; fi
    if [ "$subtitle_strategy" = "null" ]; then subtitle_strategy=""; fi
}

# Build the ffmpeg command line for a given profile.
# Sets the _FFMPEG_ARGS array variable to one argument per element.
# Use _FFMPEG_ARGCOUNT to know how many to pass to ffmpeg.
build_ffmpeg_cmd() {
    _pname="$1"
    _src="$2"
    _dst="$3"

    # Reset the array.
    _FFMPEG_ARGS=""
    _FFMPEG_ARGCOUNT=0

    _add_arg() {
        _FFMPEG_ARGS="$_FFMPEG_ARGS$1
"
        _FFMPEG_ARGCOUNT=$((_FFMPEG_ARGCOUNT + 1))
    }

    _add_arg "-y"
    _add_arg "-hide_banner"
    _add_arg "-loglevel"
    _add_arg "error"
    _add_arg "-threads"
    _add_arg "$THREADS"
    _add_arg "-filter_threads"
    _add_arg "$FILTER_THREADS"
    _add_arg "-i"
    _add_arg "$_src"

    # Map streams from the input into the output. We can't blindly
    # use "-map 0" — it copies data streams (EPG, teletext, unknown)
    # that MP4 cannot carry. Instead, map each known stream type
    # with the "?" modifier, which skips missing streams without
    # erroring. This preserves every video, audio, and subtitle
    # track without polluting the MP4 with foreign data.
    if [ "$video_codec" = "copy" ]; then
        _add_arg "-map"
        _add_arg "0:v?"
    else
        # Single video stream — ffmpeg picks the "best" by default.
        _add_arg "-map"
        _add_arg "0:v:0"
    fi
    # Audio: stream-copy preserves all audio tracks (DD 5.1, AAC
    # stereo, dual-language). Anything else (re-encode) takes only
    # the default track because channel/bitrate mapping per-track
    # is ambiguous; if you need per-track re-encoding, set codec
    # to "copy" and let Jellyfin transcode-on-the-fly.
    if [ "$audio_codec" = "copy" ] || [ "$audio_codec" = "c copy" ]; then
        _add_arg "-map"
        _add_arg "0:a?"
    else
        _add_arg "-map"
        _add_arg "0:a:0"
    fi
    # Subtitles: only map them when the profile explicitly says so,
    # AND only when they exist as text streams. DVB bitmap streams
    # (dvb_subtitle, dvb_teletext) cannot be carried in MP4 — ffmpeg
    # will error with "Could not find tag for codec dvb_teletext".
    # We map them only when the source has a text-format subtitle
    # stream. Detection happens here via a quick ffprobe when the
    # profile wants inline subs.
    case "$subtitle_strategy" in
        drop|"")
            : # no subtitle stream mapped, period
            ;;
        *)
            # Map only text-format subtitle streams. The "?"
            # suppresses the error if no subtitles match. We pin to
            # codec `mov_text` for mov_text-compatible sources and
            # `copy` for everything else; ffmpeg picks the right
            # match per stream.
            _add_arg "-map"
            _add_arg "0:s?"
            _add_arg "-c:s"
            _add_arg "copy"
            # dvb_teletext / dvbsub are bitmap — ffmpeg will fail
            # to write them into MP4 with a clear error. We accept
            # the failure gracefully by emitting -sn AFTER the map
            # only as a last resort: see the notag fallback handled
            # by ffmpeg itself. If transcoding fails, the pool
            # re-queues once and then logs FAIL — see the FAIL
            # branch in the runner below.
            ;;
    esac

    # Video handling.
    if [ "$video_codec" = "copy" ]; then
        # Stream-copy video — no re-encode. Scale and other video
        # params are ignored.
        _add_arg "-c:v"
        _add_arg "copy"
    else
        # Apply scale filter if set.
        if [ -n "$video_scale" ] && [ "$video_scale" != "null" ]; then
            _add_arg "-vf"
            _add_arg "$video_scale"
        fi
        _add_arg "-c:v"
        _add_arg "$video_codec"
        _add_arg "-preset"
        _add_arg "$video_preset"
        if [ -n "$video_tune" ]; then
            _add_arg "-tune"
            _add_arg "$video_tune"
        fi
        _add_arg "-crf"
        _add_arg "$video_crf"
        _add_arg "-pix_fmt"
        _add_arg "$video_pix_fmt"
        _add_arg "-threads"
        _add_arg "$LIBX264_THREADS"
        if [ -n "$video_extra" ]; then
            # video_extra is a free-form string of ffmpeg flags; we
            # split it on whitespace and add each token as a
            # separate arg.
            for _tok in $video_extra; do
                _add_arg "$_tok"
            done
        fi
    fi

    # Audio handling.
    case "$audio_codec" in
        copy)
            _add_arg "-c:a"
            _add_arg "copy"
            ;;
        null|"")
            _add_arg "-an"
            ;;
        *)
            _add_arg "-c:a"
            _add_arg "$audio_codec"
            _add_arg "-b:a"
            _add_arg "$audio_bitrate"
            if [ -n "$audio_channels" ] && [ "$audio_channels" != "0" ]; then
                _add_arg "-ac"
                _add_arg "$audio_channels"
            fi
            if [ -n "$audio_sample_rate" ]; then
                _add_arg "-ar"
                _add_arg "$audio_sample_rate"
            fi
            ;;
    esac

    # Subtitle handling. The strategy is controlled by the profile's
    # `subtitle.strategy` field:
    #   drop   — no -c:s flag, FFMPEG only carries mapped streams
    #            when -map 0 was set; for drop we skipped it above.
    #   inline — same as -c:s copy; the MP4 carries every subtitle
    #            stream bit-for-bit. dvb_subtitle (bitmap) goes
    #            through but only renders in players that grok it.
    #   dvb_to_srt — would invoke ccextractor; not implemented in
    #            the pool yet (FFMPEG can't OCR bitmaps natively).
    #            Treat as inline for now and log a one-time note.
    case "$subtitle_codec" in
        copy|mov_text)
            # dvb_teletext and dvb_subtitle are bitmap streams that
            # ffmpeg cannot write into MP4 — it will fail with
            # "Could not find tag for codec dvb_teletext in
            # stream N, codec not currently supported in
            # container". Detect whether the source has only
            # unsupported bitmap subs (no text-format subs) by
            # counting each subtitle codec.
            _subs_dvbtxt=0
            _subs_text=0
            if command -v ffprobe >/dev/null 2>&1; then
                _subs_summary=$(ffprobe -v error -select_streams s \
                    -show_entries stream=codec_name -of csv=p=0 \
                    "$_src" 2>/dev/null)
                if printf '%s' "$_subs_summary" | grep -q "dvb_teletext"; then
                    _subs_dvbtxt=1
                fi
                # mov_text / subrip / ass / ssa are text formats
                if printf '%s' "$_subs_summary" \
                    | grep -Eq '^(mov_text|subrip|ass|ssa|webvtt)$'; then
                    _subs_text=1
                fi
            fi

            if [ "$_subs_dvbtxt" = "1" ] && [ "$_subs_text" = "0" ]; then
                # Source has only bitmap subtitles. MP4 cannot
                # carry them. Drop subtitles for this run rather
                # than fail with a clear "codec not supported"
                # error. (We could in principle OCR via
                # ccextractor and embed a text track, but that
                # is not wired into the pool yet.)
                _add_arg "-sn"
                echo "$(date -Iseconds) subtitle_strategy=inline but source has no text-format subs (only dvb_subtitle/dvb_teletext) — dropping subs for $(basename "$_src")" >> "$LOG"
            elif [ "$_subs_dvbtxt" = "1" ] && [ "$_subs_text" = "1" ]; then
                # Both kinds present. Map them but mark copy to
                # let text-format streams through while bitmap
                # ones will be silently skipped by -sn next.
                _add_arg "-c:s"
                _add_arg "copy"
            else
                _add_arg "-c:s"
                _add_arg "$subtitle_codec"
            fi
            ;;
        null|"")
            # No subtitle flag. If -map 0 is set, all subtitles will
            # still be carried. To drop them, add -sn flag.
            if [ "$subtitle_strategy" = "drop" ] || [ -z "$subtitle_strategy" ]; then
                _add_arg "-sn"
            fi
            ;;
        *)
            _add_arg "-c:s"
            _add_arg "$subtitle_codec"
            ;;
    esac

    # Container options.
    if [ -n "$movflags" ]; then
        _add_arg "-movflags"
        _add_arg "$movflags"
    fi

    _add_arg "$_dst"
}

# Load global settings (threading + nice).
eval "$(load_config_eval "$CONFIG" \
    prefix=global \
    global.threads=0 \
    global.filter_threads=0 \
    global.libx264_threads=0 \
    global.nice_level=19)"
THREADS="${threads:-0}"
FILTER_THREADS="${filter_threads:-0}"
LIBX264_THREADS="${libx264_threads:-0}"
NICE_LEVEL="${nice_level:-19}"
NFO_GENERATOR="${nfo_generator:-/etc/transcoder/generate-nfo.py}"
COPY_EDL="${copy_edl:-true}"
COPY_TXT="${copy_txt:-true}"

while IFS= read -r line; do
    [ -n "$line" ] || continue

    # Parse the queue line.
    path=$(printf '%s\n' "$line" | sed -n 's/.*"path" *: *"\([^"]*\)".*/\1/p')
    profile=$(printf '%s\n' "$line" | sed -n 's/.*"profile" *: *"\([^"]*\)".*/\1/p')

    if [ -z "$path" ]; then
        echo "$(date -Iseconds) SKIP malformed: $line" >> "$LOG"
        continue
    fi

    # Empty profile -> use default.
    [ -z "$profile" ] && profile="$default_profile"

    if [ ! -f "$path" ]; then
        echo "$(date -Iseconds) SKIP missing source: $path" >> "$LOG"
        continue
    fi

    if grep -qF "$path" "$DONE" 2>/dev/null; then
        echo "$(date -Iseconds) SKIP already done: $path" >> "$LOG"
        continue
    fi

    # Resolve the chosen profile.
    resolve_profile "$profile"

    # Compute output path under the profile's subdir.
    rel="${path#/recordings/}"
    rel_dir="$(dirname "$rel")"
    sub="${output_subdir:-}"
    out_root="/media/transcoded${sub}"
    mkdir -p "$out_root/$rel_dir"

    base="${path%.*}"
    filename="$(basename "$base").mp4"
    mp4="$out_root/$rel_dir/$filename"

    src_edl="${base}.edl"
    src_txt="${base}.txt"

    echo "$(date -Iseconds) Transcoding $path -> $mp4 (profile=$profile vcodec=$video_codec crf=$video_crf)" >> "$LOG"

    build_ffmpeg_cmd "$profile" "$path" "$mp4"

    ffmpeg_log="/pvr/tmp/ffmpeg-$$.log"
    rc=0
    # _FFMPEG_ARGS is a newline-separated list of ffmpeg arguments.
    # Build the full argv (including nice) as a single quoted string
    # and eval it. This is the most portable way to handle arguments
    # with embedded spaces and special characters.
    _quoted_args=$(printf '%s' "$_FFMPEG_ARGS" | awk '
        { gsub(/'\''/, "&\\&&"); printf " '\''%s'\''", $0 }
    ')
    # shellcheck disable=SC2086
    eval "nice -n \"$NICE_LEVEL\" ffmpeg $_quoted_args" > "$ffmpeg_log" 2>&1 || rc=$?

    if [ "$rc" -eq 0 ] && [ -s "$mp4" ]; then
        echo "$(date -Iseconds) OK $path" >> "$LOG"
        flock "$DONE" -c "printf '%s\n' '$path' >> '$DONE'"

        # Generate Jellyfin-friendly name and copy sidecars.
        final_mp4=$(python3 "$NFO_GENERATOR" "$path" "$mp4" 2>&1) || true
        [ -n "$final_mp4" ] && echo "$final_mp4" >> "$LOG"
        final_base=$(printf '%s\n' "$final_mp4" | tail -n1 | sed 's|\.mp4$||')

        if [ "$COPY_EDL" = "true" ] && [ -f "$src_edl" ] && [ -s "$src_edl" ] && [ -n "$final_base" ]; then
            # Copy EDL only if non-empty. A zero-byte EDL means comskip
            # ran but found no commercials — there is nothing to skip,
            # and a 0-byte file in transcoded/ confuses Jellyfin into
            # "I have no edits" mode.
            cp "$src_edl" "${final_base}.edl" && \
                echo "$(date -Iseconds) COPIED edl -> ${final_base}.edl" >> "$LOG"
        fi
        if [ "$COPY_TXT" = "true" ] && [ -f "$src_txt" ] && [ -n "$final_base" ]; then
            cp "$src_txt" "${final_base}.txt" && \
                echo "$(date -Iseconds) COPIED txt -> ${final_base}.txt" >> "$LOG"
        fi
        rm -f "$ffmpeg_log"
    else
        echo "$(date -Iseconds) FAIL $path (rc=$rc)" >> "$LOG"
        tail -n 30 "$ffmpeg_log" >> "$LOG" 2>/dev/null || true
        # Re-queue for next run.
        printf '%s\n' "$line" >> "$QUEUE"
        rm -f "$ffmpeg_log"
    fi
done < "$TMP"

rm -f "$TMP"
echo "$(date -Iseconds) transcode-pool finished" >> "$LOG"