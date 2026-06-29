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
