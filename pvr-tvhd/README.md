# pvr-tvhd

qnap-pvr fork of Tvheadend with the Post-Processing webui
tab (FP-1 of BACKLOG.md).

## Status (2026-06-30) — LIVE

The fork is now in production use on QNAP.

* compose.yml points at `pvr-tvheadend:latest`
* The container uses `command: ["-c", "/var/tvheadend"]`
  and `working_dir: /var/tvheadend`. The host directory is
  bind-mounted at both `/config` and `/var/tvheadend`;
  TVH reads it via `/var/tvheadend` because the
  `realpath("/config")` call inside `config_boot` exits
  78 under this Alpine 3.20 + QNAP kernel combination.
  See `~/.hermes/plans/postproc-webui.md` for the
  investigation.
* Healthcheck passes (`/dev/dvb/adapter*` present)
* HTTP/HTSP servers on 9981/9982
* EPG, DVB adapters, recordings all functional
* `/pvr/api/queue/<kind>` and `/pvr/api/log/<kind>`
  respond (HTTP 401, same as the rest of the TVH API
  without auth)

## Files

| Path | Purpose |
|---|---|
| `Dockerfile` | Multi-stage build: builder compiles TVH from `tvh-src/`, runner installs the binary + entrypoint |
| `rootfs/init.d/container-entrypoint.sh` | Minimal entrypoint that execs `tvheadend` with the caller's args |
| `rootfs/usr/share/tvheadend/src/webui/static/app/postproc.js` | The webui module loaded by the TVH bundle |
| `pvr_queue.c` / `pvr_queue.h` | Reference copies of the C side of the fork (the live copy lives in `tvh-src/`) |

## Build

`build.sh` rsyncs `tvh-src/` into `pvr-tvhd/tvh-src/`
before the Docker build so the builder stage has the
source tree, and cleans it up afterwards.

```sh
./build.sh
```

## Why a fork

TVH ships a precompiled `tvh.js.gz` bundle. Adding a new
webui module to the bundle requires recompiling the
upstream build. The `pvr_queue.c` HTTP handler is the
backend for that module.

See `~/.hermes/plans/postproc-webui.md` for the
background and `BACKLOG.md` for the feature breakdown.
