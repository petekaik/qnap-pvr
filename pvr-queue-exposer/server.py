#!/usr/bin/env python3
"""
pvr-queue-exposer HTTP-palvelin.

Lukee PVR-post-processing-jonot ja lokit, palauttaa JSON-muodossa.
Ei kirjoita queue-tiedostoja (read-only MVP) — FP1 laajentaa
POST-endpointeilla (skip-queue, trigger-pool).
"""

import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

# Polut — tulevat ympäristömuuttujista compose.yml:stä.
# Oletukset vastaavat tuotannon polkuja mountattuina
# kontin sisään.
COMSKIP_QUEUE = os.environ.get("COMSKIP_QUEUE", "/comskip/queue/comskip-queue.jsonl")
COMSKIP_DONE = os.environ.get("COMSKIP_DONE", "/comskip/queue/comskip-queue.done")
COMSKIP_LOG = os.environ.get("COMSKIP_LOG", "/comskip/queue/comskip.log")

TRANSCODE_QUEUE = os.environ.get("TRANSCODE_QUEUE", "/transcoder/queue/transcode-queue.jsonl")
TRANSCODE_DONE = os.environ.get("TRANSCODE_DONE", "/transcoder/queue/transcode-queue.done")
TRANSCODE_LOG = os.environ.get("TRANSCODE_LOG", "/var/log/transcode-nightly.log")

PORT = int(os.environ.get("PORT", "8765"))


def read_jsonl(path, limit=None):
    """Lukee JSONL-tiedoston, palauttaa listan dict-objekteja.

    Ohittaa virheelliset rivit varoituksella. Jos tiedostoa
    ei ole olemassa, palauttaa tyhjän listan.
    """
    if not os.path.exists(path):
        return []
    rows = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for i, line in enumerate(f):
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    # Ei JSON — ehkä plain-text done-lista joka
                    # päätyi väärään polkuun, tai keskeneräinen rivi.
                    rows.append({"path": line, "_malformed": True})
                if limit and len(rows) >= limit:
                    break
    except OSError:
        pass
    return rows


def read_lines(path, limit=None):
    """Lukee plain-text-tiedoston, palauttaa listan rivejä.

    done-listat ovat plain-text-muodossa (yksi polku per rivi).
    """
    if not os.path.exists(path):
        return []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = [ln.rstrip("\n") for ln in f if ln.strip()]
    except OSError:
        return []
    if limit:
        lines = lines[-limit:]
    return lines


def count_failures(log_path, since_seconds=86400):
    """Laskee FAIL-rivien määrän lokitiedostossa.

    Yksinkertainen heuristiikka — skannaa viimeiset N rivejä
    ja etsii 'FAIL'-alimerkkijonoa. Ei yritä parsia aikaleimoja,
    koska PVR-lokit käyttävät ISO-aikaleimoja ja eri rivejä.
    """
    if not os.path.exists(log_path):
        return 0
    try:
        with open(log_path, "r", encoding="utf-8", errors="replace") as f:
            # Lue viimeiset 1000 riviä — käytännössä kattaa
            # kaikki FAIL-tapahtumat viimeisen 24 tunnin ajalta
            # (PVR kirjoittaa FAIL-rivin vain transkoodauksen
            # epäonnistuessa, joten tämä on rajallinen tapahtuma).
            lines = f.readlines()[-1000:]
    except OSError:
        return 0
    return sum(1 for ln in lines if " FAIL " in ln)


def active_ffmpeg_process():
    """Lukee /proc ja etsii käynnissä olevan FFmpeg-prosessin.

    Palauttaa dictin: {pid, cpu_pct, rss_kb, eteneminen, komento}.
    Eteneminen arvioidaan MP4-tiedoston koosta.

    HUOM: tämä on hostin näkymä FFmpeg-prosesseista, ei transcode-
    kontin. Tämä kontti on macvlan- ja queue-verkkojen ulkopuolella,
    joten se EI NÄE transcode-kontin FFmpeg-prosesseja suoraan.
    Prosessidata haetaan FP1:ssä eri tavalla (esim. SSH-kutsulla
    tai lisäämällä transcode-kontille healthcheck-endpoint).
    """
    # MVP: palauta None (ei dataa vielä)
    return None


class Handler(BaseHTTPRequestHandler):
    """HTTP-pyyntöjen käsittelijä."""

    def log_message(self, format, *args):
        # Hiljennetään oletuslogi (joka menee stderriin).
        # Pidetään kuitenkin debug-loki käytössä.
        pass

    def _send_json(self, payload, status=200):
        body = json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")  # sallitaan TVH-selain
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlparse(self.path).path
        now = int(time.time())

        if path == "/api/healthz":
            self._send_json({"status": "ok", "ts": now})
            return

        if path == "/api/status":
            # Yhteenveto — käytetään Status-välilehden paneelissa
            self._send_json({
                "ts": now,
                "comskip": {
                    "queue_count": len(read_jsonl(COMSKIP_QUEUE)),
                    "done_count": len(read_lines(COMSKIP_DONE)),
                    "failures_24h": count_failures(COMSKIP_LOG),
                },
                "transcode": {
                    "queue_count": len(read_jsonl(TRANSCODE_QUEUE)),
                    "done_count": len(read_lines(TRANSCODE_DONE)),
                    "failures_24h": count_failures(TRANSCODE_LOG),
                    "active": active_ffmpeg_process(),
                },
            })
            return

        if path == "/api/queue/comskip":
            self._send_json({
                "ts": now,
                "items": read_jsonl(COMSKIP_QUEUE),
            })
            return

        if path == "/api/queue/comskip/done":
            self._send_json({
                "ts": now,
                "paths": read_lines(COMSKIP_DONE),
            })
            return

        if path == "/api/queue/transcode":
            self._send_json({
                "ts": now,
                "items": read_jsonl(TRANSCODE_QUEUE),
            })
            return

        if path == "/api/queue/transcode/done":
            self._send_json({
                "ts": now,
                "paths": read_lines(TRANSCODE_DONE),
            })
            return

        if path == "/api/queue/transcode/active":
            self._send_json({
                "ts": now,
                "active": active_ffmpeg_process(),
            })
            return

        # 404
        self._send_json({"error": "not found", "path": path}, status=404)


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"pvr-queue-exposer listening on :{PORT}", flush=True)
    print(f"  comskip queue:  {COMSKIP_QUEUE}", flush=True)
    print(f"  comskip done:   {COMSKIP_DONE}", flush=True)
    print(f"  comskip log:    {COMSKIP_LOG}", flush=True)
    print(f"  transcode queue: {TRANSCODE_QUEUE}", flush=True)
    print(f"  transcode done:  {TRANSCODE_DONE}", flush=True)
    print(f"  transcode log:   {TRANSCODE_LOG}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()