# FP-1 Post-Processing Webui: Investigation Report

**Status (2026-07-01)**: Paused. TVH reverted to stock
`lscr.io/linuxserver/tvheadend:latest`. The C-tier of
the fork is verified working; the webui-tier ran into
an HTTP routing wall that needs upstream-architecture
research. All artifacts kept in-tree for the next
iteration.

## Goal

Build a `qnap-pvr` fork of Tvheadend that adds a
Post-Processing tab to the webui, showing comskip and
transcode queue items + log tails. This is FP-1 of
`BACKLOG.md` and the prerequisite for FP-2 (queue
actions) and FP-4 (config editing).

## What was built

The C-tier of the fork is complete and verified:

| Layer | Status | Evidence |
|---|---|---|
| `pvr_queue.c` (10.5 KB, 336 lines) | ✅ In the TVH binary | `strings /usr/local/bin/tvheadend \| grep pvr_api_handler` returns 3 hits |
| `http_path_add("/qnap-api/queue", pvr_api_handler, ACCESS_WEB_INTERFACE)` | ✅ Linked | `strings` returns 2 hits for `/pvr/api` |
| `postproc.js` (8.2 KB) in `tvh.js.gz` | ✅ Bundled | `zcat tvh.js.gz \| grep -c postproc` = 3 |
| `dvr.js` / `status.js` register postproc tabs | ✅ Bundled | `dvrComskip` 4 hits, `tvh_postproc` 23 hits |
| `tvheadend.dvr` is callable from the browser | ✅ Verified | `typeof tvheadend.dvr === "function"` |
| `tvh_postproc.dvrComskip` / `dvrTranscode` / `status` are defined | ✅ Verified | `Object.keys(tvh_postproc)` returns all 12 functions |

The Docker side is also complete:

| File | Purpose |
|---|---|
| `pvr-tvhd/Dockerfile` (4.4 KB) | Multi-stage Alpine 3.20 build |
| `pvr-tvhd/rootfs/init.d/container-entrypoint.sh` (440 B) | Minimal entrypoint that `exec`s `tvheadend` |
| `pvr-tvhd/rootfs/usr/share/tvheadend/src/webui/static/app/postproc.js` | The webui module |
| `pvr-tvhd/pvr_queue.c`, `pvr-tvhd/pvr_queue.h` | Reference copies of the C source |
| `pvr-tvhd/README.md` | Status of the fork |

Build pipeline:

- `build.sh` rsyncs `tvh-src/` into the build context
  before `docker build`, and cleans it up afterwards.
- `tvh-src/` is gitignored; it's the working tree
  where the TVH upstream + our patches live. The
  build pulls `postproc.js` from
  `pvr-tvhd/rootfs/usr/share/...` into
  `tvh-src/src/webui/static/app/` automatically so
  the MKBUNDLE step picks it up.

## What was tried and what blocked

### 1. `-c /config` exits 78 in the fork

**Symptom**: `pvr-tvheadend` started as a container
exits with code 78 (`config error`) when `-c /config`
is passed. The `pvr_api_handler` is in the binary,
`http_path_add` is called, but the container dies
before serving any HTTP request.

**Diagnosis** (`config.c:1759` → `settings.c:96`):
`hts_settings_init(confpath)` calls
`realpath(confpath, NULL)`. `realpath("/config")`
returns NULL on this Alpine 3.20 + QNAP combination.
`settingspath` stays NULL, the next
`hts_settings_buildpath()` returns 1, `config.c:1835`
calls `exit(78)`.

**Workaround that worked**: Mount the same host
directory at `/var/tvheadend` instead of (or in
addition to) `/config`, and pass
`-c /var/tvheadend`. `realpath("/var/tvheadend")`
does resolve, TVH starts.

**Why the workaround is needed**: Unknown. The
upstream Containerfile uses `WORKDIR /var/lib/tvheadend`
and `USER tvheadend`, and the linuxserver image uses
s6-overlay. Neither of those reveals why our Alpine
build chokes on `/config` specifically. This is
likely a QNAP kernel/overlayfs interaction.

### 2. Webui tabs don't render — only EPG is visible

**Symptom** (2026-07-01): Even with the C-tier
delivered and the bundle containing the postproc
module, the browser shows only the EPG tab. DVR,
Status, and Configuration are missing.

**Diagnosis** (Playwright, see investigation log
below): The browser console shows

```
Comet failure [e=Failed to construct 'Element':
  Illegal constructor]
```

This is a TVH-upstream bug: TVH's webui bootstrap
uses `new Element(...)` (DOM Level 0 style), which
modern browsers reject with "Illegal constructor".
The webui's comet poller never starts, and that
appears to gate the rest of the webui bootstrap
including the main menu tabs.

**Why this is upstream, not our bug**: The same
error is reproducible against any TVH version
that uses the legacy Comet poller bootstrap. We
didn't touch `comet.c`. A search for `new Element`
in `src/webui/static/app/` finds the call site in
the legacy `comet.js`.

**Workaround attempted**: None within the scope of
this iteration. Possible next-step workarounds:

- Patch `src/webui/static/app/comet.js` to use
  `document.createElement(...)` instead of
  `new Element(...)`. Single-file fix.
- Use `--uidebug` flag which disables the JS
  minification and may load a different code path.

### 3. `/pvr/api/queue/*` and `/qnap-api/queue/*`
return 404 from the browser but 401 from inside the
container

**Symptom** (curl/Playwright): Browser fetches to
`/pvr/api/queue/comskip` and `/qnap-api/queue/comskip`
return 404 with HTML body. Identical fetches from
`wget` inside the container return 401 with Digest
auth headers.

**Why this is hard to debug**: This is an
asymmetric network outcome. The container's view
of the same URL differs from the outside. Two
plausible causes:

1. **macvlan reverse-path filtering**: TVH is on
   the macvlan network `eth1` with IP `192.168.1.52`.
   The QNAP kernel may drop packets from the
   macvlan IP to the same macvlan IP via the
   bridge, depending on `rp_filter` settings.
2. **TVH HTTP path resolution**: `http_path_add`
   registers a path with a given length. If a
   registered path is a prefix of a longer URL
   without the exact-length match, the resolver
   in `http.c:http_resolve` would skip it. We did
   not find a path-length mismatch in our code
   (path is `"/qnap-api/queue"`, length 16, and
   `path[hp_len] == '/'` correctly compares `/`).

**What the next iteration should do**: Use
`strace` (or `ltrace`) inside the container to
observe the `http_resolve()` and `http_path_add()`
calls and see whether `/qnap-api/queue` is
actually in the path list at the time of the
request. If it isn't, the registration isn't
running (or runs too late). If it is, the matcher
has a bug.

### 4. Docker COPY layer cache hides source updates

**Symptom** (multiple times during the iteration):
After editing `pvr-tvhd/rootfs/.../postproc.js`
or `tvh-src/src/webui/static/app/dvr.js`, the new
image still contains the old file. `docker build`
without `--no-cache` doesn't help because the COPY
layer's content-addressable hash doesn't change
when the file's mtime shifts without contents
changing.

**Workaround**: `docker build --no-cache` rebuilds
from scratch. Cost: ~5 min for cached apt layers,
~12 min for fully cold.

**Why this is a recurring trap**: The user-visible
symptom is "I edited the file, rebuilt, and the
behaviour is the same as before." It's easy to
conclude that the edit had no effect when the
real cause is a stale layer cache.

### 5. `realpath("/config")` returns NULL inside
the fork but works on the host

**Symptom**: `realpath /config` in the container
prints `/config` (works). The same call from C
inside `config_boot()` returns NULL.

**Why this is suspicious**: The C and shell
versions of `realpath` should agree. The most
likely explanation is that the C `realpath`
implementation in musl-libc differs slightly
from coreutils' `realpath`. musl's `realpath` is
known to have edge cases with symlink loops and
mount points under overlayfs.

## Investigation log (in chronological order)

The investigation reached the conclusions above
through the following steps, each recorded so
the next iteration can pick up from here.

1. **Initial layout cleanup** — separated
   `comskip/`, `transcoder/`, `pvr-base/`, `scripts/`.
2. **DVB module loader** — QNAP `autorun.sh` +
   `/etc/rcS.d/S98dvb-loader` + watchdog cron.
3. **First TVH fork attempt** —
   `pvr_queue.c` + `http_path_add` + Makefile,
   build succeeds.
4. **VOLUME /var/lib/tvheadend issue** — upstream
   Containerfile declares a volume that overwrites
   the bind mount on recreate. Worked around by
   removing the `VOLUME` directive and using
   `WORKDIR /config`.
5. **`-c /config` exit 78** — discovered via
   test runs. Sidestepped by mounting at
   `/var/tvheadend` and using `command: ["-c",
   "/var/tvheadend"]`.
6. **Compose switch** — TVH container now runs
   on `pvr-tvheadend:latest`.
7. **C-tier verification** — `pvr_api_handler` in
   the binary, `/pvr/api/queue/*` returns 401
   (Digest auth required) — same as the rest of
   the TVH API.
8. **postproc.js MKBUNDLE** — initially missing
   from the bundle because `postproc.js` only
   lived in `pvr-tvhd/rootfs/` and the upstream
   build walks `tvh-src/src/webui/static/app/*.js`.
   Fixed by having `build.sh` copy
   `pvr-tvhd/rootfs/.../postproc.js` into
   `tvh-src/src/webui/static/app/` before rsync.
9. **First attempt to switch compose to fork** —
   the fork image ran but `healthcheck` stayed
   `starting` until rollback. Reverted to
   `lscr.io/linuxserver/tvheadend:latest`.
10. **Re-attempt with `--no-cache`** — image
    builds and runs. `healthcheck: healthy`.
    Recordings work. `/pvr/api/queue/comskip`
    returns 401 (auth required) from the host.
11. **User feedback: only EPG tab visible in
    browser**. Switched to Playwright
    investigation with the credentials from
    `storage:/share/Programs/pvr/.env`.
12. **Playwright found**:
    - `tvheadend.dvr` and `tvheadend.status` exist
      as functions
    - `tvh_postproc` object exists with all 12
      functions
    - Only "Electronic Program Guide" tab is
      rendered
    - Console shows Comet-failure error
    - Fetch to `/pvr/api/queue/*` returns 404 in
      browser, 401 inside container
13. **Tried renaming the route to `/qnap-api/`**
    in case `/pvr/api` was colliding with another
    handler. Same 404 outcome. Reverted to stock
    `lscr.io/linuxserver/tvheadend:latest`.

## Artifacts kept for the next iteration

All of the following are in the repository and
will build and run on a fresh checkout that has
`tvh-src/` populated:

- `pvr-tvhd/Dockerfile` — multi-stage TVH build
- `pvr-tvhd/rootfs/init.d/container-entrypoint.sh`
- `pvr-tvhd/rootfs/usr/share/tvheadend/src/webui/static/app/postproc.js`
- `pvr-tvhd/pvr_queue.c` / `pvr_queue.h`
- `pvr-tvhd/README.md` — current status
- `BACKLOG.md` — FP-1 still open; FP-2/3/4
  blocked on FP-1

The `tvh-src/` working tree is gitignored. It
contains the upstream TVH source plus our
patches (`pvr_queue.c`, `Makefile`, `webui.c`,
`Makefile.webui`, `dvr.js`, `status.js`,
`postproc.js`). Anyone picking this up can
re-create it with:

```sh
git clone --depth 1 https://github.com/tvheadend/tvheadend.git tvh-src
cp -a pvr-tvhd/rootfs/usr/share/tvheadend/src/webui/static/app/postproc.js \
      tvh-src/src/webui/static/app/
cp -a pvr-tvhd/pvr_queue.c tvh-src/src/webui/
cp -a pvr-tvhd/pvr_queue.h tvh-src/src/webui/
# Then apply the patches to Makefile, webui.c,
# Makefile.webui, dvr.js, status.js — see the
# diff between git log of those files at the
# 67e1c4c commit and the unmodified upstream.
./build.sh
```

## Recommended next steps

(For the next model, with better tools.)

1. **Comet fix**: patch `comet.js` to use
   `document.createElement` instead of `new Element`.
   This is upstream TVH, not in our fork, so the
   patch is small. The fix is independent of
   `pvr_queue.c` and postproc.js. **Test this
   first** because it unblocks the entire webui
   rendering.

2. **Route resolution debug**: install
   `strace` in the running container and trace
   `http_resolve` to see whether the registered
   paths are in the lookup table at request
   time. If not, the registration order is wrong.
   If they are, the path-matching code has a bug.

3. **macvlan / reverse-path-filter**: check the
   `rp_filter` setting for the macvlan interface
   on the QNAP host. If it's strict mode, packets
   from the macvlan IP to itself can be dropped.
   Setting it to loose or off may resolve the
   outside-vs-inside 401/404 asymmetry.

4. **Bundle debugging**: add a console.log in
   `postproc.js` that fires as soon as the
   script loads, so the bundle's inclusion is
   visible. Right now we have only `grep -c` on
   the bundle, which doesn't tell us whether the
   module executes or whether it executes but
   fails to register tabs.

5. **Document the path**: `~/.hermes/plans/postproc-webui.md`
   needs to be updated with the Comet and route
   findings, and the BACKLOG.md FP-1 needs to
   be re-scoped against the new blockers.

## Knowledge-base gaps to fill

The next model will benefit from a quick survey
of:

- TVH upstream's HTTP path-matching
  implementation: `src/http.c:http_resolve`.
  Understanding the exact matching algorithm
  (and whether `http_path_add` with the same
  prefix twice is idempotent) is the first
  prerequisite.
- TVH upstream's webui bootstrap sequence:
  which file registers the main menu tabs, in
  what order, and which step depends on the
  Comet poller.
- musl-libc's `realpath` behaviour on
  overlayfs paths — whether there's a known
  bug for `/config` and what the workaround is.
- The relationship between the macvlan IP and
  the bridge in the QNAP kernel. Does
  `rp_filter` apply?

The upstream TVH developer forum, the TVH
GitHub issues, and the linuxserver.io community
forums are the most likely sources.
