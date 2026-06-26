# Architecture

This document describes the PVR stack using the [C4 model](https://c4model.com/) level-2 (container) diagram. The system is designed for low-power Docker hosts where CPU-intensive transcoding must be decoupled from recording.

## Context (C4 Level 1)

A household wants to record free-to-air DVB-T/T2 broadcasts and watch them on local network clients. The host is a QNAP NAS-class device with limited CPU power.

```
┌──────────────┐     DVB-T/T2     ┌─────────────────────────────────────┐
│  Antenna     │──────────────────▶│  PVR Stack (Docker on QNAP/NAS)     │
└──────────────┘                   │                                     │
                                 │  TVHeadend, Jellyfin, transcoder  │
┌──────────────┐                 │                                     │
│  Home users  │◀────────────────│  Live TV, recordings, transcoded   │
│  (clients)   │   HTTP / DLNA   │  files                             │
└──────────────┘                 └─────────────────────────────────────┘
```

## Containers (C4 Level 2)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                Docker Host                                  │
│  ┌──────────────┐   ┌──────────────┐   ┌─────────────────────────────┐   │
│  │  tvheadend   │   │   jellyfin   │   │        transcoder           │   │
│  │              │   │              │   │                             │   │
│  │  Records     │   │  Serves live │   │  Reads queue                │   │
│  │  .ts files   │   │  TV + all    │   │  Transcodes .ts → .mp4      │   │
│  │  Runs post-  │   │  recordings  │   │  Off-peak schedule          │   │
│  │  processor   │   │              │   │                             │   │
│  └──────┬───────┘   └──────┬───────┘   └─────────────┬───────────────┘   │
│         │                  │                         │                   │
│         └──────────────────┴─────────────────────────┘                   │
│                            Shared host volumes                              │
│              /media/recordings, /media/transcoded,                          │
│              /transcoder/queue, /transcoder/scripts                         │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Data flow

1. TVHeadend records a program to `${DATA}/media/recordings/<show>/<episode>.ts`.
2. After the recording finishes, TVH invokes `/transcoder/scripts/post-recording.sh %f` inside the `tvheadend` container.
3. The hook appends the recording path to `/transcoder/queue/transcode-queue.jsonl`.
4. At `TRANSCODE_CRON`, the `transcoder` container runs `nightly-transcode.sh`.
5. The script reads the queue, transcodes each `.ts` to H.264/AAC MP4 under `/media/transcoded/`, and preserves the original `.ts`.

## Why a separate transcoder container?

TVHeadend can transcode recordings itself with stream profiles, but doing so during recording consumes CPU resources on a low-power host and risks dropped frames. A separate container:

- shifts CPU load to off-peak hours,
- preserves the original transport stream,
- uses a plain ffmpeg pipeline that is easier to tune than TVH's internal transcode logic,
- avoids TVH bugs such as broken MPEG-TS transcode flags in some versions.

## Network

TVHeadend and Jellyfin use a Docker `macvlan` network (`eth1`) to obtain fixed IP addresses on the home LAN. The transcoder uses an internal bridge network only; it does not need a routable IP.

## Security considerations

- `.env` contains API keys and credentials; it is excluded from Git via `.gitignore`.
- No container ports are exposed to the host except those defined by the macvlan addresses.
- The transcoder scripts are mounted read-only where possible.
- TVHeadend runs `privileged: true` only to access `/dev/dvb` DVB tuners.

## Scaling / future extensions

- Add a second `transcoder` replica if CPU and disk I/O allow (queue file would need a lock-aware split).
- Replace `dcron` with an external scheduler (e.g. host cron or Kubernetes CronJob) if the Docker host already has one.
- Extend `nightly-transcode.sh` with commercial detection or subtitle extraction.
