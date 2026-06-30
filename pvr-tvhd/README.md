# pvr-tvhd — TVH fork (rolled-back state)

## Current state

This directory exists as a placeholder for the postproc-webui
fork that is being worked on under
`~/.hermes/plans/postproc-webui.md`. The plan is paused while we
validate the rolled-back state: `compose.yml` uses the stock
`lscr.io/linuxserver/tvheadend:latest` image and the
Post-Processing tab is NOT in the webui.

The `Dockerfile` in this directory is a no-op `FROM
lscr.io/linuxserver/tvheadend:latest` and exists only so
`compose.yml`'s `build.context: ./pvr-tvhd` still resolves. If/when
the plan is executed, this Dockerfile will be replaced with the
fork image's actual build steps.

## Why the rolled-back state, briefly

TVH's webui is a precompiled `tvh.js.gz` bundle served from
`/usr/share/tvheadend/src/webui/static/`. Adding new tabs to it
needs one of:

1. A full source build (~12 min on the QNAP Celeron)
2. A COPY-based extension of `lscr.io/linuxserver/tvheadend`
3. Modifying the upstream `webui.c` to register new HTTP routes

We tried (1) and (2), and both caused regressions to TVH login
and stability (Docker volume markers, UID/PGID mappings,
macvlan/`pvr_internal` interplay). The plan at
`~/.hermes/plans/postproc-webui.md` describes option (3) as the
correct path because it leaves the image and the network layout
unchanged — TVH just serves `/pvr/queue/*` from an in-process
forwarder that talks to `pvr-queue-exposer` over `pvr_internal`.

## Do NOT add patches to this directory

Until the plan is executed and merged, no patched `dvr.js`,
`status.js`, `postproc.js`, or `tvhd-postproc-template.js` should
live here. Doing so is what caused the regression that this
rollback undoes.

## Verification of the rolled-back state

```bash
# Confirm TVH is the upstream image, not a fork:
docker inspect --format '{{.Config.Image}}' tvheadend
# Expected: lscr.io/linuxserver/tvheadend:latest

# Confirm no postproc files are in the image:
docker exec tvheadend ls /usr/share/tvheadend/src/webui/static/app/ | grep -E 'postproc|dvr|status'
# Expected: only `dvr.js` and `status.js` (the upstream copies)

# Confirm the webui serves the login page:
curl -sS -o /dev/null -w '%{http_code}\n' --connect-timeout 5 \\
    http://192.168.1.52:9981/extjs.html
# Expected: 200
```
