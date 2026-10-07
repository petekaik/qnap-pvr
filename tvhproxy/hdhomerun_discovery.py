# HDHomeRun binary discovery protocol
# Implements the SiliconDust UDP broadcast discovery protocol used by
# Jellyfin (and other libhdhomerun clients) to locate HDHomeRun devices on
# the LAN. This lets Jellyfin's "Auto Discover" button populate the tuner
# list without manually entering the device URL.
#
# Reference: https://github.com/Silicondust/libhdhomerun/blob/master/hdhomerun_pkt.h
#
# Packet format (all multi-byte integers are big-endian):
#   [frame_type: 2] [payload_length: 2] [TLV data: payload_length] [crc32: 4]
#
# TLV encoding (tag-length-value):
#   [tag: 1] [var_length] [value: N]
#   var_length: if MSB clear, single byte. If MSB set, 7 low bits of first
#               byte plus full second byte (little-endian varint).
#
# Discovery request (client -> broadcast 255.255.255.255:65001):
#   frame_type = 0x0002 (DISCOVER_REQ)
#   TLV tags:
#     0x01 DEVICE_TYPE  (uint32, 0xFFFFFFFF = wildcard)
#     0x02 DEVICE_ID    (uint32, 0xFFFFFFFF = wildcard)
#
# Discovery reply (device -> client unicast):
#   frame_type = 0x0003 (DISCOVER_RPY)
#   TLV tags:
#     0x01 DEVICE_TYPE      (uint32, 0x00000001 = TUNER)
#     0x02 DEVICE_ID        (uint32, unique per device)
#     0x10 TUNER_COUNT      (uint8)
#     0x2A BASE_URL         (string, e.g. http://203.0.113.70:5004)
#     0x2B DEVICE_AUTH_STR  (string)
#     0x27 LINEUP_URL       (string, optional)

import logging
import socket
import struct
import threading

logger = logging.getLogger(__name__)

# Frame types
HDHOMERUN_TYPE_DISCOVER_REQ = 0x0002
HDHOMERUN_TYPE_DISCOVER_RPY = 0x0003

# Tags
HDHOMERUN_TAG_DEVICE_TYPE = 0x01
HDHOMERUN_TAG_DEVICE_ID = 0x02
HDHOMERUN_TAG_TUNER_COUNT = 0x10
HDHOMERUN_TAG_LINEUP_URL = 0x27
HDHOMERUN_TAG_BASE_URL = 0x2A
HDHOMERUN_TAG_DEVICE_AUTH_STR = 0x2B
HDHOMERUN_TAG_MULTI_TYPE = 0x2D

# Device types
HDHOMERUN_DEVICE_TYPE_TUNER = 0x00000001
HDHOMERUN_DEVICE_TYPE_WILDCARD = 0xFFFFFFFF

DISCOVERY_PORT = 65001


def _crc32(data):
    """CRC32 matching libhdhomerun's polynomial (used in packet sealing)."""
    crc = 0xFFFFFFFF
    for b in data:
        x = (crc ^ b) & 0xFF
        crc >>= 8
        if x & 0x01: crc ^= 0x77073096
        if x & 0x02: crc ^= 0xEE0E612C
        if x & 0x04: crc ^= 0x076DC419
        if x & 0x08: crc ^= 0x0EDB8832
        if x & 0x10: crc ^= 0x1DB71064
        if x & 0x20: crc ^= 0x3B6E20C8
        if x & 0x40: crc ^= 0x76DC4190
        if x & 0x80: crc ^= 0xEDB88320
    return crc ^ 0xFFFFFFFF


def _write_var_length(n):
    """Encode a var_length per libhdhomerun format."""
    if n < 0x80:
        return bytes([n])
    return bytes([(n & 0x7F) | 0x80, (n >> 7) & 0xFF])


def _write_tlv(tag, value):
    """Build a single TLV (tag + var_length + value)."""
    return bytes([tag]) + _write_var_length(len(value)) + value


def _build_reply(device_id, tuner_count, base_url, device_auth, lineup_url):
    """Build a complete DISCOVER_RPY packet ready for sending."""
    tlv = b''
    tlv += _write_tlv(HDHOMERUN_TAG_DEVICE_TYPE,
                      struct.pack('>I', HDHOMERUN_DEVICE_TYPE_TUNER))
    tlv += _write_tlv(HDHOMERUN_TAG_DEVICE_ID,
                      struct.pack('>I', device_id))
    tlv += _write_tlv(HDHOMERUN_TAG_TUNER_COUNT, bytes([tuner_count]))
    base_url_bytes = base_url.encode('ascii')
    if len(base_url_bytes) >= 0x80:
        # Var-length can only address ~16K, but be defensive
        raise ValueError('base_url too long')
    tlv += _write_tlv(HDHOMERUN_TAG_BASE_URL, base_url_bytes)
    if device_auth:
        tlv += _write_tlv(HDHOMERUN_TAG_DEVICE_AUTH_STR,
                          device_auth.encode('ascii'))
    if lineup_url:
        tlv += _write_tlv(HDHOMERUN_TAG_LINEUP_URL,
                          lineup_url.encode('ascii'))

    # Header: [type:2][length:2]
    frame = struct.pack('>H', HDHOMERUN_TYPE_DISCOVER_RPY)
    frame += struct.pack('>H', len(tlv))
    frame += tlv
    # CRC32 (little-endian) over header + payload
    frame += struct.pack('<I', _crc32(frame))
    return frame


def _parse_request(data):
    """Validate a discovery request. Returns (device_type, device_id) or None."""
    if len(data) < 8:
        return None
    frame_type = struct.unpack('>H', data[0:2])[0]
    if frame_type != HDHOMERUN_TYPE_DISCOVER_REQ:
        return None
    payload_length = struct.unpack('>H', data[2:4])[0]
    expected_total = 4 + payload_length + 4
    if len(data) < expected_total:
        return None
    # Validate CRC
    if _crc32(data[:expected_total - 4]) != struct.unpack('<I', data[expected_total - 4:expected_total])[0]:
        return None

    pos = 4
    end = 4 + payload_length
    requested_type = HDHOMERUN_DEVICE_TYPE_WILDCARD
    requested_id = HDHOMERUN_DEVICE_TYPE_WILDCARD
    while pos < end:
        if pos + 1 > end:
            break
        tag = data[pos]
        pos += 1
        if pos >= end:
            break
        l = data[pos]
        pos += 1
        if l & 0x80:
            if pos >= end:
                break
            l = (l & 0x7F) | (data[pos] << 7)
            pos += 1
        if pos + l > end:
            break
        value = data[pos:pos + l]
        pos += l
        if tag == HDHOMERUN_TAG_DEVICE_TYPE and l == 4:
            requested_type = struct.unpack('>I', value)[0]
        elif tag == HDHOMERUN_TAG_DEVICE_ID and l == 4:
            requested_id = struct.unpack('>I', value)[0]
    return requested_type, requested_id


class HDHomerunDiscovery:
    """Background UDP broadcast listener for SiliconDust HDHomeRun discovery.

    Listens on UDP port 65001 for DISCOVER_REQ packets and replies with a
    DISCOVER_RPY containing this device's info. Designed for macvlan/QNAP
    setups where the container has a direct LAN IP that the broadcast
    group 255.255.255.255 can reach.

    IMPORTANT: This responder MUST NOT reply to Tvheadend itself. Tvheadend
    also does HDHomeRun discovery on startup to find physical HDHomeRun
    hardware, and if it picks up this proxy (which appears as a HDHomeRun
    device), Tvheadend crashes with SIGSEGV (signal 11) as soon as it
    tries to probe the device. The real Tvheadend upstream service is the
    one we proxy TO, so any reply we send to it is also pointless — it
    won't be talking back to us.

    To prevent the loop/crash we read TVH_HOST_IP (the address Tvheadend
    is reachable at) from env and silently drop discovery requests coming
    from that IP.
    """

    def __init__(self, device_id, tuner_count, base_url, device_auth,
                 lineup_url, exclude_ips=None):
        # device_id may arrive as hex string (e.g. '12345678') or int
        if isinstance(device_id, str):
            try:
                self.device_id = int(device_id, 16) & 0xFFFFFFFF
            except ValueError:
                self.device_id = int(device_id) & 0xFFFFFFFF
        else:
            self.device_id = int(device_id) & 0xFFFFFFFF
        self.tuner_count = int(tuner_count)
        self.base_url = base_url
        self.device_auth = device_auth or ''
        self.lineup_url = lineup_url or ''
        # Normalize excluded IPs to a frozenset for O(1) lookup
        self.exclude_ips = frozenset(ip.strip() for ip in (exclude_ips or [])
                                     if ip and ip.strip())
        self._stop = threading.Event()
        self._sock = None
        self._thread = None

    def start(self):
        self._thread = threading.Thread(target=self._run, daemon=True,
                                        name='hdhomerun-discovery')
        self._thread.start()
        logger.info('HDHomeRun discovery listening on UDP port %d', DISCOVERY_PORT)

    def stop(self):
        self._stop.set()
        if self._sock:
            try:
                self._sock.close()
            except Exception:
                pass

    def _run(self):
        """Listen for broadcast discovery requests and reply."""
        while not self._stop.is_set():
            sock = None
            try:
                sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                # Allow multiple processes to bind to port 65001
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                if hasattr(socket, 'SO_REUSEPORT'):
                    try:
                        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
                    except (OSError, AttributeError):
                        pass
                sock.bind(('0.0.0.0', DISCOVERY_PORT))
                sock.settimeout(1.0)
                self._sock = sock
                while not self._stop.is_set():
                    try:
                        data, addr = sock.recvfrom(2048)
                    except socket.timeout:
                        continue
                    except OSError:
                        break
                    self._handle_request(data, addr, sock)
            except OSError as e:
                logger.error('HDHomeRun discovery bind error: %s (retrying in 5s)', e)
                if sock:
                    try:
                        sock.close()
                    except Exception:
                        pass
                if self._stop.wait(5):
                    return
            except Exception as e:
                logger.exception('HDHomeRun discovery unexpected error: %s', e)
                if sock:
                    try:
                        sock.close()
                    except Exception:
                        pass
                if self._stop.wait(5):
                    return

    def _handle_request(self, data, addr, sock):
        """Parse and reply to a discovery request."""
        parsed = _parse_request(data)
        if parsed is None:
            logger.debug('HDHomeRun discovery: unparseable packet from %s', addr)
            return
        req_type, req_id = parsed
        # Drop requests from excluded IPs (e.g. Tvheadend itself, which
        # crashes with SIGSEGV if it picks us up as a HDHomeRun device).
        logger.info('HDHomeRun discovery: request from %s, exclude_list=%s',
                    addr[0], self.exclude_ips)
        if addr[0] in self.exclude_ips:
            logger.info('HDHomeRun discovery: dropping request from %s '
                        '(in exclude list)', addr[0])
            return
        # Filter by requested type (we answer both TUNER and wildcard requests
        # because some clients send multi-type with TUNER as the primary match).
        if req_type not in (HDHOMERUN_DEVICE_TYPE_WILDCARD,
                            HDHOMERUN_DEVICE_TYPE_TUNER):
            return
        # If client asked for a specific device id, only respond if it matches.
        if req_id != HDHOMERUN_DEVICE_TYPE_WILDCARD and req_id != self.device_id:
            return

        reply = _build_reply(self.device_id, self.tuner_count,
                             self.base_url, self.device_auth, self.lineup_url)
        try:
            sock.sendto(reply, addr)
            logger.info('HDHomeRun discovery: replied to %s:%d (%d bytes)',
                        addr[0], addr[1], len(reply))
        except OSError as e:
            logger.error('HDHomeRun discovery: failed to reply: %s', e)
