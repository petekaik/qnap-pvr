# Transcode Profiles

The transcode container exposes four profiles. Each profile is a
complete FFmpeg invocation plan: video codec, preset, tune, CRF,
pixel format, optional scale filter, audio codec, and subtitle
handling.

A profile is selected per queue line by adding a `"profile": "<name>"`
field to the JSONL line. If no field is present, the value of
`default_profile` from `transcoder/scripts/config.yaml` is used.

```json
{"path":"/recordings/Show/Show_2026-06-29_20-00.ts","added":"...","profile":"web_720p"}
```

This document covers each profile in detail and the rules that apply
to all of them.

## Rules that apply to every profile

### Multi-stream mapping

`-map 0` is **not** used. It tries to copy data streams (EPG, teletext,
unknown) which MP4 cannot carry and fails with
`Could not find tag for codec dvb_teletext in container`. Instead, the
pool emits one `ffmpeg -map` per stream type, each with the `?`
modifier so missing streams are silently skipped.

```
-map 0:v?      # every video stream
-map 0:a?      # every audio stream  (only when audio.codec is copy)
-map 0:a:0    # single best audio  (any re-encode)
-map 0:s?      # every subtitle stream (only when strategy is "inline"
                # and the source has at least one text-format subs)
```

### Subtitle handling

DVB sources can carry three kinds of subtitles:

  - `dvb_subtitle` — bitmap graphics. Cannot be carried in MP4 and
    cannot be OCR-extracted without `ccextractor` (not bundled).
  - `dvb_teletext` — same family, different codec name. Same
    restriction.
  - `mov_text` / `subrip` / `ass` / `ssa` / `webvtt` — text-format
    streams. Can be carried in MP4 unchanged.

The pool's `build_ffmpeg_cmd` runs `ffprobe -select_streams s` against
the source. If the source has only bitmap subs and the profile wants
inline subtitles, the pool emits `-sn` instead of `-c:s copy` and logs
a warning. If both bitmap and text subs are present, the text ones
are copied and the bitmap ones are silently dropped.

To extract DVB subs to a `.srt` file alongside the recording, install
`ccextractor` into the transcode container (Debian: `apt-get install
ccextractor`) and add a post-step to the pool that runs it on the
source `.ts`. The transcoder hook currently has no such step; the
right place for it is between the success branch of the FFmpeg
invocation and the sidecar copy.

### Audio handling

When `audio.codec = copy`:

  - All audio tracks in the source are mapped to the output. 5.1 DD
    stays 5.1 DD, not transrated to AAC stereo.
  - bitrate and channels settings are ignored (the stream carries
    its own metadata).
  - Jellyfin gets the original codecs and will pick the right track
    for the client (e.g. surround track on the living-room receiver,
    stereo track on a phone).

When `audio.codec != copy`, the re-encode applies to a single track
because per-track re-encoding with different bitrates per channel
configuration is ambiguous. Set codec to `copy` and let Jellyfin
transcode-on-the-fly if you need per-track re-encoding.

### FFmpeg argument construction

The pool builds argv as a newline-separated list, then re-emits it via
`awk` and `eval "set -- ..."` so single quotes, spaces, and colons
inside config values (a typical scale filter has all three) survive
the shell. Do not collapse the argument list into one quoted string;
that is the most common way to break the FFmpeg invocation. See
`transcode-pool.sh` `build_ffmpeg_cmd()` for the exact construction.

## Profile reference

### `preservation` (default)

Use when you want a Jellyfin-friendly MP4 with the minimum possible
loss compared to the broadcast. Recommended for archival.

```yaml
preservation:
  video:
    codec:    libx264
    preset:   slow
    tune:     film
    crf:      15
    pix_fmt:  yuv420p
    scale:    null
  audio:
    codec:    copy
    bitrate:  ""
    channels: 0
  subtitle:
    codec:    copy
    strategy: inline
  output_subdir: ""
  movflags:      "+faststart"
```

Notes:
  - CRF 15 is below the visibility threshold for 1080i/p H.264
    broadcast. The output is around 2–4x the size of CRF 23 for
    a typical TV show. On a J1900 with `-threads 0` enabled, expect
    roughly 25–35 min of encoding per 30 min of input.
  - `preset: slow` is slower than `medium` but uses better motion
    estimation. With `-threads 0` the parallel decode hides most of
    the cost on a 4-core host.
  - `audio.codec: copy` is the single most important knob for
    preserving 5.1 mixes. Any re-encode drops bitrate or channel
    layout.
  - Subtitles are `copy` by default, with the dvb_teletext/dvb_subtitle
    autodetection described above. If the source has only bitmap
    subs, the pool drops them and logs a warning.

### `high_quality`

Kept for backwards compatibility. Equivalent to `preservation` minus
the audio copy: audio is re-encoded to AAC stereo 192 kbps.

```yaml
high_quality:
  video:
    codec:    libx264
    preset:   medium
    tune:     film
    crf:      18
    pix_fmt:  yuv420p
    scale:    null
  audio:
    codec:    aac
    bitrate:  "192k"
    channels: 2
  subtitle:
    codec:    null
    strategy: drop
```

Use only if you know you want a single stereo track and do not care
about losing the original broadcast audio quality.

### `web_720p`

Downscale to 720p for clients with limited bandwidth. Still copies
audio so the source's surround mix survives.

```yaml
web_720p:
  video:
    codec:    libx264
    preset:   veryfast
    tune:     fastdecode
    crf:      28
    pix_fmt:  yuv420p
    scale:    "scale=w=1280:h=720:force_original_aspect_ratio=decrease"
  audio:
    codec:    copy
    bitrate:  ""
    channels: 0
  subtitle:
    codec:    copy
    strategy: inline
```

Notes:
  - Outputs go to `${DATA}/media/transcoded<output_subdir>/...`, with
    `output_subdir: "_720p"`. Configure Jellyfin to look at both
    paths as libraries so it can pick the best file per client.
  - `preset: veryfast` and `tune: fastdecode` together prioritise
    decode speed over compression efficiency. The output is twice
    the size of `medium` at the same CRF. That is the right trade-off
    for clients that only stream at 5–10 Mbit/s.
  - `scale: "scale=w=1280:h=720:force_original_aspect_ratio=decrease"`
    downscales to 720p, retaining the original aspect ratio by
    padding where the source isn't 16:9.

### `passthrough`

TS-to-MP4 remux with no re-encode. Fastest path, decoded video and
audio are byte-identical to the source.

```yaml
passthrough:
  video:
    codec:    copy
    scale:    null
  audio:
    codec:    copy
    bitrate:  ""
    channels: 0
  subtitle:
    codec:    copy
    strategy: inline
  output_subdir: "_passthrough"
```

Notes:
  - Subtitles are copied. If the source has dvb_teletext, the
    autodetection in `build_ffmpeg_cmd` will drop them, just as for
    the other copy-mode profiles.
  - `ffmpeg` may still rewrite H.264 SPS/PPS during the muxer step
    even when stream-copying video. The decoded output is
    byte-identical to the input, but a byte-level diff against the
    source `.ts` will differ. CRC32 of the bitstream matches.

## What does not work yet

- **DVB subtitle extraction** — `ccextractor` is not bundled in the
  container. If you want `.srt` sidecars for Finnish broadcasts,
  install it manually and add a hook to `transcode-pool.sh`. The pool
  already logs when subs are dropped for dvb_teletext/dvb_subtitle,
  so adding the hook is a small change.
- **Hardware acceleration** — `h264_qsv` / `h264_nvenc` are not
  configured because they are not available on a stock QNAP TS-X51
  (Celeron J1900, no QuickSync). The pool is set up so adding
  `video.codec: h264_qsv` and the matching `extra:` flags would Just
  Work on a host that has the appropriate Intel GPU exposed via
  `/dev/dri`.
