# PVR Stack for QNAP / Docker

A lightweight, containerised personal video recorder (PVR) stack built
for low-power Docker hosts such as a QNAP NAS. TVHeadend records DVB-T/T2
broadcasts as MPEG-TS pass-through files. Two specialised post-processing
containers consume the queue:

  - **comskip** runs commercial detection in real time (single-threaded,
    nice 19). It produces `.edl` files that mark the commercial breaks so
    Jellyfin can skip them on playback.
  - **transcode** converts the `.ts` recordings to H.264 MP4. Encoding
    runs as a separate transcode pass with profile-based settings. Both
    containers share a writable `pvr_internal` network and reach the host
    recordings via bind mounts.

The originals are preserved. Jellyfin serves both live TV and the
recordings.

## Components

| Container     | Image (build context / source)                | Role                                                        |
|---------------|-----------------------------------------------|-------------------------------------------------------------|
| `tvheadend`   | `lscr.io/linuxserver/tvheadend:latest`        | DVB tuner management, EPG, recording scheduler              |
| `jellyfin`    | `jellyfin/jellyfin:latest`                     | Media server for live TV and recordings                     |
| `comskip`     | built from `comskip/` → `pvr-comskip:latest`   | Real-time commercial detection, writes `.edl` next to `.ts` |
| `transcode`   | built from `transcoder/` → `pvr-transcode:latest` | Drains the queue, transcodes to MP4, emits NFO/sidecars  |
| shared base   | built from `pvr-base/` → `pvr-base:latest`     | Debian + ffmpeg + python3 + cron (FROM pvr-base)            |

The `pvr-base` image is not a running service. It exists only as the
shared build cache layer so the two specialised images (comskip / transcode)
inherit the same packages without re-installing them on every build.

TVHeadend and Jellyfin get fixed IPs from a `macvlan` network (`eth1`).
Comskip and transcode communicate with TVHeadend via JSONL files in
`${DATA}/comskip/queue/` and `${DATA}/transcoder/queue/`, both mounted
into the TVH container. They live on a private Docker network
(`pvr_internal`) that has no route out of the host.

## Quick start

```bash
# 1. Clone the repository onto your Docker host.
git clone https://github.com/petekaik/qnap-pvr.git
cd qnap-pvr

# 2. Copy the example environment file and fill in your values.
cp .env.example .env
$EDITOR .env

# 3. Create the macvlan network if it does not already exist.
docker network create -d macvlan \
    --subnet=192.168.1.0/24 \
    --gateway=192.168.1.1 \
    -o parent=eth1 \
    eth1 || true

# 4. Build and start.
./build.sh                   # one-shot build of pvr-base + comskip + transcode
docker compose up -d          # bring up all four services
```

`./build.sh` builds the three local images with a consistent layer
ordering (`pvr-base` first, then the two specialised ones). See
[`build.sh`](./build.sh) for `--no-cache` and other flags.

## Directory layout on the host

```
${DATA}/
├── compose.yml mounts
│
├── media/
│   ├── recordings/        # Original .ts files (preserved)
│   └── transcoded/        # Output .mp4 + .nfo + .edl + .jpg
│
├── comskip/
│   ├── bin/               # Comskip 0.83.001 binary (large, .gitignored)
│   ├── etc/
│   │   ├── comskip.ini    # Comskip detection thresholds
│   │   ├── config.yaml    # Comskip queue + log paths, channel skip list
│   │   └── scripts/       # Host-side overrides for the baked pool scripts
│   └── queue/             # Comskip queue (comskip-queue.jsonl) and done log
│
├── transcoder/
│   ├── scripts/           # Pool script + NFO generator (mounted ro)
│   └── queue/             # Transcode queue and done log
│
├── scripts/               # TVH post-recording hook (ro mount)
│
├── tmp/                   # Scratch dir for locks and FFmpeg scratch logs
│                          # (replaces the host /tmp which is a 64 MB ramdisk)
│
├── tvheadend/config/      # TVH runtime data
└── jellyfin/config/       # Jellyfin runtime data
```

## Comskip and Transcode how they hook in

TVHeadend appends a JSONL line to two queue files via the post-processor
hook in `scripts/post-recording.sh`:

```
{"path":"/recordings/<dir>/<episode>.ts","added":"<ISO 8601>"}
```

- **comskip** follows the queue with `tail -F -n 0`, runs Comskip
  per-line, skips channels in the commercial-free list, and writes
  `<episode>.edl` next to the source `.ts`.
- **transcode** drains the queue at a fixed schedule (`TRANSCODE_CRON`,
  default hourly), transcodes any pending work, and copies the EDL/TXT
  sidecars alongside the new `.mp4`. Originals stay where they are.

Both pools use a `flock` lockfile to ensure only one instance runs at a
time per container.

### Queue semantics

The queue files are append-only JSONL. A second file, `<queue>.done`,
records the path of every recording that has already been processed.
This is the idempotency guard: a job already in `.done` is skipped on
the next run, regardless of how many times it appears in the queue
file.

## Configuration

| File                                             | What it controls                                                         |
|--------------------------------------------------|--------------------------------------------------------------------------|
| `.env`                                           | Secrets: TVH admin password, Jellyfin API key, paths, cron expression    |
| `compose.yml`                                    | Service layout, bind mounts, resource limits                             |
| `comskip/etc/config.yaml`                        | Comskip binary path, queue paths, log path, commercial-free channels      |
| `comskip/etc/comskip.ini`                        | Comskip detection thresholds (logo position, scene-change sensitivity)  |
| `transcoder/scripts/config.yaml`                 | Default profile, per-profile FFmpeg invocation plan, log rotation       |
| `scripts/config.yaml`                            | TVH post-recording hook → which queues get the new jobs                  |

Profiles are documented in detail in
[`docs/PROFILES.md`](./docs/PROFILES.md). The full C4 architecture and
data flow live in [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md).

## Why a separate comskip container?

Comskip runs whenever a new `.ts` appears in the queue. Spawning it as a
sidecar to the recorder would couple its CPU profile to TVH's I/O path
and risk dropping frames. A sidecar container lets the host schedule
comskip at its own pace (real-time, `nice 19`), and keeps the detection
phase completely independent of the recording phase.

Comskip is single-threaded by design — adding workers does not make it
faster because the binary does not parallelise, and two concurrent
runs on the same `.ts` only thrash disk I/O.

## Why a separate transcode container?

Same reasoning: transcode is decoupled from recording. Even when running
in real time, a Celeron-class host struggles if FFmpeg and TVH's DVB
demuxer compete for the same disk. Running transcode in a sidecar
container allows the host scheduler (`TRANSCODE_CRON`) to schedule
encoding for off-peak hours, and lets us cap the encoding resource
budget independently from recording (transcode has 2 GB RAM and 3 CPUs
in the default `compose.yml`).

## Profiles

The `transcode` container selects a profile per queue line:

  - `preservation` (default) — visually lossless libx264 (CRF 15,
    `preset=slow`, `tune=film`), `audio.codec=copy` preserves every
    audio track bit-for-bit (DD 5.1 stays DD 5.1), subtitle copy
    with bitmap-aware fallback.
  - `high_quality` — same as before refactor; CRF 18 libx264 with
    audio re-encoded to AAC 2.0.
  - `web_720p` — 720p, veryfast preset, CRF 28. Sized for mobile clients.
  - `passthrough` — zero-encode TS→MP4 remux. Fastest path, identical
    decoded video/audio.

See [`docs/PROFILES.md`](./docs/PROFILES.md) for per-field guidance
and the dvb_teletext/dvb_subtitle handling rules.

## Logging

- **Comskip log:** `/share/Programs/pvr/comskip/queue/comskip.log`
  Contains only structured `RUN` / `OK` / `SKIP` / `EDL` / `FAIL` lines.
  Comskip's own per-frame progress (which is hundreds of lines per
  recording) is redirected to `progress_log`, which defaults to
  `/dev/null`. To capture it for debugging, change the value in
  `comskip/etc/config.yaml`.

- **Transcode log:** `${DATA}/logs/transcode-nightly.log`
  Captured by the container's `tail -F` (PID 1) and persisted to host
  via the `/var/log` bind. Size-triggered rotation handled inside the
  pool script (`log_max_kb` / `log_keep` in `config.yaml`).

- **TVH post-recording log:** `${DATA}/tvheadend/config/dvr/log/post-recording.log`
  Mounted read-only into the comskip and transcode containers so they
  can read it when generating NFO files.

Log rotation for host-side files is configured in
`/etc/logrotate.d/pvr` on the host (not in this repo — install once via
your host's package manager or write the snippet manually).

## Network

```
┌─ eth1 (macvlan) ───────────────────┐  ┌─ pvr_internal (bridge) ─────┐
│  192.168.1.52  tvheadend           │  │  comskip                    │
│  192.168.1.53  jellyfin            │  │  transcode                  │
└────────────────────────────────────┘  └────────────────────────────┘
                  ▲                              ▲
                  └────── both share queue ──────┘
                          files on host
```

TVHeadend and Jellyfin use a Docker `macvlan` network (`eth1`) to get
fixed LAN IPs. Comskip and transcode live on an internal bridge network
(`pvr_internal`, `internal: true`) with no route out of the host — they
only need to read files mounted from `${DATA}`.

## Security considerations

- `.env` contains TVH admin password and Jellyfin API key. Excluded from
  Git via `.gitignore`. Never commit it.
- `.env.example` ships placeholder values only.
- `compose.yml` references every secret via `${VAR}` substitution so
  the file itself stays secret-free.
- No container ports are exposed to the host other than the macvlan
  IPs above. Comskip and transcode have no published ports.
- The transcoder and post-recording scripts are mounted read-only
  (`:ro`) where possible, so a security bug in a script cannot
  overwrite its own source.
- TVHeadend runs `privileged: true` solely to access `/dev/dvb`. The
  permission is scoped to that single service.
- `tvh-healthcheck.sh` is mounted read-only and probes only `/dev/dvb`,
  never the application config.

## Related projects

- **DVB tuner drivers for QNAP:** https://github.com/petekaik/qnap-dvb
  Builds the kernel modules `em28xx`, `si2168`, `si2157`,
  `videobuf2-*` and the `dvb-demod-si2168-b40-01.fw` firmware that
  TVHeadend needs to talk to a Hauppauge dualHD on a stock QNAP TS-X51
  kernel (which ships no DVB drivers).

## License

MIT
