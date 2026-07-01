# pvr-tvhd

qnap-pvr fork of Tvheadend with the Post-Processing webui
tab (FP-1 of BACKLOG.md).

## Status (2026-06-30) — C-tier works, webui pending

The fork's HTTP backend (`/pvr/api/queue/*` and
`/qnap-api/queue/*`) is implemented in C and reachable,
but the webui menu registration is not yet visible in
the browser. The investigation trail is in this README
and in commit messages.

### What works

* `compose.yml` points at `pvr-tvheadend:latest`
* The container uses `command: ["-c", "/var/tvheadend"]`
  and `working_dir: /var/tvheadend` — the bind-mount
  sidesteps an Alpine 3.20 + QNAP `realpath("/config")`
  bug (exit 78 otherwise).
* `pvr_queue.c` is in the binary (`pvr_api_handler`
  is a known symbol, `/pvr/api` appears 2 times).
* `postproc.js` is in `tvh.js.gz` bundle (3 hits).
* `dvr.js` and `status.js` patches that register the
  postproc tabs are in the bundle (`dvrComskip` 4
  hits, `tvh_postproc` 23 hits).
* `tvh_postproc.dvrComskip`, `dvrTranscode`, `status`,
  etc. are all defined and reachable from the
  browser console.
* Healthcheck passes; HTTP/HTSP servers on 9981/9982;
  EPG, DVB adapters, recordings all functional.

### What's broken

* `/pvr/api/queue/<kind>` and `/qnap-api/queue/<kind>`
  return **404** from the browser and curl. The same
  path returns 401 from `wget` inside the container.
  This looks like a macvlan or `http_path_add` route
  resolution bug specific to the `/pvr/api` and
  `/qnap-api` path prefixes.
* Only the EPG tab is visible in the browser. The
  DVR / Status / Configuration tabs don't render,
  even though the registration code is in the
  bundle. The TVH log shows a Comet failure:
  `Failed to construct 'Element': Illegal constructor`
  — a TVH/legacy-ExtJS issue with modern browsers,
  unrelated to FP-1.
* postproc.js's `fetchQueue()` calls receive 404
  responses, so the dashboard panels can't render
  data. The empty-state fallback ("no rows") does
  show, which is why the panels look like they
  exist but are empty if you can see them.

### Why this is hard

1. `pvr_api_handler` is in the binary, but the HTTP
   route doesn't resolve. The path-matching code
   in `src/http.c` does a `strncmp` against registered
   paths; we don't know why `/pvr/api/queue` and
   `/qnap-api/queue` don't match.
2. The webui bundle is built into the binary via
   MKBUNDLE; the bundles we measure inside the
   running container are stale (Jun 30 20:13, from
   the very first fork build). Docker's COPY layer
   cache keeps serving the same `tvh.js.gz` even
   though the source has changed.
3. The Comet-failure / Element-constructor error is
   a TVH upstream issue, not something we can fix
   in this fork without re-architecting TVH's
   webui bootstrap.

### Next steps

* Investigate why `/pvr/api` and `/qnap-api`
  routes resolve to 404 even though the handler
  is linked. Possible avenues: `http_path_add` is
  being called too late (after the HTTP server
  starts); there's a different prefix being
  prepended in `http_path_add_modify` when
  `tvheadend_webroot` is set.
* Build with `RUN --mount=type=cache` to
  invalidate the MKBUNDLE layer cache.
* Or: switch to runtime-bundle-patch (decode
  `tvh.js.gz`, append a postproc-IIFE, re-encode).
  See `~/.hermes/plans/postproc-webui.md`.

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

See `~/.hermes/plans/postproc-webui.md` for the
background and `BACKLOG.md` for the feature breakdown.
