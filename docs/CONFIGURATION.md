# Configuration Reference

This document lists every knob the PVR stack exposes, organised by file.
All paths below are paths on the Docker host unless prefixed
`/etc/...`, `/comskip/...`, `/transcoder/...`, or `/pvr/...`, which are
paths inside a container.

## `.env`

Secrets, network topology, and per-container environment. Excluded
from Git — copy from `.env.example` and fill in.

| Variable           | Used by                  | Purpose                                                                  |
|--------------------|--------------------------|--------------------------------------------------------------------------|
| `DATA`             | compose, all services    | Root directory for all PVR project data on the host                       |
| `TZ`               | all services             | IANA timezone, e.g. `Europe/Helsinki`                                    |
| `LOCAL_IPV4_1`     | tvheadend                | Fixed LAN IP for the TVH container on the `eth1` macvlan network          |
| `LOCAL_IPV4_2`     | jellyfin                 | Fixed LAN IP for the Jellyfin container                                   |
| `ADMIN_USER`       | TVH init                 | TVH web UI username, written to its `passwd` file on first boot only      |
| `ADMIN_PASSWORD`   | TVH init                 | TVH web UI password, written to its `passwd` file on first boot only       |
| `API_KEY`          | transcode (NFO generator)| Jellyfin API key, used by `generate-nfo.py` to query recording metadata   |
| `INTERVAL_SECONDS` | examples/epg-grabber     | Optional EPG grabber interval, ignored if that example is not deployed    |
| `TRANSCODE_CRON`   | transcode service        | Cron expression for the transcode pool (`0 * * * *` by default = hourly)  |
| `PVR_HOST_PREFIX`  | TVH post-recording       | When TVH invokes the hook with a host path, strip this prefix; default    |
|                    |                          | `/share/Programs/pvr/media` so the hook normalises host paths to            |
|                    |                          | `/recordings/...` inside the container                                    |
| `PVR_LOG_PATH`     | TVH post-recording       | Log path the hook writes to inside the TVH container, e.g.                 |
|                    |                          | `/config/dvr/log/post-recording.log`                                      |

The `COMSKIP_WORKERS` and `TRANSCODE_WORKERS` knobs that appeared in
earlier revisions have been removed. Both pools now drain the queue
single-threaded inside their own container (`flock` lockfile at
`/pvr/tmp/<name>.lock`). Scaling is done by adding more containers,
not more workers per container.

The removed `TRANSCODE_WORKERS` knob is replaced by FFmpeg's own
multi-threading:
  - `-threads 0` (decoder/demuxer/muxer pool),
  - `-filter_threads 0` (filter graph pool),
  - libx264 `-threads 0` (frame-level parallelism).

On a J1900 (4 cores, 2 threads/core = 8 logical), this means one
transcode fully utilises the host without contending with comskip or
the TVH DVB demuxer.

## `compose.yml`

The single source of truth for service topology. Important pieces:

### `tvheadend`

- mounts `${DATA}/media/recordings:/recordings:rw` so post-recording
  has access to the file TVH just wrote,
- mounts `${DATA}/comskip/queue:/comskip/queue:rw` and
  `${DATA}/transcoder/queue:/transcoder/queue:rw` so the post-recording
  hook can append to both,
- mounts `${DATA}/scripts:/pvr/scripts:ro` so the post-recording
  hook lives on the host, edits take effect on next restart, and
  the script cannot be tampered with from inside the container,
- mounts `${DATA}/scripts/config-loader.sh:/usr/local/bin/config-loader.sh:ro`,
  the path `post-recording.sh` does `. /usr/local/bin/config-loader.sh`,
- mounts `${DATA}/scripts/tvh-healthcheck.sh:/usr/local/bin/tvh-healthcheck.sh:ro`,
  the `healthcheck` probe,
- mounts `${DATA}/tmp:/pvr/tmp` so locks, FFmpeg-logs and the
  channel-name list live on the big volume, not in the host's 64 MB
  ramdisk,
- mounts `${DATA}/tvheadend/config:/config:rw` for TVH's own runtime,
- mounts `/dev/dvb` directly. The container runs `privileged: true`
  for that access; nothing else inside the container needs it.

### `jellyfin`

- mounts `${DATA}/media/recordings:/recordings:ro` so Jellyfin can
  play the originals,
- mounts `${DATA}/media/transcoded:/media/transcoded:ro` so it picks
  up the new MP4s (and the `.nfo` / `.edl` sidecars),
- mounts `/dev/dri` for hardware acceleration when present (the
  default `compose.yml` has it; if the host has no Intel/AMD GPU,
  Jellyfin will silently fall back to software decoding).

### `comskip`

- mounts `${DATA}/media/recordings:/recordings:ro` so it can read the
  `.ts` files,
- mounts `${DATA}/comskip/etc:/etc/comskip:ro` so the on-host
  `config.yaml` and `comskip.ini` win on container restart without
  a rebuild,
- mounts `${DATA}/comskip/queue:/comskip/queue:rw` for the queue and
  the `comskip.log`,
- mounts `${DATA}/tmp:/pvr/tmp` for the lock and channels list,
- mounts `${DATA}/tvheadend/config/dvr/log:/config/dvr/log:ro` (only
  in legacy revisions; the current comskip pool reads TVH logs only
  through hostside paths if needed).

### `transcode`

- mounts `${DATA}/media/recordings:/recordings:ro`,
- mounts `${DATA}/media/transcoded:/media/transcoded:rw` (output),
- mounts `${DATA}/transcoder/scripts:/etc/transcoder:ro`,
- mounts `${DATA}/transcoder/queue:/transcoder/queue:rw`,
- mounts `${DATA}/tmp:/pvr/tmp` for the lockfile and FFmpeg stderr
  dumps,
- mounts `${DATA}/tvheadend/config/dvr/log:/config/dvr/log:ro`
  so `generate-nfo.py` can read the TVH DVR log to parse title, plot
  and schedule.

### Networks

- `eth1` — external macvlan, declared in `compose.yml` as
  `external: true`. TVH and Jellyfin attach here to get fixed LAN IPs.
  Create on the host before `docker compose up -d`.
- `pvr_internal` — internal bridge (subnet `172.25.0.0/16`,
  `internal: true`). Comskip and transcode live here. There is no
  route out of the host; they only need to read the bind-mounted
  recordings and queues.

### `build.sh`

The repo ships a helper that builds the three local images in the
correct order:

```bash
./build.sh            # cached, normal incremental build
./build.sh --no-cache # full rebuild, slower but guarantees clean layers
```

The script resolves `PROJECT_DIR` from `$0` so it can be invoked from
anywhere and still build the right context.

## `comskip/etc/config.yaml`

Drives the comskip container's runtime behaviour. Parsed at startup
by `pvr-config-loader.sh` (a shell-only YAML reader, baked into the
image at `/usr/local/bin/`).

```yaml
comskip_binary: /usr/local/bin/comskip
comskip_ini:    /etc/comskip/comskip.ini

nice_level: 19

log:  /comskip/queue/comskip.log
done: /comskip/queue/comskip-queue.done

# Where comskip's own stdout AND stderr go. Comskip emits per-frame
# progress on stderr; default discards both. Set to a real file path
# to capture it for debugging.
progress_log: /dev/null

commercial_free_channels:
  - Yle TV1
  - Yle TV2
  - Yle Teema & Fem
  - Yle Areena
```

Edit on the host; `docker compose restart comskip` for changes to take
effect.

## `comskip/etc/comskip.ini`

Comskip's detection thresholds. Read once when Comskip starts. Two
parts are worth tuning for Finnish DVB-T broadcasts:

- `logo_threshold` and `logo_percentile` — Comskip uses these to
  detect the broadcaster's logo during commercial breaks. If it
  over- or under-detects on a particular channel, override the
  `tune_*` values for that channel.
- `edl_skip_field` — set to `2` (skip non-key frames) for smoother
  Jellyfin playback.

Do not edit `output_edl`. It is always on. Without it Comskip would
not write a `.edl` and Jellyfin would have nothing to skip against.

## `transcoder/scripts/config.yaml`

Drives the transcode container's runtime behaviour. The bulk of the
file is the profile table. Full reference lives in
[`PROFILES.md`](./PROFILES.md). The fragment below is the non-profile
overhead.

```yaml
# Default profile when a queue line has no explicit "profile" field.
default_profile: preservation

# Process priority for ffmpeg (higher = nicer to other workloads).
global:
  nice_level: 19

# FFmpeg / libx264 multi-threading inside this container.
# Three knobs so each subsystem can be tuned:
#   threads          ffmpeg's decoder/demuxer/muxer pool
#   filter_threads   filter graph pool (scale, etc.)
#   libx264_threads  x264 frame-level parallelism
global:
  threads: 0
  filter_threads: 0
  libx264_threads: 0

# Jellyfin NFO + sidecar handling.
nfo_generator: /etc/transcoder/generate-nfo.py
copy_edl:      true
copy_txt:      true
copy_log:      false

# Built-in size-triggered log rotation.
log: /var/log/transcode-nightly.log
log_max_kb: 1024
log_keep: 5

done: /transcoder/queue/transcode-queue.done

# Crontab expression for the pool — overridable from .env.
cron: "0 * * * *"
```

## `scripts/config.yaml` (TVH post-recording hook)

Drives `post-recording.sh` inside the TVH container. Parsed at
invocation time by `config-loader.sh`.

```yaml
paths:
  host_prefix:      "/share/Programs/pvr/media"
  container_prefix: "/recordings"

log:
  path: "/config/dvr/log/post-recording.log"

steps:
  comskip:
    enable: true
    queue:  "/comskip/queue/comskip-queue.jsonl"

  transcode:
    enable: true
    queue:  "/transcoder/queue/transcode-queue.jsonl"
```

`paths.host_prefix` is the host prefix TVH should normalise away
before it appends to either queue. Leave it empty if TVH already
writes the container-side path.

Set `steps.<name>.enable: false` to skip a step. The post-recording
hook only appends to queues with `enable: true`.

## `scripts/config-loader.sh`

A shell-only YAML reader. Sourced via `. /usr/local/bin/config-loader.sh`
from `post-recording.sh`. Supports the subset of YAML the project
actually uses (key: value, dotted-path nesting, lists). No python,
no `python3-yaml`. If a key is missing the loader falls back to the
default that `load_config_eval` was called with.

The same parser is baked into the comskip and transcode images at
`/usr/local/bin/pvr-config-loader.sh`. The two files are identical;
they live at different on-disk paths so the TVH side can be patched
without rebuilding the worker images.

## Cron

Each container has its own cron job:

| Container | Schedule            | Command                                                       |
|-----------|---------------------|---------------------------------------------------------------|
| comskip   | (none)              | — Comskip follows the queue in real time, no cron needed.       |
| transcode | `${TRANSCODE_CRON}` | `/etc/transcoder/transcode-pool.sh >> /var/log/...log 2>&1`     |

`TRANSCODE_CRON` is a standard five-field cron expression (minute,
hour, day, month, weekday). The default `0 * * * *` is hourly. For
nightly off-peak use `0 2 * * *`.

The container's `entrypoint.sh` installs the cron entry on top of the
in-image default, so changes to `TRANSCODE_CRON` in `.env` do not
require a rebuild — they take effect on the next container restart.
