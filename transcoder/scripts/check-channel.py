#!/usr/bin/env python3
"""Check whether a recording should skip comskip based on its channel.

Reads the TVHeadend DVR log files and returns 0 if the recording is on a
commercial-free channel (e.g. YLE), otherwise 1.
"""

import json
import os
import sys
from pathlib import Path

TVH_LOG_DIR = Path("/config/dvr/log")
COMMERCIAL_FREE_CHANNELS = {
    "Yle TV1",
    "Yle TV2",
    "Yle Teema & Fem",
    "Yle TV1 HD",
    "Yle TV2 HD",
    "Yle Teema & Fem HD",
}


def find_channel_name(recording_path: str) -> str:
    target = Path(recording_path)
    target_name = target.name
    target_parent = str(target.parent)
    if not TVH_LOG_DIR.is_dir():
        return ""

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
            if fpath.name == target_name or str(fpath.parent) == target_parent:
                channelname = data.get("channelname", "")
                if channelname:
                    return channelname
        # Also consider entries with no files but matching parent (fallback)
        for f in data.get("files", []):
            fpath = Path(f.get("filename", ""))
            if str(fpath.parent) == target_parent:
                candidates.append((log_file.stat().st_mtime, data))

    if candidates:
        return candidates[0][1].get("channelname", "")
    return ""


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: check-channel.py <recording_path>", file=sys.stderr)
        sys.exit(2)
    channel = find_channel_name(sys.argv[1])
    print(channel)
    if channel in COMMERCIAL_FREE_CHANNELS:
        sys.exit(0)
    sys.exit(1)
