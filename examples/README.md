# Optional EPG grabbers

The core PVR stack (`compose.yml`) assumes DVB-T/T2 OTA EPG from
TVHeadend is sufficient. When that is not the case — for example with
IPTV tuners, when richer programme metadata is needed, or when
scraping from a non-OTA source — these example configurations add
alternative EPG sources.

## Sibling project

For DVB tuner driver support on QNAP hardware, see the companion
project:

**https://github.com/petekaik/qnap-dvb**

## Examples included

| Directory                | Source            | Notes                                                          |
|--------------------------|-------------------|----------------------------------------------------------------|
| `examples/epg-grabber/`  | iptv-org/epg      | Node-based XMLTV grabber that maps iptv-org channels to a local playlist |
| `examples/webgrabplus/`  | WebGrab+Plus      | .NET-based grabber with site-specific `WebGrab++.config.xml`   |

## Usage

Each example is a standalone `compose.yml` fragment. You can either
add the service block to the main `compose.yml`, or run it
side-by-side with the main stack:

```bash
cd examples/epg-grabber
docker compose -f compose.yml up -d --build
```

The example `compose.yml` files deliberately do **not** depend on the
main `compose.yml` so you can choose to deploy or skip each one
independently. Place an `.env` file in each example directory if the
example container reads secrets (none of the included examples do,
but a hand-edited one might).

## Important notes

- The `epg-grabber` example writes to `/output/guide.xml`. Mount that
  to a location TVHeadend can read, or use the TVH XMLTV socket
  (`/tvh-config/epggrab/xmltv.sock`) as shown in the example
  entrypoint.
- The `webgrabplus` example requires a .NET 9 runtime. The provided
  `install-dotnet.sh` init script installs it automatically at
  container start-up. The script is idempotent, so Watchtower
  updates do not break it.
- These are **examples**: channel lists, site IDs and source sites
  must be adapted to your region and TVHeadend channel names.

## Documenting changes to examples

Examples evolve alongside the main stack. When you change an example,
also update this README so a reader knows:

  - which compose fragment applies to the current main `compose.yml`,
  - what `.env` entries (if any) the example needs,
  - which paths the example reads or writes,
  - whether the example uses host cron or container cron.

The examples/ subtree is part of the same repo and follows the same
review and commit hygiene as the rest of the project.
