FROM python:3.11-slim

# tvhproxy — TVH → HDHomeRun-protokollaemulaattori.
#
# Perustuu chkuendig/tvhProxy-forkkiin (joka on aktiivisin fork
# jkabergin alkuperäisestä, arkistoidusta projektista). Lisätty
# SSDP-multicast-discovery, joka on kriittinen jotta Jellyfin/Plex
# löytävät tämän HDHomeRun-laitteena verkossa.
#
# Kontin vastuut:
#   - Kuunnellaan HDHomeRun-protokollan pyyntöjä portissa 5004
#     (HTTP, /discover.json, /lineup.json, /stream/...)
#   - Lähetetään SSDP-multicast-paketteja UDP 239.255.255.250:1900
#     jotta lähiverkon laitteet löytävät tämän automaattisesti
#   - Vastataan SiliconDust binary-discovery -protokollaan UDP 65001,
#     jotta Jellyfinin "Auto Discover" -toiminto löytää tämän ilman
#     käyttäjän manuaalista URL-syöttöä
#   - Ohjataan stream-pyynnöt TVH:lle HTTP/HTTP-digest-autentikoinnilla
#
# Verkko: macvlan eth1:llä, kiinteä IP .70 (tvhproxy), TVH .52.
# Multicast toimii koska eth1:llä on 239.255.255.250-ryhmä aktiivinen.

# Runtime healthcheck tarvitsee curl/python -työkalut
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/app

COPY requirements.txt ./
RUN pip3 install --no-cache-dir -r requirements.txt

COPY . .

# Flask HTTP-portti (tvhProxy WSGI)
EXPOSE 5004
# SSDP-multicast (UPnP discovery)
EXPOSE 1900/udp
# HDHomeRun binary discovery (Jellyfin Auto Discover)
EXPOSE 65001/udp

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD curl -sf http://localhost:5004/discover.json || exit 1

CMD ["python3", "./tvhProxy.py"]
