# Changelog

This document tracks notable changes to the PVR stack. It is **not**
auto-generated. Update it whenever a behaviour change ships, even if
the commit message already explains the why — the changelog is for
operators reading `git log` two months later.

The format follows [Keep a Changelog](https://keepachangelog.com/).
Each entry lists the container(s) affected, so an operator can scan
the section for whatever service they are debugging.

## [Unreleased]

### Changed

- **README.md, ARCHITECTURE.md, CONFIGURATION.md, PROFILES.md,
  examples/README.md, docs/diagrams/** rewritten. The previous
  documentation assumed a single `transcoder` image and a cron+nightly
  pipeline; the codebase is now a two-container post-processor
  (`comskip` + `transcode`) plus a shared `pvr-base` build layer.
  Profile table, multi-stream mapping, dvb_teletext handling, and
  the shared `/pvr/tmp` scratch directory are documented in their
  own files.
- Default profile renamed from `high_quality` to `preservation`.
  `high_quality` still exists for backwards compatibility. See
  [`PROFILES.md`](./PROFILES.md).

### Removed

- `COMSKIP_WORKERS` and `TRANSCODE_WORKERS` env knobs. Both pools are
  single-threaded inside their container; scaling is done by adding
  containers, not workers per container. FFmpeg internal threading
  (`-threads 0`, `-filter_threads 0`, libx264 `-threads 0`) replaces
  the multi-worker model.

### Security

- Stripped host-specific details from the documentation. Replaced
  concrete `/share/Programs/pvr/...` paths with `${DATA}/...`,
  concrete IPs (`192.168.1.52` / `.53`) with `LOCAL_IPV4_*`
  placeholders, host-typo jargon (`TS-X51`, `Celeron J1900`,
  `Hauppauge dualHD`) with hardware-agnostic wording. Added a
  `Documentation hygiene` section to `README.md` with `grep`
  checks to run before committing, so the leak does not recur.

### Fixed

- **Comskip restart lost queued work.** Previously, the comskip
  container only ran `tail -F -n 0` on its queue — a naive tail
  loop that does not replay lines already present at start time.
  After a QNAP reboot, TVH's post-recording hook could append
  entries to the queue while comskip was down, and they would
  never be processed. Added a new `entrypoint.sh` that runs three
  subcommands on every container start:
    1. `drain` — process anything already queued.
    2. `prune-done` — drop paths from the done-list whose source
       no longer exists on disk (keeps the list from growing
       forever; lets a reused path be re-processed).
    3. `watch` — start the `tail -F` follower.
  Refactored `comskip-pool.sh` to share a `process_line` core
  between the drain and watch modes, and to expose the three
  subcommands as arguments (`drain`, `prune-done`, `watch`).
  Behaviour with missing source files is unchanged: a missing
  source produces a `SKIP missing source` log line and is not
  added to the done-list.

- **Transcode done-list grew without bound.** The transcode
  container's `entrypoint.sh` already drained the queue on start
  and ran a periodic cron, so it never lost queued work, but its
  done-list grew forever: every recording ever transcoded stayed
  in `transcode-queue.done` even after the source `.ts` was
  deleted in TVH. Added a `prune-done` subcommand to
  `transcode-pool.sh` (mirroring comskip) and called it from
  `entrypoint.sh` immediately before the initial `run`. The
  prune is intentionally only at container boundaries, not on
  the cron tick, so a busy day never sees done-list entries
  disappear mid-flight. Side effect: a later recording that
  reuses the same path is actually re-processed (was silently
  skipped before because the old path was still in done).

### Fixed

- **prune-done crashed when every entry was kept.** The
  `prune-done` subcommand in both `comskip-pool.sh` and
  `transcode-pool.sh` wrote a new done-list to a temp file,
  then `mv`ed it over the original. If every entry was kept
  (none dropped) the temp file was never created, so the `mv`
  failed with `cannot stat ... No such file or directory`. On
  QNAP this printed a noisy error to `transcode-nightly.log`
  and on any future `set -e`-aware shell would have killed
  the script mid-prune. Touch the temp file up-front so `mv`
  always has a source. Caught during the post-restart
  validation run on 2026-06-30.

- **Transcode pool lost queued work after crash.** The drain
  step (`cp queue tmp; : > queue; while read tmp`) was
  vulnerable to mid-flight crashes: if FFmpeg was SIGKILLed
  or the host rebooted before `rm tmp` ran, the next pool
  invocation saw an empty queue plus an orphan tmp with N
  untouched lines — those lines were effectively lost until
  a human manually moved the tmp back. Added a
  `recover-orphaned-tmp` subcommand to `transcode-pool.sh`
  that appends any orphan tmp back into the queue and
  removes it. The entrypoint runs this BEFORE the initial
  pool run, so the recovered lines are part of the same
  drain cycle. Idempotency: a line recovered from tmp whose
  source is also in the done-list is skipped on the next
  pool run by the existing done-check, so the worst case
  is one extra FFmpeg invocation with deterministic output
  going to the same path. Verified on QNAP after restart
  with 5 lines recovered from a previous orphan tmp.
  Comskip does not need an equivalent: its `tail -F`
  follower never writes a tmp file, so there is no orphan
  state to recover.

- **PID-based temp file naming.** The transcode pool's working
  temp was a fixed name (`transcode-queue.jsonl.tmp`), so
  during normal operation it looked identical to an orphan
  tmp left behind by a crashed pool — impossible to tell
  apart without timestamps. Renamed to
  `transcode-queue.$$.tmp` (shell PID), and updated
  `recover-orphaned-tmp` to scan the queue directory for any
  `transcode-queue.*.tmp` that does NOT match its own PID
  and treat those as orphans. Side benefits: (1) two parallel
  pool invocations no longer stomp on each other's temp;
  (2) the directory listing tells you at a glance which
  tmp is "this run's" and which are leftovers.

- **Stale FFmpeg stderr logs cleaned up on container start.**
  Same crash mode as the orphan tmp: when a pool run is
  killed mid-FFmpeg, the pool's own `rm $ffmpeg_log` at
  the end of the loop never runs. Leftover `ffmpeg-*.log`
  files in `/pvr/tmp` are dead-state — they describe a
  process that no longer exists, and just eat disk space.
  Added a `clean-orphaned-ffmpeg-logs` subcommand that
  removes any `ffmpeg-*.log` in the scratch dir whose PID
  suffix does not match the current pool's $$. Called
  from `entrypoint.sh` between `recover-orphaned-tmp` and
  `prune-done`. Verified on QNAP: cleared 5 stale logs,
  freed ~7 MB. The cleanup is logged with the count and the
  bytes reclaimed so the operator can see at a glance how much
  was recovered.

## [Unreleased] — Post-Processing tab in TVH webui

### Added

- **Post-Processing tab in TVH webui.** The MVP for the
  queue dashboard lives in two new pieces plus the small
  patches needed to integrate them with TVH's webui:
  - `pvr-queue-exposer/` — Alpine + Python 3.12 HTTP bridge
    (50 MB image, port 8765). Reads queue JSONL files, done
    lists and log tails from the comskip and transcode queues
    and exposes them as JSON. Endpoints: `/api/status`,
    `/api/queue/<kind>`, `/api/queue/<kind>/done`,
    `/api/log/<kind>?lines=N`, `/api/healthz`. Lives on
    `pvr_internal`, so it sees the queue volumes without
    exposing queue paths to the LAN.
  - `pvr-tvhd/` — TVH fork that bundles a new `postproc.js`
    module into `tvh.js.gz` (TVH's webui is a precompiled
    gzipped bundle — runtime patching is not possible). The
    fork adds a "Post-Processing" tab to the DVR view
    (queue + done lists for comskip and transcode, polled
    every 10 s) and a KPI summary panel to the Status view
    (queue counts, done counts, 24 h failure counts).
    The fork also replaces `support/container-entrypoint.sh`
    in the runner stage so TVH uses `--config /config` and
    sees the persistent config tree that `compose.yml`
    bind-mounts there. Without this wrapper the webui
    returns 403 Forbidden because `VOLUME /var/lib/tvheadend`
    in the upstream Dockerfile otherwise creates an empty
    anonymous volume.
  - `compose.yml` updated so `tvheadend` uses the locally
    built `pvr-tvheadend:built` image (`pull_policy: never`)
    and attaches to both `eth1` and `pvr_internal`. New
    `pvr-queue-exposer` service mounts the queue and log
    directories read-only.
  - `tvh-src/` is gitignored — it is a build dependency,
    not a project source.

  Build takes ~12 min on a low-power x86_64 host; see
  `pvr-tvhd/README.md` for the rebuild procedure and the
  four-file patch surface (the new module, two `if-block`
  additions to existing modules, and one `JAVASCRIPT +=`
  line in `Makefile.webui`).

  MVP scope is **read-only dashboard**. Deferred to later
  feature packs: log tail viewer, skip-queue POST endpoint,
  trigger-pool POST endpoint, log download.

  Verified on QNAP: `postproc` appears 3 times in `tvh.js.gz`
  (module definition + dvr call + status call),
  `pvr-queue-exposer` is reachable from TVH (HTTP 200 on
  `/api/healthz`), and the bundle is loaded by the browser
  unmodified (no proxy, no runtime patching).

### Security

- **Post-processing containers run with no network interface.**
  Comskip and transcode now declare `network_mode: none` in
  `compose.yml`, replacing the previous `internal: true` bridge
  (`pvr_internal`). The old setup still attached every container
  to Compose's default `bridge` network (internal: true only
  blocks the default gateway, not the implicit bridge), so a
  vulnerability in FFmpeg's demuxer or comskip's commercial
  detection code could still reach the LAN, the Jellyfin admin
  API, or the host's other services. `network_mode: none` is
  the most explicit way to say "this container does not network"
  — it removes the attack surface entirely with zero functional
  cost, since communication with TVH happens exclusively through
  shared filesystem queues. The `pvr_internal` network block
  was removed from `compose.yml` and the Mermaid container
  diagram updated. Build-time networking (`docker build`) is
  unaffected — build uses its own network.
