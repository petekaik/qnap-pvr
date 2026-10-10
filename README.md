# PVR Stack for QNAP / Docker

A lightweight, containerised personal video recorder (PVR) stack built
for low-power Docker hosts such as a QNAP NAS. TVHeadend records DVB-T/T2
broadcasts as MPEG-TS pass-through files. Three specialised post-processing
containers work off that output, all reaching the host recordings via bind
mounts and all running with `network_mode: none` (no network interface):

  - **comskip** runs commercial detection in real time (single-threaded,
    nice 19). It produces `.edl` files that mark the commercial breaks so
    Jellyfin can skip them on playback.
  - **transcode** converts the `.ts` recordings to H.264 MP4. Encoding
    runs as a separate transcode pass with profile-based settings,
    scheduled for off-peak hours.
  - **cc-extract** extracts DVB subtitles to `.srt` with CCExtractor. It
    tails comskip's done-list rather than holding its own queue, so a
    recording is only processed once commercial detection has finished
    with it.

The originals are preserved. Jellyfin serves both live TV and the
recordings.

An optional **tvhproxy** sidecar emulates an HDHomeRun tuner so Jellyfin
and other HDHomeRun-aware clients (Plex, Channels, the HDHomeRun app) can
discover TVHeadend over the LAN without Jellyfin acting as an intermediary.
It is a fork of [chkuendig/tvhProxy](https://github.com/chkuendig/tvhProxy)
with SSDP and SiliconDust binary discovery added — see
[`tvhproxy/README.md`](./tvhproxy/README.md). It also serves the channel
logos (picons) at `/picons/` — see [Channel logos](#channel-logos-picons).

### Channel logos (picons)

TVHeadend hands its clients a channel icon URL verbatim, and the
linuxserver image it is configured to use points at
`file:///picons/%C.png`. No HTTP client can fetch a `file://` URL, so
Jellyfin failed the image fetch for every channel on every guide refresh
(34 errors / 21 channels over three days, measured 2026-10-10) and
displayed no logos at all. TVHeadend's own `/imagecache` route is not a
substitute: it is keyed on a numeric id rather than a name, and it is
auth-gated.

tvhproxy therefore serves the same files over HTTP at `/picons/<name>.png`,
and TVH's channel icons point there. A host-published port would not work —
Jellyfin is a macvlan child and cannot reach the NAS host itself, whereas
tvhproxy has its own address in the same broadcast domain.

The picons live *inside the tvheadend image*, not on a host path, so they
cannot be bind-mounted out of it; copy them once and re-copy whenever the
image is updated:

```bash
docker cp tvheadend:/picons "${DATA}/picons"
```

Then point TVH at the HTTP copy. Do this with the container stopped — TVH
rewrites `/config` on shutdown and would otherwise clobber the edit:

```bash
docker compose stop tvheadend
sed -i 's|"chiconpath": "file:///picons/|"chiconpath": "http://<tvhproxy-ip>:5004/picons/|' \
    "${DATA}/tvheadend/config/config"
sed -i 's|file:///picons/|http://<tvhproxy-ip>:5004/picons/|g' \
    "${DATA}"/tvheadend/config/channel/config/*
docker compose start tvheadend
```

`piconpath` is deliberately left at `file:///picons/`: TVH only validates
`file://` URLs before use, so pointing it at HTTP makes TVH assume every
service-named picon exists and log a failed download for each one. The
service-named set is not in the image anyway.

**Channels with no usable picon — status 2026-10-10.** Five channels carried
no stored `icon` and fell back to a service picon the image does not ship,
so TVH resolved a dead path and Jellyfin logged an "does not have an image"
error per request. Pre-existing, and not fixable by configuration alone —
each one needs an image supplied. Four now have one, placed in
`${DATA}/picons/` and pointed at with the override recipe below:

| channel | file | source |
|---|---|---|
| TV5 | `tv5-fi.png` | Wikimedia Commons — the 2024 rebrand mark |
| MTV Ava | `mtvava.png` | the set's own `ava tv.png` (the AVA wordmark) |
| One Way TV | `onewaytv.png` | onewaymission.fi (`OWTV-logo-mini.png`) |
| onniTV | `onnitv.png` | onnitv.fi (`onnitv-logo.png`) |

**Iskuri.net** was the one gap with no image available: an adult channel
(historically Sextv.fi / Digiviihde) whose current mark lives only on its own
site, while the sole neutral source — Wikipedia — carries the *historic*
Digiviihde logo, i.e. the wrong brand. As of 2026-10-10 the channel (and the
nameless `PMT:` ghost channel, which also had no icon) is **disabled in TVH**
instead: it advertises no icon, so nothing errors, and it no longer appears in
Jellyfin's guide. Supply a PNG under any unused name to reinstate it with the
recipe above. List anything still icon-less with:

```bash
docker exec tvhproxy sh -c 'curl -s --digest -u "$TVH_USER:$TVH_PASSWORD" \
  "http://<tvh-ip>:9981/api/channel/grid?limit=999&start=0"' \
  | tr '}' '\n' | grep '"icon":"picon://'
```

Clearing a channel's icon instead makes TVH advertise none, which stops the
error but shows no logo.

**Correction (added later the same day — read this before trusting the
section above).** An earlier version of this section implied that serving
the picons over HTTP fixed Jellyfin's channel-image errors. It does not.
TVH's `htsp_image()` (`src/htsp_server.c`) shows that for HTSP clients at
protocol version 15 or above — Jellyfin's plugin negotiates 44 — TVH does
**not** pass the configured icon URL through at all: it substitutes a
*relative* `imagecache/<id>` reference. The `file://` path is therefore
never handed to Jellyfin.

The guide's `UriFormatException` has a different cause. The plugin rebuilds
an absolute URL from that relative reference and embeds the TVH account's
credentials in it **unencoded**, producing
`http://<user>:<password>@<tvh-host>:<port>/imagecache/<id>`.

Two things are needed to make that work, and both were measured on this
deployment on 2026-10-10 against Jellyfin 12.2.0 and plugin 15.0.0.0:

1. **A URL-safe (alphanumeric) password** on whichever TVH account the
   plugin authenticates with. A password containing `@`, or a `%` not
   followed by two hex digits, makes .NET reject the URL outright:
   `Invalid URI: The hostname could not be parsed`.
2. **An access-control entry in TVH granting the Jellyfin host
   unauthenticated access.** The plugin embeds credentials in the URL
   precisely so the fetch can authenticate, but Jellyfin's `HttpClient`
   does not turn URI userinfo into an Authorization header — so the
   request arrives anonymous. TVH accepts only **digest** on
   `/imagecache` (measured: no auth → 401, basic → 401, digest → 200),
   and without an entry the fetch fails with
   `HttpRequestException: … 401 (Unauthorized)`.

   An entry with username `*` (TVH's anonymous user), a prefix limited to
   the Jellyfin host (`<jellyfin-ip>/32`) and **streaming rights only** is
   sufficient: the `/imagecache` route accepts `ACCESS_STREAMING`, so the
   web UI stays password-protected and nothing else on the LAN is
   affected. Verified: the same URL returns 200 from the Jellyfin host and
   still 401 from any other.

Also note the plugin **logs the credentialed URL**, so the TVH password
appears in cleartext in Jellyfin's log whenever an image fetch fails. Do
not share those logs; rotate the account if they have been.

**Channel icon overrides.** The picon set that ships inside the tvheadend
image is a pan-European collection with name collisions, and TVH's
service-name scheme picks the wrong file wherever names collide. Measured:
Finnish **TV5** resolves to `tv5.png`, which is **IRIB TV5**, an Iranian
Quran channel; the set also mislabels `tvfinland.png`, which is really the
**Frii** logo. The fix is to place the correct image under a name nothing
else uses and point the channel at it. No TVH restart is needed, so an
in-flight recording is not disturbed:

```bash
cp <correct-logo>.png "${DATA}/picons/tv5-fi.png"
curl -s --digest -u "$TVH_USER:$TVH_PASSWORD" -X POST \
  --data-urlencode \
  'node={"uuid":"<channel-uuid>","icon":"http://<tvhproxy-ip>:5004/picons/tv5-fi.png"}' \
  "http://<tvh-ip>:9981/api/idnode/save"
```

The channel then gets a fresh `imagecache/<id>`, and Jellyfin picks up the
new URL on its next guide refresh. Get `<channel-uuid>` from
`/api/channel/grid`.

Serving the picons here is still worth keeping — it is what TVH's own image
cache fetches from, and it keeps `chiconpath` reachable by any consumer that
takes the raw icon — but it is not what Jellyfin's errors were about.

## Components

| Container     | Image (build context / source)                | Role                                                        |
|---------------|-----------------------------------------------|-------------------------------------------------------------|
| `tvheadend`   | `lscr.io/linuxserver/tvheadend:latest`        | DVB tuner management, EPG, recording scheduler              |
| `jellyfin`    | `jellyfin/jellyfin:latest`                     | Media server for live TV and recordings                     |
| `comskip`     | built from `comskip/` → `pvr-comskip:latest`   | Real-time commercial detection, writes `.edl` next to `.ts` |
| `transcode`   | built from `transcoder/` → `pvr-transcode:latest` | Drains the queue, transcodes to MP4, emits NFO/sidecars  |
| `cc-extract`  | built from `cc-extract/` → `pvr-cc-extract:latest` | Extracts DVB subtitles to `.srt`, tails comskip's done-list |
| `tvhproxy`    | built from `tvhproxy/` → `pvr-tvhproxy:latest` | HDHomeRun protocol emulation for client auto-discovery      |
| `pvr-queue-exposer` | built from `pvr-queue-exposer/` → `pvr-queue-exposer:latest` | Read-only HTTP bridge for queue files, consumed by the TVH webui plugin (see [`BACKLOG.md`](./BACKLOG.md)) |
| `pvr-base`     | built from `pvr-base/` → `pvr-base:latest`     | Shared base image — Debian + ffmpeg + python3 + cron. Not a service |

The `pvr-base` image is not a running service. It exists only as the
shared build cache layer so the specialised images (comskip / transcode /
cc-extract) inherit the same packages without re-installing them on every
build.

TVHeadend, Jellyfin and tvhproxy get fixed IPs from a `macvlan` network
(`eth1`). The worker containers communicate with TVHeadend via JSONL files
in `${DATA}/comskip/queue/` and `${DATA}/transcoder/queue/`, both mounted
into the TVH container. They run with `network_mode: none` — no network
interface at all — so the queues are the only communication channel.
cc-extract has no queue of its own; it tails comskip's done-list.

## Post-Processing webui (planned, not yet implemented)

[`BACKLOG.md`](./BACKLOG.md) tracks the plan to add a Post-Processing tab
to TVH's Digital Video Recorder view, a Post-Processing panel to the Status
view, a Settings entry for comskip/transcode configuration, and trigger/skip
endpoints. It is paused while the rolled-back state is validated — see
[`pvr-tvhd/README.md`](./pvr-tvhd/README.md) for what was rolled back and
why.

## Quick start

```bash
# 1. Clone the repository onto your Docker host.
git clone https://github.com/petekaik/qnap-pvr.git
cd qnap-pvr

# 2. Copy the example environment file and fill in your values.
cp .env.example .env
$EDITOR .env

# 3. Create the macvlan network if it does not already exist.
#    Replace the subnet/gateway/iface placeholders with values that
#    match your LAN. Use an unused subnet (not your main LAN's
#    subnet if you have one) so the macvlan addresses do not collide
#    with DHCP-assigned IPs.
docker network create -d macvlan \
    --subnet=<your-macvlan-subnet> \
    --gateway=<your-lan-gateway> \
    -o parent=<your-lan-iface> \
    eth1 || true

# 4. Build and start.
./build.sh                    # pvr-base, then the images that inherit from it
docker compose up -d          # starts every service; Compose builds the
                              # remaining images on demand
```

`./build.sh` builds the local images with a consistent layer ordering
(`pvr-base` first, then the images that inherit from it). Services whose
image is not pre-built are built by Compose on the first `up`. See
[`build.sh`](./build.sh) for `--no-cache` and other flags.

Running TVHeadend and Jellyfin under `.env.example`'s placeholders is not
enough on its own — the stack expects a real `DATA` directory tree, a
`macvlan` network, and `/dev/dvb` present on the host. `.env.example` is
the canonical, commented list of every variable the stack reads.

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

### How they hook in

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
- **cc-extract** has no queue of its own. It tails comskip's done-list, so
  a recording reaches subtitle extraction only after commercial detection
  has finished with it — a one-way dependency that keeps
  `post-recording.sh` unaware of cc-extract.

Both pools use a `flock` lockfile to ensure only one instance runs at a
time per container.

### Queue semantics

The queue files are append-only JSONL. A second file, `<queue>.done`,
records the path of every recording that has already been processed.
This is the idempotency guard: a job already in `.done` is skipped on
the next run, regardless of how many times it appears in the queue
file.

### Comskip restart semantics

`comskip-pool.sh` is a `tail -F` follower. A naive tail loop would
only see **new** lines appended after start; lines that TVH queued
while the container was down would be silently dropped on restart.
The comskip container's `entrypoint.sh` therefore runs three
subcommands on every start:

1. `drain` — reads the whole queue once, processes every line,
   empties the queue file.
2. `prune-done` — drops entries from `comskip-queue.done` whose
   source `.ts` no longer exists on disk. Keeps the done-list from
   growing forever when you delete recordings in TVH, and lets a
   later recording that reuses the same path be re-processed.
3. `watch` — runs the `tail -F` loop in the background.

So the container restart sequence is: catch up on whatever was
queued → forget about deleted recordings → start watching for new
work.

The transcode container has the same restart-safety built in,
plus one extra step for the failure mode the drain's
`cp queue tmp; : > queue` design introduces. Its `entrypoint.sh`
runs three subcommands on every start:

1. `recover-orphaned-tmp` — if a previous run died mid-flight
   (FFmpeg SIGKILL, host reboot, OOM kill, NAS crash), the
   drain step left `transcode-queue.jsonl.tmp` on disk with
   untouched lines. This appends them back to the queue and
   removes the tmp. Without this, those lines would sit on
   disk forever and a human would have to manually move the
   tmp back into the queue.
2. `prune-done` — drops entries from `transcode-queue.done`
   whose source no longer exists. Same rationale as comskip's.
3. `run` — drains whatever is already queued, including any
   lines recovered in step 1.

The cron tick installs a scheduled `run` (no recover, no prune)
so the done-list is cleaned only at container boundaries, not
in the middle of a busy day. So a container restart — or even
a hard crash mid-transcode — never loses queued work, and the
done-list does not grow forever as recordings are deleted in
TVH.

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

## How the documentation is rendered

Architecture diagrams in this repository use
[Mermaid](https://mermaid.js.org/) embedded directly in Markdown
files. GitHub renders Mermaid natively — open `docs/ARCHITECTURE.md`
on the GitHub web UI and the C4 container diagram, the build-time
layering diagram, and the recording-and-post-processing sequence
diagram will draw automatically. No extra tooling, no PNG artefacts
to commit, no out-of-date diagram files.

The PlantUML sources (`docs/diagrams/c4-*.puml`) are kept in the
repo for editors that prefer PlantUML, but the canonical, always
up-to-date diagrams are the Mermaid blocks in
[`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md). When you change the
architecture, edit the Mermaid in `ARCHITECTURE.md`; the PUML files
are not the source of truth.

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
in real time, a low-power host struggles if FFmpeg and TVH's DVB
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

- **Comskip log:** `${DATA}/comskip/queue/comskip.log`
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
┌─ <lan-iface> (macvlan) ──────────────────────┐  ┌─ network_mode: none ─────┐
│  <tvheadend-ip>   tvheadend                  │  │  comskip                 │
│  <jellyfin-ip>    jellyfin                   │  │  transcode               │
│  <tvhproxy-ip>    tvhproxy                   │  │  cc-extract              │
└──────────────────────────────────────────────┘  └──────────────────────────┘
                       ▲                          ▲
                       └────── share queue ───────┘
                              files on host
```

TVHeadend, Jellyfin and tvhproxy attach to a `macvlan` network (`eth1`) so
they get fixed LAN IPs visible to clients on the home network. The worker
containers (comskip, transcode, cc-extract) run with `network_mode: none`
— they have no network interface at all, and reach the outside world only
as files mounted from `${DATA}`. Communication between TVH and the workers
happens entirely through those shared filesystem queues
(`${DATA}/comskip/queue/` and `${DATA}/transcoder/queue/`); no container
ever opens a socket to another. See
[`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md#networks) for the full
rationale on why this is more secure than the previous `internal: true`
bridge setup.

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
- Comskip, transcode and cc-extract run with `network_mode: none` — they
  have no network interface at all, so a vulnerability in FFmpeg's demuxer,
  in comskip's commercial-detection code, or in CCExtractor cannot reach
  the LAN, the Jellyfin admin API, or the QNAP management UI.
- tvhproxy's TVH credentials come from `.env` (`TVH_USER` / `TVH_PASSWORD`)
  and are passed into the container as environment variables; the
  matching TVH account is IP-allowlisted to the LAN, so the password alone
  is not sufficient from an off-network host. Those TVH account files
  (`tvhproxy/etc/`, `tvhproxy/passwd/`) are gitignored — they carry the
  credential and the allow-list, and are host state rather than source.

## Related projects

- **DVB tuner drivers for QNAP:** https://github.com/petekaik/qnap-driver-builder — builds
  the kernel modules and supplies the firmware that a QNAP host needs before
  TVHeadend can see a tuner at all (some QNAP kernels ship no DVB drivers). That
  project owns the whole hardware side: drivers, firmware, `/dev/dvb` and
  keeping them loaded across reboots and QTS updates. This repository starts
  where it ends — at the device nodes already existing.

This stack is built on other people's work:

- **[TVHeadend](https://github.com/tvheadend/tvheadend)** — the recorder. This
  repository uses the
  [LinuxServer.io image](https://github.com/linuxserver/docker-tvheadend); the
  paused fork is documented in [`pvr-tvhd/`](./pvr-tvhd/README.md).
- **[tvhProxy](https://github.com/chkuendig/tvhProxy)** — HDHomeRun protocol
  emulation, vendored into [`tvhproxy/`](./tvhproxy/README.md) with SSDP and
  SiliconDust binary discovery added. The
  [jkaberg fork](https://github.com/jkaberg/tvhProxy) is the more active
  ancestor of the two upstreams.
- **[Jellyfin](https://github.com/jellyfin/jellyfin)** — media server and
  playback client.
- **[Comskip](https://github.com/erikkaashoek/Comskip)** — commercial
  detection.
- **[CCExtractor](https://github.com/CCExtractor/ccextractor)** — DVB subtitle
  extraction.
- **[iptv-org/epg](https://github.com/iptv-org/epg)** and
  **[WebGrab+Plus](https://github.com/WebGrabPlus)** — EPG grabbers, wired up
  under [`examples/`](./examples/README.md).

## Documentation hygiene

This repository is intended to ship on public GitHub. Before you
commit any change to the documentation, run these checks:

```bash
# 1. No host paths leaked into the docs.
grep -rnE '/share/[A-Z]|/mnt/|/home/[a-z]+/|~/' README.md docs/ examples/  # secretscan:ignore

# 2. No LAN IPs or subnets.
grep -rnE '192\.168\.|10\.0\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[01]\.' README.md docs/ examples/

# 3. No hostnames.
grep -rnE '[a-z0-9-]+\.local\b|[a-z0-9-]+-nas\b|qnap|hostname' README.md docs/ examples/

# 4. No firmware or vendor specifics that single out one host.
grep -rnE 'J1900|TS-X51|TS-25[15]|Celeron J1900' README.md docs/ examples/
```

If any of these match, edit the offending line to use placeholders
(`${DATA}/...`, `<lan-iface>`, `LOCAL_IPV4_*`, "low-power host")
before committing. The principle is: a reader of this repo who
is *not* the author should learn nothing about the author's specific
network, disk layout, hardware vendor or firmware revision.

Operator-only values — actual IP addresses, host paths, credentials,
SSH ports, DDNS names — belong in the operator's private
configuration (`docker-compose.override.yml`, `.env`, host scripts)
and never in this repo.

## License

MIT
