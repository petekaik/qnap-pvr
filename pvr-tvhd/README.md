# pvr-tvhd

qnap-pvr fork of Tvheadend with the Post-Processing webui
tab (FP-1 of BACKLOG.md).

## Status (2026-06-30)

The fork builds and starts. The Docker image
`pvr-tvheadend:latest` contains:

* The Post-Processing webui module
  (`postproc.js` under `rootfs/usr/share/.../static/app/`)
* The `pvr_queue.c` HTTP handler that serves
  `/pvr/api/queue/<kind>`, `/done`, and `/log/<kind>`
* A minimal entrypoint that execs `tvheadend` with the
  caller's args

`docker compose` still references the stock upstream
`lscr.io/linuxserver/tvheadend:latest` because the fork
exits with code 78 when `-c /config` is passed. Starting
without `-c` (and letting `WORKDIR /config` place the
binary next to the bind-mounted config tree) works, but
compose.yml's TVH command is `[/init]`, which doesn't
surface that to the entrypoint yet.

## Files

| Path | Purpose |
|---|---|
| `Dockerfile` | Multi-stage build: builder compiles TVH from `tvh-src/`, runner installs the binary + entrypoint |
| `rootfs/init.d/container-entrypoint.sh` | Minimal entrypoint that execs `tvheadend` |
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
