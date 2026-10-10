# tvhproxy

TVH → HDHomeRun-protokollaemulaattori. Sallii Jellyfin iOS-clientin (ja
muut HDHomeRun-protokollaa ymmärtävät clientit, kuten Plex / Channels
App / HDHomeRun-config-komento) löytää TVH:n lähiverkossa ilman
Jellyfin-palvelinta välikätenä.

Toteutus perustuu [chkuendig/tvhProxy](https://github.com/chkuendig/tvhProxy)
-forkkiin, joka on aktiivisin fork
[jkabergin](https://github.com/jkaberg/tvhProxy) arkistoidusta
alkuperäisestä. Lisätty SSDP-multicast-discovery, joka on kriittinen
jotta Jellyfin/Plex löytävät tämän HDHomeRun-laitteena verkossa.

## Arkkitehtuuri

```
┌─────────────────┐     SSDP (UDP 239.255.255.250:1900)     ┌──────────────────┐
│ Jellyfin iOS    │◄────────────────────────────────────────┤ tvhproxy         │
│ (LAN client)    │   HDHomeRun-protokolla (HTTP :5004)      │ 203.0.113.70     │
└─────────────────┘                                          │ macvlan eth1     │
                                                             └──────┬───────────┘
                                                                    │ HTTP+digest
                                                                    ▼
                                                             ┌──────────────────┐
                                                             │ TVH              │
                                                             │ 203.0.113.52:9981│
                                                             └──────┬───────────┘
                                                                    │ DVB-T
                                                                    ▼
                                                             ┌──────────────────┐
                                                             │ USB DVB-T2      │
                                                             │ adapter          │
                                                             └──────────────────┘
```

## Tiedostot

- `Dockerfile` — Python 3.11-slim + Flask + gevent + requests
- `tvhProxy.py`, `ssdp.py` — upstream-koodi (lievällä patchilla: konfiguroitava
  HDHomeRun-laitemalli .env:stä)
- `hdhomerun_discovery.py` — SiliconDust binary-discovery-protokolla
  (UDP 65001), jotta Jellyfinin "Auto Discover" löytää laitteen
- `/picons/<nimi>.png` — kanavalogot (piconit) HTTP:nä. TVH antaa
  clientille kanavaikonin muodossa `file:///picons/…`, jota mikään
  HTTP-asiakas ei voi noutaa, joten Jellyfin ei saanut logoja lainkaan
  ja lokitti virheen joka kanavasta. Tämä reitti tarjoaa samat
  tiedostot; kuvat on kopioitu tvheadend-imagesta kertaalleen
  (`docker cp tvheadend:/picons ${DATA}/picons`) — ks. pää-README,
  "Channel logos (picons)".
- `requirements.txt` — Python-riippuvuudet
- `templates/device.xml` — UPnP device description
- `.env.example` — konfiguraatiomalli; kopioi `.env`:ksi ja säädä
- `etc/<uuid>` — TVH accesscontrol-tiedosto (IP-allowlisted käyttäjä).
  **Gitignored** — sisältää käyttäjän ja LAN-allowlistin
- `passwd/<uuid>` — TVH passwd-tiedosto (TVHeadend-Hide- + base64 -salasana).
  **Gitignored** — sisältää salasanan. Kopioi hostilta, ks. Käyttöönotto

## Discovery-protokollat

tvhproxy mainostaa itseään kahdella eri protokollalla, koska Jellyfin ja
eri HDHomeRun-clientit käyttävät eri menetelmiä:

| Protokolla | Portti | Kenelle | Paketti |
|---|---|---|---|
| SSDP/UPnP multicast | UDP 1900 | Yleiskäyttö (Plex, Channels App, jotkut Jellyfin-lisäosat) | NOTIFY säännöllisesti |
| SiliconDust binary discovery | UDP 65001 (broadcast) | **Jellyfin** "Auto Discover" | Vastaus broadcast-pyyntöön |

**Tärkeää (2026-09-16)**: Jellyfinin "Auto Discover" käyttää
**SiliconDust-protokollaa, EI SSDP-multicastia**. Aiemmin SSDP:n avulla
löytyi laite joillekin clienteille, mutta Jellyfin tarvitsi URL-syötön
käsin. Lisätty `hdhomerun_discovery.py` joka vastaa
Jellyfinin/C#-koodin lähettämään broadcast-pyyntöön oikealla
binääriprotokollalla (frame type 0x0003, TLV-tagit DEVICE_TYPE,
DEVICE_ID, TUNER_COUNT, BASE_URL, DEVICE_AUTH_STR, LINEUP_URL).

## Konfigurointi

### 1. Verkko

tvhproxy tarvitsee oman macvlan-IP:n eth1:llä. Aseta `LOCAL_IPV4_3`
Pääkäyttäjän `.env`-tiedostoon. IP:n täytyy olla macvlan-IPRangen
sisällä (203.0.113.64/27, eli 203.0.113.64–.95).

### 2. TVH-käyttäjä

TVH vaatii tvhproxy-kutsuille autentikoidun käyttäjän, jolla on
IP-allowlist storage-aliverkkoon.

**Web-UI-luonti on pakollinen.** Käsin luodut JSON-tiedostot
eivät toimi LSIO:n tvheadend-image:lla — TVH lukee tiedostot
vain ensimmäisellä käynnistyskerralla ja sen jälkeen access_entries-
ja passwd_entries-listat synkronoituvat sisäisesti, eikä
myöhemmin tehdyt tiedostomuutokset tule voimaan ilman kontin
uudelleenkäynnistystä JA TVH:n sisäisen tilan nollaus (esim. poista
ja luo uusi käyttäjä web-UI:sta).

**ERITTÄIN TÄRKEÄ** (löydetty 2026-09-16): TVH-käyttäjän `webui`-asetus
täytyy olla **päällä** (true), jotta mikään API-kutsu toimii — myös
pelkät `ACCESS_ANONYMOUS`-maskin omaavat kutsut kuten
`/api/serverinfo`. Tämä on LSIO-image:n erityispiirre. Vaikka
web-UI-käyttö ei ole tarpeen, asetus täytyy olla päällä.

Web-UI-asetukset:
- Username: `tvhproxy`
- Password: the value of `TVH_PASSWORD` in your `.env`
  (tai generoi uusi, ks. .env.example)
- Allowed networks: `203.0.113.50/32,127.0.0.1/32,203.0.113.70/32`
- Streaming: basic, htsp, advanced
- **Web interface: ☑ PÄÄLLÄ** (pakollinen!)
- Admin: ☐ ei

Salasanan uudelleenkoodaus:
```bash
python3 -c "import base64; print(base64.b64encode(b'TVHeadend-Hide-' + b'NEW_PASSWORD').decode())"
```

**tvhproxy.py:n bugi**: tvhProxy.py ei pura user:password@host -URL:sta
käyttäjätunnusta ja salasanaa, vaan lukee ne erillisinä `TVH_USER`-
ja `TVH_PASSWORD`-ympäristömuuttujista. Jos näitä ei ole
määritelty, `HTTPDigestAuth('', '')` lähettää tyhjän autentikoinnin
ja TVH vastaa 401 → lineup.json palauttaa 500.
.env-tiedoston `TVH_URL` ei yksinään riitä — tarvitset myös erilliset
`TVH_USER` ja `TVH_PASSWORD`. compose.yml:ään on lisätty
`environment:`-osio joka varmistaa nämä.

### 3. .env-asetukset

Kopioi `.env.example` → `.env` ja säädä:
- `TVH_URL` — TVH:n HTTP-API + tvhproxy-käyttäjä
- `TVH_PROXY_URL` — julkinen URL-osoite jonka SSDP mainostaa
- `LOCAL_IPV4_3` — macvlan-IP

## Käyttöönotto

```bash
# 1. Lisää LOCAL_IPV4_3 .env-tiedostoon
echo "LOCAL_IPV4_3=203.0.113.70" >> /path/to/pvr/.env

# 2. Kopioi tvhproxy-konfiguraatio
scp -r .env tvhproxy admin@your-host:/path/to/pvr/tvhproxy/

# 3. Luo TVH-käyttäjä web-UI:sta (Configuration → Users → Add)

# 4. Käynnistä
cd /path/to/pvr && docker compose up -d tvhproxy

# 5. Testaa
curl http://203.0.113.70:5004/discover.json
# → 200 OK, HDHomeRun-metatiedot
```

## Vianmääritys

### "Address already in use" kontin käynnistyksessä
Macvlan-IP ei ole IPRangen sisällä. Tarkista `docker network inspect eth1`
ja valitse IP range-alueelta.

### lineup.json palauttaa 500
Yleisin syy ei ole TVH-käyttäjä vaan puuttuvat `TVH_USER` / `TVH_PASSWORD`
projektin `.env`-tiedostossa. `compose.yml` välittää ne kontille
`environment:`-lohkolla, joka **ohittaa** `tvhproxy/.env`:n — jos ne
puuttuvat, arvoksi tulee tyhjä merkkijono, TVH vastaa 401 ja
`_get_channels()` palauttaa `None`. Oire on osittainen: `/discover.json`
vastaa yhä 200, joten kontti näyttää terveeltä ja Jellyfin löytää
virittimen, mutta kanavalista katoaa. Tarkista:

```bash
docker inspect tvhproxy --format '{{range .Config.Env}}{{println .}}{{end}}' | grep TVH_USER
```

Jos arvo on tyhjä, lisää molemmat avaimet projektin `.env`:iin (arvojen
on vastattava `TVH_URL`:ään upotettuja tunnuksia) ja aja
`docker compose up -d tvhproxy`.

Jos tunnukset ovat kunnossa, vika on itse TVH-käyttäjässä. Tarkista
TVH:n lokit:
```bash
docker logs tvheadend | grep -E "ERROR|access"
```
Luo käyttäjä uudestaan web-UI:sta.

### SSDP-paketit eivät lähde
Tarkista että kontti on macvlan-verkossa ja port 1900 on auki:
```bash
docker exec tvhproxy ss -ulnp | grep 1900
```

### Jellyfin "Auto Discover" ei löydä laitetta

Jellyfin käyttää UDP broadcast -porttia 65001 (SiliconDust-protokolla).
Tarkista että tvhproxy kuuntelee sitä:
```bash
docker logs tvhproxy | grep -E 'discovery|65001'
```
Ja testaa manuaalisesti:
```bash
python3 -c "
import socket
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
sock.bind(('0.0.0.0', 0))
sock.settimeout(3)
disc = bytes([0, 2, 0, 12, 1, 4, 255, 255, 255, 255, 2, 4, 255, 255, 255, 255, 115, 204, 125, 143])
sock.sendto(disc, ('255.255.255.255', 65001))
print(sock.recvfrom(2048)[1])
"
```
Jos vastausta ei tule, tarkista että kontissa on macvlan-verkko (ei
bridge) — broadcast ei kulje bridge-verkon läpi.

### Lisää tvhproxy manuaalisesti jos Auto Discover ei toimi
Mene Jellyfin → Dashboard → Live TV → Tuner Devices → Add Tuner Device:
- Type: HD Homerun
- URL: `http://<tvhproxy-IP>:5004`

### EPG-ohjelmaopas ei näy Jellyfinissä

Jellyfin ei hae EPG:tä automaattisesti HDHomeRun-laitteilta. tvhproxy
tarjoaa XMLTV-syötteen osoitteessa `http://<tvhproxy-IP>:5004/epg.xml`
(3262 ohjelmaa, 23 kanavaa). Asenna se:

1. Dashboard → Live TV → TV Guide Providers
2. + Add XMLTV
3. Name: `TVH XMLTV`
4. Path/URL: `http://203.0.113.70:5004/epg.xml`
5. Save

tvhproxy hakee XMLTV:n TVH:sta ja välittää sen Jellyfinille. TVH:n
oma `http://203.0.113.52:9981/xmltv.xml` toimii myös, mutta tvhproxy:n
kautta on nopeampi koska se puskuroi tuloksen.

### Tvheadend kaatuu signal 11:llä (CRASH)

Tvheadend tekee myös HDHomeRun-discoveryä verkossa ja **kaatuu** jos se
löytää tvhproxy-kontin HDHomeRun-laitteena. Tämä on LSIO-imagen
bugi (libhdhomerun+lite+bcr crashaa). Korjaus: tvhproxy tunnistaa
TVH:n IP:n `TVH_URL`:sta ja jättää vastaamatta sen lähettämiin
discovery-pyyntöihin. TVH jää käyntiin, mutta sen HTTP-palvelin
saattaa silti aluksi resetoida yhteyksiä (yhteydet palautuvat kun
TVH stabiloituu).

Jos TVH on kaatunut:
```bash
docker logs tvheadend | grep "Signal: 11"
```
Pitkän kaatumiskierteen jälkeen TVH käynnistyy yleensä 30-60s
sisällä kunhan discovery-pyyntöjä ei enää tule.
```
