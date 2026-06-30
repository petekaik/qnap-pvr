# pvr-tvhd — TVH fork with Post-Processing tab

## Overview

This is **not** a standalone build. It is the *source tree* of the
qnap-pvr fork of Tvheadend. The actual build happens via the
upstream `Dockerfile` in `tvh-src/`, which compiles TVH from source
and bakes our `postproc.js` module into the webui's `tvh.js.gz`
bundle.

## What's in the fork

Three files in `tvh-src/src/webui/static/app/` are patched relative
to upstream:

1. **`postproc.js`** (new file, 12.5 KB)
   - `tvheadend.postproc.dvr(panel, index)` — adds a
     "Post-Processing" tab to the DVR view with two subtabs
     (Comskip and Transcode), each showing the queue + done list.
   - `tvheadend.postproc.status(panel)` — adds a "Post-Processing"
     KPI panel to the Status view (4-6 cards: queue counts,
     done counts, 24h failures).
   - Polls `pvr-queue-exposer:8765/api/*` every 10 seconds.

2. **`dvr.js`** (4 lines added at line ~1203)
   ```js
   if (tvheadend.postproc) {
       tvheadend.postproc.dvr(p, 6);
   }
   ```

3. **`status.js`** (4 lines added at line ~836)
   ```js
   if (tvheadend.postproc) {
       tvheadend.postproc.status(panel);
   }
   ```

One build-system file:

4. **`Makefile.webui`** (2 lines added at line ~154)
   ```
   # qnap-pvr fork: Post-Processing tab module (queue + status panels)
   JAVASCRIPT += $(ROOTPATH)/app/postproc.js
   ```
   This is **the critical patch** — without it, `postproc.js` is
   dropped into the source tree but never bundled into `tvh.js.gz`,
   so the browser never receives it. TVH's webui is a precompiled
   bundle; you cannot add modules at runtime by just dropping a
   file in.

One image-layer file:

5. **`support/container-entrypoint.sh`** (replaces upstream's
   entry script in the runner stage)
   ```sh
   #!/bin/sh
   set -eu

   if [ -d /config ]; then
       exec tvheadend --config /config "$@"
   else
       exec tvheadend "$@"
   fi
   ```
   The upstream `Dockerfile` declares `VOLUME /var/lib/tvheadend`,
   so by default Compose creates an anonymous Docker volume there
   and TVH starts with an empty runtime configuration. The webui
   returns **403 Forbidden** with `[ERROR] access: No access
   entries loaded` because there are no access control entries,
   no DVR config, no EPG. The bind mount in `compose.yml` to
   `/config` is unused.
   
   Fix: point TVH at our persistent config tree with its native
   `--config` flag. We replace the upstream entry script in the
   runner stage with this wrapper, and the webui starts working.

## How to rebuild

The fork must be rebuilt any time upstream TVH ships a new release
(touch any of `postproc.js`, `dvr.js`, `status.js`, or
`Makefile.webui` and rebuild).

```bash
# 1. Refresh upstream source
cd tvh-src
git pull --ff-only

# 2. Re-apply the patches
cp ../pvr-tvhd/rootfs/usr/share/tvheadend/src/webui/static/app/postproc.js \
   src/webui/static/app/postproc.js

# Apply the dvr.js + status.js + Makefile.webui patches by hand or
# with a tool like `patch -p1`. See git log for the exact diffs.

# 3. Build (substitute the actual TVH source directory used on
#    the host; in this repo it lives next to the project root)
ssh storage "export PATH=/share/CACHEDEV1_DATA/.qpkg/container-station/bin:\$PATH; \
  cd <DATA>/tvh-src; \
  docker build -t pvr-tvheadend:built --build-arg ALPINE_VERSION=3.20 \
    -f Dockerfile ."

# 4. Restart
cd <DATA>
docker compose up -d tvheadend
```

`<DATA>` is the directory where the project is checked out on the
host (see `.env.example`).

A full build takes ~12 minutes on a low-power x86_64 host (down
from ~30 minutes on the first build because Docker caches the
builder stage).

## Why a full source build?

TVH's webui is built into a single gzipped bundle
(`src/webui/static/tvh.js.gz`, ~300 KB) at `make install` time.
The browser receives ONLY that bundle — it does not load
individual `.js` files from `static/app/`. Therefore you cannot
patch TVH at runtime by mounting a host file over the image: the
patched file is ignored.

The alternatives we rejected:

- **Patching `tvh.js.gz` at runtime** (decompress, splice in our
  module, recompress). Possible but fragile — the bundle format
  is minified and a single mis-aligned byte breaks everything.
  Also requires keeping a binary patcher script in sync with the
  upstream bundle.
- **Proxy injection** (nginx rewrites HTML to add a `<script>`
  tag). Adds another network hop and another failure mode for
  little benefit.
- **Plugin system** (TVH does not have one for the webui).

A full source build is the simplest correct option.

## Trade-offs

- **Build time** is the main cost (~12 min for incremental rebuilds
  on the QNAP, ~30 min for first builds). Mitigated by Docker layer
  caching — the `builder` stage rebuilds from scratch only when
  `tvh-src/` changes.
- **Disk space** — the `pvr-tvheadend:built` image is ~220 MB
  versus ~700 MB for the `lscr.io/linuxserver/tvheadend` based
  image (because we skip the build-only layers).
- **Maintenance** — patches to upstream files must be re-applied
  after `git pull`. The patch surface is small (4 lines × 2 files
  + 1 file new file + 2 lines in Makefile) so this is a 5-minute
  job per upstream release.

## Verification

After rebuilding, verify the patch is in the bundle:

```bash
docker run --rm pvr-tvheadend:built \
    sh -c 'gunzip -c /usr/local/share/tvheadend/src/webui/static/tvh.js.gz | grep -c tvheadend.postproc'
# Expected output: 3 (moduleload + dvr call + status call)
```

After starting the container, verify the network path:

```bash
docker exec tvheadend wget -q -O- http://pvr-queue-exposer:8765/api/healthz
# Expected output: { "status": "ok", "ts": ... }
```

In the browser, the Post-Processing tab should appear in the
Digital Video Recorder view, and a Post-Processing panel in the
Status view.