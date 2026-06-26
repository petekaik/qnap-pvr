#!/usr/bin/env python3
"""Generate Jellyfin-compatible NFO metadata for TVHeadend recordings.

Reads the TVHeadend DVR log files from /config/dvr/log and creates:
  - A tvshow.nfo for the series in the destination directory
  - An episodedetails.nfo next to the transcoded .mp4 file

The episode filename is also rewritten to SxxExx format so Jellyfin's
built-in metadata lookup recognises it as a TV episode.
"""

import json
import os
import re
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional, Tuple

TVH_LOG_DIR = Path("/config/dvr/log")
FIN_LANG = "fin"


def parse_season_episode(title: str, subtitle: str) -> Tuple[Optional[int], Optional[int]]:
    """Try to extract season and episode numbers from title/subtitle.

    Finnish TV listings commonly use forms like:
      "Kausi 4, 4/12. Akvarelli."
      "Kausi 31. Jakso 7-22."
      "Jakso 7-10."
      "4/12."
    Returns (season, episode) or (None, None) if not found.
    """
    text = f"{title} {subtitle}"

    # "Kausi 4, 4/12" or "Kausi 4. 4/12" or "Kausi 4 4/12"
    m = re.search(r"[Kk]ausi\s*(\d+)[,.]?\s*(\d+)\s*/\s*\d+", text)
    if m:
        return int(m.group(1)), int(m.group(2))

    # "Kausi 31. Jakso 7-22" or "Kausi 31, Jakso 7-22"
    m = re.search(r"[Kk]ausi\s*(\d+)\D+[Jj]akso\s*(\d+)\D", text)
    if m:
        return int(m.group(1)), int(m.group(2))

    # "Jakso 7-22" - take the first episode number
    m = re.search(r"[Jj]akso\s*(\d+)[-\s]\s*(\d+)", text)
    if m:
        # No season in this form, default later to 1 if we can't find it
        return None, int(m.group(1))

    # Bare "4/12." at the start of the subtitle
    m = re.search(r"(?:^|[.])\s*(\d+)\s*/\s*\d+", text)
    if m:
        return None, int(m.group(1))

    return None, None


def read_text_field(field: dict) -> str:
    """Return the Finnish value from a TVH multilingual string field."""
    if not isinstance(field, dict):
        return str(field) if field else ""
    return field.get(FIN_LANG, field.get("eng", next(iter(field.values()), "")))


def find_dvr_entry(recording_path: str) -> Optional[dict]:
    """Locate the DVR log entry for a recording.

    First try an exact filename match. TVHeadend sometimes rewrites the
    recorded filename slightly (e.g. changing the last word), so fall back
    to matching by the parent directory and the most recent entry there.
    """
    target = Path(recording_path)
    target_name = target.name
    target_parent = str(target.parent)
    if not TVH_LOG_DIR.is_dir():
        return None

    candidates = []
    for log_file in sorted(TVH_LOG_DIR.iterdir(), key=os.path.getmtime, reverse=True):
        if not log_file.is_file():
            continue
        try:
            data = json.loads(log_file.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            continue
        for f in data.get("files", []):
            fname = f.get("filename", "")
            fpath = Path(fname)
            if fpath.name == target_name:
                return data
            if str(fpath.parent) == target_parent:
                candidates.append((log_file.stat().st_mtime, data))

    if candidates:
        # Most recent entry in the same show directory.
        return candidates[0][1]
    return None


def unix_ts_to_iso(ts: int) -> str:
    try:
        dt = datetime.fromtimestamp(ts, tz=timezone.utc).astimezone()
        return dt.strftime("%Y-%m-%d")
    except Exception:
        return ""


def write_tvshow_nfo(show_dir: Path, title: str) -> None:
    nfo = show_dir / "tvshow.nfo"
    xml = [
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>",
        "<tvshow>",
        f"  <title>{_esc(title)}</title>",
        "  <!-- Series metadata is intentionally minimal; Jellyfin looks up the",
        "       title online and fills in plot, posters, genres and cast. -->",
        "</tvshow>",
    ]
    nfo.write_text("\n".join(xml) + "\n", encoding="utf-8")


def write_episode_nfo(nfo_path: Path, meta: dict) -> None:
    title = read_text_field(meta.get("title", {}))
    subtitle = read_text_field(meta.get("subtitle", {}))
    plot = subtitle or title
    season, episode = parse_season_episode(title, subtitle)
    if season is None:
        season = 1
    if episode is None:
        episode = 1
    aired = unix_ts_to_iso(meta.get("start", 0))

    xml = [
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>",
        "<episodedetails>",
        f"  <title>{_esc(title)}</title>",
        f"  <showtitle>{_esc(title)}</showtitle>",
        f"  <season>{season}</season>",
        f"  <episode>{episode}</episode>",
        f"  <plot>{_esc(plot)}</plot>",
        f"  <aired>{aired}</aired>",
        "</episodedetails>",
    ]
    nfo_path.write_text("\n".join(xml) + "\n", encoding="utf-8")


def _esc(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def normalise_filename(title: str, subtitle: str, season: int, episode: int, ext: str) -> str:
    """Return a compact Jellyfin-friendly episode filename like 'Show S01E02.ext'.

    TVHeadend now records as $t/S%snE%en.$x, so we keep the same compact shape.
    Episode description lives in the NFO, not in the filename.
    """
    base = f"{title} S{season:02d}E{episode:02d}"
    return f"{base}{ext}"


def generate(recording_path: str, transcoded_path: str) -> str:
    """Create NFOs and return the final Jellyfin-friendly path for the mp4."""
    entry = find_dvr_entry(recording_path)
    if entry is None:
        print(f"[generate-nfo] WARNING: no DVR log entry for {recording_path}", file=sys.stderr)
        return transcoded_path

    title = read_text_field(entry.get("title", {}))
    subtitle = read_text_field(entry.get("subtitle", {}))
    season, episode = parse_season_episode(title, subtitle)
    if season is None:
        season = 1
    if episode is None:
        episode = 1

    src = Path(transcoded_path)
    ext = src.suffix
    show_dir = src.parent

    # Keep the existing show directory structure but ensure the episode file
    # follows SxxExx naming so Jellyfin metadata lookup kicks in reliably.
    new_name = normalise_filename(title, subtitle, season, episode, ext)
    dst = show_dir / new_name

    write_tvshow_nfo(show_dir, title)
    write_episode_nfo(show_dir / (new_name.replace(ext, ".nfo")), entry)

    if dst != src:
        shutil.move(str(src), str(dst))
        print(f"[generate-nfo] renamed {src.name} -> {dst.name}")
    else:
        print(f"[generate-nfo] kept filename {src.name}")

    return str(dst)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: generate-nfo.py <recording_path> <transcoded_path>", file=sys.stderr)
        sys.exit(1)
    final_path = generate(sys.argv[1], sys.argv[2])
    print(final_path)
