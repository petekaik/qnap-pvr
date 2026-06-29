# pvr-queue-exposer
#
# Pieni HTTP-palvelin joka lukee PVR-post-processing-jonot ja lokit
# ja palauttaa ne JSON-muodossa. Tämä siltaa TVH-kontin (joka
# istuu macvlan-verkossa ja jolla ei ole suoraa pääsyä
# queue-hakemistoihin) ja comskip/transcode-konttien (jotka
# istuvat pvr_internal-verkossa ja joilla on mount queue-hakemistoihin).
#
# Endpoints (kaikki palauttavat JSON):
#
#   GET  /api/status               - yhteenveto kaikista jonoista
#   GET  /api/queue/comskip        - comskip-jonon JSONL-rivit
#   GET  /api/queue/comskip/done   - comskip done-lista
#   GET  /api/queue/transcode      - transcode-jonon JSONL-rivit
#   GET  /api/queue/transcode/done - transcode done-lista
#   GET  /api/queue/transcode/active - aktiivinen FFmpeg-prosessi
#   GET  /api/healthz              - health check
#
# Suojaus: tämä kontti EI OLE macvlan-verkossa (vain pvr_internal),
# joten ulkoverkosta ei ole pääsyä. Pohjimmiltaan tämä on
# "loopback-rajapinta" paikallisten komponenttien välillä.
#
# Tuotantoversiossa tämä korvataan FP1:n myötä POST-endpointeilla
# (skip-queue, trigger-pool). Toistaiseksi read-only.

FROM python:3.12-alpine

# Ei tarvita suuria kirjastoja — Pythonin standardikirjasto
# riittää HTTP-palvelimelle ja JSON-jäsentämiselle.
# Tämä pitää imagen pienenä (~50 MB vs. ~800 MB debianilla).

# Asenna jq debuggausta varten (ei tarvita ajonaikana)
RUN apk add --no-cache jq \
    && adduser -D -u 1000 pvr

WORKDIR /app

# Kopioi vain server.py. Käytämme explicit chmod-komentoa
# (eikä --chmod flagia) koska COPY kunnioittaa lähdetiedoston
# oikeuksia ja paikalliset kehitystiedostot ovat usein 0600.
COPY server.py /app/server.py
RUN chmod 0644 /app/server.py && chown pvr:pvr /app/server.py

USER pvr

EXPOSE 8765

# Health check — käytetään compose healthcheckissä.
# Käytetään 127.0.0.1 (ei localhost), koska Alpine/Docker
# saattaa ratkaista localhostin IPv6:ksi ensin ja wget
# valittaa siitä.
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:8765/api/healthz || exit 1

CMD ["python3", "-u", "/app/server.py"]