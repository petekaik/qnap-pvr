# Optional EPG grabbers

The core PVR stack (`compose.yml`) assumes DVB-T/T2 OTA EPG from TVHeadend is sufficient. When that is not the case — for example with IPTV tuners or when richer programme metadata is needed — these example configurations add alternative EPG sources.

## Sibling project

For DVB tuner driver support on QNAP hardware, see the companion project:

**https://github.com/petekaik/qnap-dvb**

## Examples included

| Directory | Source | Notes |
|-----------|--------|-------|
| `examples/epg-grabber/` | iptv-org/epg | Node-based XMLTV grabber that maps iptv-org channels to a local playlist |
| `examples/webgrabplus/` | WebGrab+Plus | .NET-based grabber with site-specific `WebGrab++.config.xml` |

## Usage

Each example is a standalone `compose.yml` fragment. Add the service block to your main `compose.yml` or start it separately with:

```bash
cd examples/epg-grabber
docker compose -f compose.yml up -d --build
```

## Important notes

- The `epg-grabber` container writes to `/output/guide.xml`. Mount that to a location TVHeadend can read, or use the TVH XMLTV socket (`/tvh-config/epggrab/xmltv.sock`) as shown in the example entrypoint.
- The `webgrabplus` container requires a .NET 9 runtime. The provided `install-dotnet.sh` init script installs it automatically at container start-up. The script is idempotent, so Watchtower updates do not break it.
- These are **examples**: channel lists, site IDs and source sites must be adapted to your region and TVHeadend channel names.
