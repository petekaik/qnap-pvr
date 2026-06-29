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
