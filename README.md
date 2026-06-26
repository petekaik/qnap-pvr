# PVR Stack for QNAP / Docker

A lightweight, containerized personal video recorder (PVR) stack built for low-power Docker hosts such as a QNAP NAS. TVHeadend records DVB-T/T2 broadcasts as MPEG-TS pass-through files. A dedicated `transcoder` container transcodes them to H.264/AAC MP4 files during off-peak hours, keeping the originals intact. Jellyfin serves both live TV and recordings.

## Components

| Container | Image | Purpose |
|-----------|-------|---------|
| `tvheadend` | `lscr.io/linuxserver/tvheadend:latest` | DVB tuner management, EPG, recording scheduler |
| `jellyfin` | `jellyfin/jellyfin:latest` | Media server for live TV and recordings |
| `transcoder` | `pvr-transcoder:latest` (local build) | Off-peak H.264/AAC transcoding of `.ts` recordings |

## Quick start

1. Clone the repository onto your Docker host.
2. Copy `.env.example` to `.env` and fill in your local values.
3. Create the external macvlan network if it does not exist.
4. Run `docker compose up -d --build`.
5. Configure TVHeadend via its web UI and set the post-processor command.

See `docs/ARCHITECTURE.md` for full setup instructions and C4 diagrams.

## Directory layout on the host

```
${DATA}/
├── tvheadend/config/      # TVH configuration
├── tvheadend/epg/         # XMLTV exports (optional)
├── jellyfin/config/       # Jellyfin configuration
├── jellyfin/cache/        # Jellyfin cache
├── media/
│   ├── recordings/        # Original .ts recordings
│   ├── transcoded/        # Transcoded .mp4 files
│   └── tv/                # Additional TV library
├── transcoder/
│   ├── scripts/           # Transcoder scripts (mounted read-only)
│   └── queue/             # Transcode queue and done-log
```

## Post-processor setup

In the TVHeadend web UI, open **Configuration -> Recording -> DVR Profiles**, enable **Advanced** options, and set:

```
Post-processor command: /transcoder/scripts/post-recording.sh %f
```

`%f` is replaced by TVH with the full path of the recorded file.

## Transcoder schedule

Set `TRANSCODE_CRON` in `.env`. Default is daily at 02:00. During testing you can use `0 * * * *` (every hour).

## Jellyfin metadata

The transcoder writes two kinds of metadata next to each transcoded file:

1. `tvshow.nfo` in the show directory.
2. `<episode>.nfo` next to the `.mp4` file.

It also renames episodes to `Show SxxExx - Title.mp4` so Jellyfin's built-in metadata lookup recognises them as TV episodes instead of guessing a movie title from the filename.

## License

MIT
