#!/usr/bin/env python3
"""Check whether a recording should skip comskip based on its channel.

Reads the TVHeadend DVR log files and the commercial-free channel list
(written by comskip-single.sh from config.yaml). Returns 0 if the
recording is on a commercial-free channel (e.g. YLE), otherwise 1.

Usage: check-channel.py <recording_path> [channels_file]
"""

import json
import os
import sys
from pathlib import Path

TVH_LOG_DIR = Path("/config/dvr/log")


def load_channels(channels_file: str) -> set:
    """Load the commercial-free channel list. One name per line, blank lines ignored."""
    try:
        with open(channels_file, "r", encoding="utf-8") as f:
            return {line.strip() for line in f if line.strip()}
    except OSError:
        return set()


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
        # Fallback: parent-only match.
        for f in data.get("files", []):
            fpath = Path(f.get("filename", ""))
            if str(fpath.parent) == target_parent:
                candidates.append((log_file.stat().st_mtime, data))

    if candidates:
        return candidates[0][1].get("channelname", "")
    return ""


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        print("Usage: check-channel.py <recording_path> [channels_file]", file=sys.stderr)
        sys.exit(2)
    recording_path = sys.argv[1]
    channels_file = sys.argv[2] if len(sys.argv) == 3 else "/etc/comskip/config.yaml"
    # Fall back to config.yaml parsing if channels_file doesn't exist.
    if not os.path.isfile(channels_file):
        try:
            import yaml
            with open("/etc/comskip/config.yaml") as f:
                data = yaml.safe_load(f) or {}
            channels = set(data.get("commercial_free_channels", []))
        except (ImportError, OSError):
            channels = set()
    else:
        channels = load_channels(channels_file)

    channel = find_channel_name(recording_path)
    print(channel)
    if channel in channels:
        sys.exit(0)
    sys.exit(1)