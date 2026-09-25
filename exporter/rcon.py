"""Minimal Source RCON client (stdlib only) — the same protocol Factorio uses."""
import socket
import struct

SERVERDATA_AUTH = 3
SERVERDATA_EXECCOMMAND = 2
SERVERDATA_RESPONSE_VALUE = 0


class RconError(Exception):
    """Raised when authentication fails or the connection breaks."""


class RconClient:
    def __init__(self, host, port, password, timeout=10):
        self._host = host
        self._port = port
        self._password = password
        self._timeout = timeout
        self._sock = None

    def connect(self):
        self._sock = socket.create_connection((self._host, self._port), timeout=self._timeout)
        self._send_packet(1, SERVERDATA_AUTH, self._password)
        pkt_id, pkt_type, _ = self._read_packet()
        if pkt_type == SERVERDATA_RESPONSE_VALUE:
            pkt_id, pkt_type, _ = self._read_packet()
        if pkt_id != 1:
            self.close()
            raise RconError("RCON authentication failed")

    def command(self, command):
        self._send_packet(2, SERVERDATA_EXECCOMMAND, command)
        _, _, body = self._read_packet()
        return body

    def close(self):
        if self._sock is not None:
            self._sock.close()
            self._sock = None

    def _send_packet(self, pkt_id, pkt_type, body):
        payload = struct.pack("<ii", pkt_id, pkt_type) + body.encode("utf-8") + b"\x00\x00"
        self._sock.sendall(struct.pack("<i", len(payload)) + payload)

    def _read_packet(self):
        size = struct.unpack("<i", self._recv_exact(4))[0]
        data = self._recv_exact(size)
        pkt_id, pkt_type = struct.unpack("<ii", data[:8])
        body = data[8:-2].decode("utf-8", errors="replace")
        return pkt_id, pkt_type, body

    def _recv_exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self._sock.recv(n - len(buf))
            if not chunk:
                raise RconError("connection closed while reading")
            buf += chunk
        return buf
