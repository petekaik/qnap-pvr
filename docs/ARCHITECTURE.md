# Architecture

This document describes the PVR stack using the [C4 model](https://c4model.com/).
The system runs on a low-power Docker host (QNAP TS-X51, Celeron J1900)
where CPU-intensive work must be split into independent units.

## Context (C4 Level 1)

A household records free-to-air DVB-T/T2 broadcasts and watches them
on local network clients.

```
┌──────────────┐     DVB-T/T2     ┌─────────────────────────────────────┐
│  Antenna     │─────────────────▶│  PVR Stack (Docker on QNAP/NAS)     │
└──────────────┘                  │                                     │
                                 │  TVHeadend, Jellyfin, comskip,      │
┌──────────────┐                  │  transcode                          │
│  Home users  │◀─────────────────│                                     │
│  (clients)   │  HTTP / DLNA /  │  Live TV, recordings, transcoded,    │
│              │  HTSP            │  with commercial-skip metadata     │
└──────────────┘                  └─────────────────────────────────────┘
```

## Containers (C4 Level 2)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Docker Host                                    │
│                                                                             │
│  ┌────────────────────────┐    ┌────────────────────────┐                    │
│  │  External macvlan      │    │  Internal bridge        │                    │
│  │  (network "eth1")      │    │  (network "pvr_internal"│                    │
│  │                        │    │   internal: true)       │                    │
│  │  ┌──────────────────┐  │    │  ┌──────────────────┐  │                    │
│  │  │   tvheadend      │  │    │  │     comskip     │  │                    │
│  │  │  192.168.1.52   │  │    │  │   (pvr-comskip) │  │                    │
│  │  │                  │  │    │  │                  │  │                    │
│  │  │ Records DVB-T    │  │    │  │ tail -F queue    │  │                    │
│  │  │ Runs post-       │  │    │  │ single-thread   │  │                    │
│  │  │ processor hook   │  │    │  │ nice 19          │  │                    │
│  │  └────────┬─────────┘  │    │  └─────────┬────────┘  │                    │
│  │           │            │    │            │           │                    │
│  │  ┌────────▼─────────┐  │    │  ┌─────────▼────────┐  │                    │
│  │  │    jellyfin      │  │    │  │    transcode     │  │                    │
│  │  │  192.168.1.53   │  │    │  │ (pvr-transcode)  │  │                    │
│  │  │                  │  │    │  │                  │  │                    │
│  │  │ Live TV +        │  │    │  │ Drain queue      │  │                    │
│  │  │ recordings       │  │    │  │ Profile-based    │  │                    │
│  │  │ (HTSP, DLNA, web)│  │    │  │ FFmpeg           │  │                    │
│  │  └──────────────────┘  │    │  └──────────────────┘  │                    │
│  └────────────────────────┘    └────────────────────────┘                    │
│                                                                             │
│                        Shared host volumes                                  │
│                                                                             │
│    ${DATA}/media/recordings      ──┬── /recordings                           │
│    ${DATA}/media/transcoded      ──┼── /media/transcoded                     │
│    ${DATA}/comskip/queue/        ──┤                                        │
│    ${DATA}/transcoder/queue/     ──┤                                        │
│    ${DATA}/transcoder/scripts/   ──┤   /etc/transcoder                       │
│    ${DATA}/scripts/post-recording.sh                                      │
│                                    ──  /pvr/scripts/post-recording.sh       │
│    ${DATA}/scripts/config-loader.sh                                       │
│                                    ──  /usr/local/bin/config-loader.sh       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Build-time layering

The two specialised worker images (`pvr-comskip`, `pvr-transcode`)
share a base layer so packages only install once.

```
                    Debian + ffmpeg + python3 + cron
                    ┌─────────────────────────┐
                    │       pvr-base           │
                    └────────────┬────────────┘
                                 │
                ┌────────────────┴────────────────┐
                │                                 │
       ┌─────────▼─────────┐          ┌───────────▼───────────┐
       │   pvr-comskip    │          │   pvr-transcode      │
       │                  │          │                      │
       │ comskip binary   │          │ transcode-pool.sh    │
       │ comskip-pool.sh  │          │ generate-nfo.py      │
       │ pvr-config-loader│          │ pvr-config-loader    │
       └──────────────────┘          └──────────────────────┘
```

`pvr-base` is not a service. It exists only as a Docker layer cache,
controlled by `./build.sh`. Without it, every `pvr-comskip` rebuild
would re-install Debian packages.

## Recording and post-processing flow

```
┌───────────────┐
│ TVHeadend     │
│ records .ts   │
└──────┬────────┘
       │ recording finishes
       ▼
┌──────────────────────────────────────────────────────┐
│ TVH invokes                                       ──▶│ /pvr/scripts/post-recording.sh %f
│                                                   │   │
│                                                   │   ├─ resolves truncated %f via
│                                                   │   │   resolve_ts()  (TVH drops the
│                                                   │   │    path at the first space in
│                                                   │   │    long show titles)
│                                                   │   │
│                                                   │   ├─ appends one JSONL line to
│                                                   │   │   /comskip/queue/comskip-queue.jsonl
│                                                   │   │
│                                                   │   └─ appends one JSONL line to
│                                                       /transcoder/queue/transcode-queue.jsonl
│
│
├──► /comskip/queue/comskip-queue.jsonl  (real time)
│
├──► /transcoder/queue/transcode-queue.jsonl  (cron, hourly)
│
▼
```

### Comskip pipeline (real-time)

```
comskip-pool.sh starts on container boot.
│
├── acquires flock on /pvr/tmp/comskip-pool.lock
│
├── tail -F -n 0 /comskip/queue/comskip-queue.jsonl
│   (waits for new lines forever)
│
└── for each new line:
    │
    ├── path="/recordings/Show/Show.ts"
    │   ├─ already in .done?  ─▶ SKIP already done
    │   ├─ file missing?      ─▶ SKIP missing source
    │   └─ channel "Yle TV1"? ─▶ SKIP commercial-free channel
    │
    ├── output: RUN comskip <path>
    │   nice -n 19 /usr/local/bin/comskip
    │           --ini=/etc/comskip/comskip.ini
    │           --output=<dir>
    │           <path>
    │           >> "$PROGRESS_LOG" 2>&1   (default /dev/null)
    │
    └── exit code:
        ├─ 0  ─ OK comskip, write path to .done
        │        (EDL was generated if commercials found)
        ├─ 1  ─ "Commercials were not found" — same as 0
        └─ >1 ─ FAIL comskip, write path to .done anyway
              (so a corrupt source does not block the queue)
```

The pool only processes new queue lines — once an EDL exists for a
recording, future TVH restart that re-adds the same line does not
re-run Comskip on it. This is the idempotency guarantee.

### Transcode pipeline (cron-driven)

```
At TRANSCODE_CRON, transcode-pool.sh runs.
│
├── acquires flock on /pvr/tmp/transcode-pool.lock
│
├── drain <queue> into <queue>.tmp, truncate <queue>
│   (atomic drain so a concurrent run never double-processes)
│
├── for each line in <queue>.tmp:
│   │
│   ├── path already in .done?  ─▶ SKIP already done
│   ├── path missing?           ─▶ SKIP missing source
│   │
│   ├── resolve_profile <name>
│   │   (loads fields from config.yaml under
│   │    profiles.<name>.*)
│   │
│   ├── ffprobe -select_streams s …  (if subtitle_strategy is not drop)
│   │   └─ dvb_teletext/dvb_subtitle only?  ─▶ -sn, log WARN
│   │
│   ├── build_ffmpeg_cmd <profile> <src> <dst>
│   │   (newline-separated argv + awk-quote + eval
│   │    so spaces/colons in $SCALE survive)
│   │
│   ├── nice -n 19 ffmpeg "$@"  > ffmpeg-$$.log 2>&1
│   │   │
│   │   └─ exit code:
│   │       ├─ 0 + non-empty output ─▶ OK
│   │       │   ├─ printf '%s\n' "$path" >> "$DONE"   (under flock)
│   │       │   ├─ python3 generate-nfo.py "$path" "$mp4"
│   │       │   │   (writes tvshow.nfo, episodedetails.nfo,
│   │       │   │    renames to Show SxxExx - Title.mp4)
│   │       │   ├─ copy .edl if non-empty            (else skip)
│   │       │   ├─ copy .txt if non-empty
│   │       │   └─ truncate ffmpeg-$$.log
│   │       │
│   │       └─ anything else         ─▶ FAIL, re-queue,
│   │                                    tail ffmpeg.log to transcode-nightly.log
│   │
│   └── (loop)
│
└── rm <queue>.tmp, transcode-pool finished
```

`resolve_profile` emits the values as shell variables — `video_codec`,
`audio_codec`, etc. — that `build_ffmpeg_cmd` reads. The library
maps `profiles.preservation.video.codec` → `video_codec`. See
[`CONFIGURATION.md`](./CONFIGURATION.md) for the YAML keys.

### Recording-completion hook

The TVH `postproc` field in a DVR profile triggers
`/pvr/scripts/post-recording.sh %f` when a recording finishes.
`%f` is the recording's filesystem path. TVH truncates `%f` at the
first space, so the hook includes a `resolve_ts` function that takes
the truncated prefix and looks for an exact `.ts` filename in the
parent directory; if not found, it falls back to glob. The resolved
path is then pushed to both queues.

## Networks

### `eth1` (external macvlan)

Fixed LAN IPs for TVHeadend and Jellyfin. Allows clients to find
them without DNS or container IP discovery.

Create once on the host before the first `docker compose up -d`:

```bash
docker network create -d macvlan \
    --subnet=192.168.1.0/24 \
    --gateway=192.168.1.1 \
    -o parent=eth1 \
    eth1
```

`compose.yml` references it as `external: true`.

### `pvr_internal` (internal bridge)

Subnet `172.25.0.0/16`, `internal: true`. Comskip and transcode
attach here. No route out of the host — they communicate with TVH
through the shared queue files on host volumes, never over the
network.

## Volumes on the host

The container bind mounts are the bridge between the network
partition and the persistent storage:

| Source on host                       | Mounted at (in container) | Used by                                          |
|--------------------------------------|----------------------------|--------------------------------------------------|
| `${DATA}/media/recordings/`          | `/recordings`              | comskip (ro), transcode (ro), tvheadend (rw)      |
| `${DATA}/media/transcoded/`          | `/media/transcoded`        | transcode (rw output), jellyfin (ro)             |
| `${DATA}/comskip/etc/`                | `/etc/comskip`             | comskip (ro — overrides baked config)             |
| `${DATA}/comskip/queue/`             | `/comskip/queue`           | comskip (rw — JSONL queue and log)               |
| `${DATA}/transcoder/scripts/`         | `/etc/transcoder`          | transcode (ro — pool + NFO scripts)              |
| `${DATA}/transcoder/queue/`          | `/transcoder/queue`        | transcode (rw — JSONL queue and log)              |
| `${DATA}/scripts/`                   | `/pvr/scripts`             | tvheadend (ro — post-recording hook)             |
| `${DATA}/scripts/config-loader.sh`   | `/usr/local/bin/config-loader.sh` | tvheadend (ro — sourced from post-recording) |
| `${DATA}/scripts/tvh-healthcheck.sh` | `/usr/local/bin/tvh-healthcheck.sh` | tvheadend (ro — used by healthcheck)        |
| `${DATA}/tmp/`                        | `/pvr/tmp`                 | all PVR containers (rw — locks, scratch logs)     |
| `${DATA}/tvheadend/config/dvr/log/`  | `/config/dvr/log`          | comskip + transcode (ro — read for NFO generation) |
| `/dev/dvb`                           | `/dev/dvb`                 | tvheadend (direct device access, privileged)      |

The `${DATA}/tmp/` shared scratch is a fix for the QNAP host's 64 MB
ramdisk `/tmp`: a single FFmpeg run can write 30+ MB to stderr.
Without this mount, the host's `/tmp` fills, the next cron run fails,
and the container's `/tmp` is the same 64 MB. By moving locks and
FFmpeg stderr dumps to `${DATA}/tmp` (the big volume), the
constraint goes away.

## Profile selection

The transcode container reads `default_profile` from
`config.yaml`. To override per recording, the post-recording hook
adds a `"profile": "<name>"` field to the queue line. For example:

```json
{"path":"/recordings/Show/Show.ts","added":"...","profile":"web_720p"}
```

Valid values are the profile names declared under `profiles:` in
`transcoder/scripts/config.yaml`. See
[`PROFILES.md`](./PROFILES.md) for the full reference.

## Why a separate comskip container?

Comskip runs whenever a new `.ts` appears in the queue. Putting it
inside the recorder's container would couple its CPU profile to
TVH's I/O path and risk dropping frames during recording. A
sidecar container lets the host schedule comskip at its own pace,
real-time, `nice 19`, and keeps the detection phase completely
independent of recording.

Comskip is single-threaded by design — adding workers does not
make it faster because the binary does not parallelise, and two
concurrent runs on the same `.ts` only thrash disk I/O.

## Why a separate transcode container?

Transcode is decoupled from recording. Even when running in real time
on a more powerful host, a Celeron-class CPU struggles when FFmpeg
and TVH's DVB demuxer compete for the same disk. Running transcode in
a sidecar container lets the host scheduler (`TRANSCODE_CRON`)
defer encoding to off-peak hours, and lets the resource limit cap
apply to encoding only (`memory: 2G`, `cpus: '3.0'` in
`compose.yml`) — not to TVH.

## Metadata for Jellyfin

Jellyfin's filename-based metadata lookup mistakes recordings for
movies (for example "Frendit" matched a movie called "Ihmeelliset
frendit"). The transcode container fixes this by:

- reading TVHeadend's DVR log directory (`/config/dvr/log`) read-only,
- parsing the original broadcast title and subtitle from the JSON
  log entry,
- extracting Finnish season/episode markers (`Kausi 4, 4/12`,
  `Kausi 31. Jakso 7-22`),
- identifying movies via TVH's native `content_type` field
  (1=movie, 4=sports, 0/8/10=series) rather than title heuristics,
- writing a minimal `tvshow.nfo` containing only the series title so
  Jellyfin looks up the rest online,
- writing a full `episodedetails.nfo` next to the `.mp4` with
  episode-specific plot, season, episode and air date,
- renaming the episode to `Show SxxExx - Title.mp4` so Jellyfin's
  built-in metadata lookup identifies it as a TV series episode.

For movies, `content_type=1` triggers a `movie.nfo` (not `tvshow.nfo`)
and the `Elokuva_` prefix is stripped from the filename.

## Related projects

- **DVB tuner drivers for QNAP:** https://github.com/petekaik/qnap-dvb

## Security considerations

- `.env` is excluded from Git via `.gitignore`. Only `.env.example`
  (placeholder values) ships in the repo.
- `compose.yml` references every secret via `${VAR}` substitution,
  so the file itself is safe to commit.
- No container ports are exposed to the host except via the macvlan
  network. Comskip and transcode have no published ports.
- The transcoder and post-recording scripts are mounted read-only
  where possible, so a security bug in a script cannot overwrite
  its own source.
- TVHeadend runs `privileged: true` solely to access `/dev/dvb`.
  The permission is scoped to that single service. The other
  services run unprivileged.
- `tvh-healthcheck.sh` only probes `/dev/dvb` and never reads
  TVH's runtime config (which contains the admin password hash).

## Scaling / future extensions

- **Multiple transcode containers** — the queue file would need a
  lock-aware split. The simplest way today is to scope each
  container to a subset of the recordings by running different
  `TRANSCODE_CRON` expressions on each host.
- **`ccextractor` for DVB subs** — install it into the transcode
  image (`apt-get install ccextractor`) and add a hook in
  `transcode-pool.sh` to run it on the source `.ts` when the
  source has only bitmap subtitles. The hook can drop a `.srt`
  next to the recording and the pool can copy it alongside the
  `.mp4`.
- **Hardware acceleration** — add a `qsv` profile with
  `video.codec: h264_qsv` and `extra: "-look_ahead 0 -async_depth 4"`.
  Requires `/dev/dri` mounted into the transcode container and an
  Intel CPU with QuickSync on the host.
- **WebGrab+Plus integration** — see `examples/webgrabplus/`. The
  example installs the `.NET 9` runtime and writes XMLTV output to
  a host directory that TVH reads as an additional EPG source.
