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

    Supports Finnish and English listings:
      "Kausi 4, 4/12. Akvarelli."
      "Kausi 31. Jakso 7-22."
      "Jakso 7-10."
      "4/12."
      "Season 4, 4/12."
      "Season 4 Episode 5"
      "S04E04"
      "s02-e03"
      "Kausi 1, 3/4."
    Returns (season, episode) or (None, None) if not found.
    """
    text = f"{title} {subtitle}"

    # "S04E04", "s02-e03" (also "S31E07" etc.)
    m = re.search(r"[Ss]\s*(\d+)\s*[Ee-]\s*(\d+)", text)
    if m:
        return int(m.group(1)), int(m.group(2))

    # "Kausi 4, 4/12" or "Kausi 4. 4/12" or "Kausi 4 4/12"
    m = re.search(r"[Kk]ausi\s*(\d+)[,.]?\s*(\d+)\s*/\s*\d+", text)
    if m:
        return int(m.group(1)), int(m.group(2))

    # "Kausi 31. Jakso 7-22" or "Kausi 31, Jakso 7-22"
    m = re.search(r"[Kk]ausi\s*(\d+)\D+[Jj]akso\s*(\d+)\D", text)
    if m:
        return int(m.group(1)), int(m.group(2))

    # "Season 4, 4/12" or "Season 4 Episode 4"
    m = re.search(r"[Ss]eason\s*(\d+)[,.]?\s*(?:[Ee]pisode\s*)?(\d+)\s*/?\s*\d*", text)
    if m and m.group(2):
        return int(m.group(1)), int(m.group(2))

    # "Jakso 7-22" - take the first episode number
    m = re.search(r"[Jj]akso\s*(\d+)[-\s]\s*(\d+)", text)
    if m:
        return None, int(m.group(1))

    # Bare "4/12." at the start of the subtitle (Finnish short form)
    m = re.search(r"(?:^|[.])\s*(\d+)\s*/\s*\d+", text)
    if m:
        return None, int(m.group(1))

    # English "Episode 5" or "Ep 5"
    m = re.search(r"[Ee]p(?:isode)?\s*(\d+)", text)
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


def write_episode_nfo(nfo_path: Path, meta: dict, title: str, is_movie: bool = False, is_sports: bool = False) -> None:
    subtitle = read_text_field(meta.get("subtitle", {}))
    plot = subtitle or title
    season, episode = parse_season_episode(title, subtitle)
    if season is None:
        season = 1
    if episode is None:
        episode = 1
    aired = unix_ts_to_iso(meta.get("start", 0))

    if is_movie:
        xml = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?\u003e",
            "<movie\u003e",
            f"  <title\u003e{_esc(title)}</title\u003e",
            f"  <plot\u003e{_esc(plot)}</plot\u003e",
            f"  <aired\u003e{_esc(aired)}</aired\u003e",
            "</movie\u003e",
        ]
    elif is_sports:
        xml = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?\u003e",
            "<episodedetails\u003e",
            f"  <title\u003e{_esc(title)}</title\u003e",
            f"  <showtitle\u003e{_esc(title)}</showtitle\u003e",
            f"  <season\u003e{season}</season\u003e",
            f"  <episode\u003e{episode}</episode\u003e",
            f"  <plot\u003e{_esc(plot)}</plot\u003e",
            f"  <aired\u003e{_esc(aired)}</aired\u003e",
            "</episodedetails\u003e",
        ]
    else:
        xml = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?\u003e",
            "<episodedetails\u003e",
            f"  <title\u003e{_esc(title)}</title\u003e",
            f"  <showtitle\u003e{_esc(title)}</showtitle\u003e",
            f"  <season\u003e{season}</season\u003e",
            f"  <episode\u003e{episode}</episode\u003e",
            f"  <plot\u003e{_esc(plot)}</plot\u003e",
            f"  <aired\u003e{_esc(aired)}</aired\u003e",
            "</episodedetails\u003e",
        ]
    nfo_path.write_text("\n".join(xml) + "\n", encoding="utf-8")


def _esc(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def normalise_filename(title: str, subtitle: str, season: int, episode: int, ext: str, is_movie: bool = False) -> str:
    """Return a Jellyfin-friendly filename.

    TVHeadend records everything as $t/$t_%F_%R$n.$x (title + ISO date + time + unique suffix).
    This is short and unique. We then rewrite the transcoded file to a scraper-friendly name:
      - TV episodes: 'Show SxxExx.ext'
      - Movies:      'Title.ext'
    The episode/movie description lives in the NFO, not in the filename.
    """
    if is_movie:
        base = title
    else:
        base = f"{title} S{season:02d}E{episode:02d}"
    return f"{base}{ext}"


def determine_content_type(entry: dict, raw_title: str, season: Optional[int], episode: Optional[int]) -> str:
    """Return one of 'movie', 'series', 'sports', 'news', 'documentary', 'unknown'.

    Uses TVHeadend's own content_type field as the primary signal, which is
    populated from EPG broadcast metadata (not language-specific string parsing).
    Falls back to title prefix only when EPG data is missing.
    """
    ct = entry.get("content_type")
    if ct is not None:
        # DVB EIT content types. Common values seen from Finnish DVB-T EPG:
        # 0  = general / not specified (most series / entertainment)
        # 1  = movie / drama
        # 2  = news / current affairs
        # 3  = entertainment / show
        # 4  = sports
        # 5  = children's / youth
        # 6  = music / ballet / dance
        # 7  = arts / culture (without music)
        # 8  = social / political / economics / current affairs magazine
        # 9  = education / science / factual / nature
        # 10 = leisure / hobbies
        # 11 = special characteristics
        if ct == 1:
            return "movie"
        if ct == 4:
            return "sports"
        if ct in (2, 8):
            return "news"
        if ct in (7, 9):
            return "documentary"
        if ct in (3, 5, 6, 10, 11):
            return "series"  # entertainment / hobby shows treated as series
        if ct == 0 and (season is not None or episode is not None):
            return "series"

    # Fallback: Finnish broadcasters prefix movie titles with "Elokuva:".
    if re.match(r"^[Ee]lokuva[:_]", raw_title):
        return "movie"

    return "unknown"


def generate(recording_path: str, transcoded_path: str) -> str:
    """Create NFOs and return the final Jellyfin-friendly path for the mp4."""
    entry = find_dvr_entry(recording_path)
    if entry is None:
        print(f"[generate-nfo] WARNING: no DVR log entry for {recording_path}", file=sys.stderr)
        return transcoded_path

    raw_title = read_text_field(entry.get("title", {}))
    title = re.sub(r"^[Ee]lokuva[:_]\s*", "", raw_title).strip()
    subtitle = read_text_field(entry.get("subtitle", {}))
    season, episode = parse_season_episode(title, subtitle)
    content_type = determine_content_type(entry, raw_title, season, episode)
    is_movie = content_type == "movie"
    is_sports = content_type == "sports"

    if season is None and not is_movie and not is_sports:
        season = 1
    if episode is None and not is_movie and not is_sports:
        episode = 1

    src = Path(transcoded_path)
    ext = src.suffix
    show_dir = src.parent

    new_name = normalise_filename(title, subtitle, season, episode, ext, is_movie=is_movie)
    dst = show_dir / new_name

    if not is_movie:
        # Sports, news etc. also get a tvshow.nfo so Jellyfin treats the folder as a series.
        write_tvshow_nfo(show_dir, title)
    write_episode_nfo(show_dir / (new_name.replace(ext, ".nfo")), entry, title, is_movie=is_movie, is_sports=is_sports)

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
