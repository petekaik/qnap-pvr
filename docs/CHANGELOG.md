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
