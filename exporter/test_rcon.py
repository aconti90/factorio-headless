import socket
import struct
import threading
import unittest

from rcon import RconClient, RconError


def _pack_packet(pkt_id, pkt_type, body):
    payload = struct.pack("<ii", pkt_id, pkt_type) + body.encode("utf-8") + b"\x00\x00"
    return struct.pack("<i", len(payload)) + payload


def _read_packet(sock):
    size = struct.unpack("<i", sock.recv(4))[0]
    data = b""
    while len(data) < size:
        data += sock.recv(size - len(data))
    pkt_id, pkt_type = struct.unpack("<ii", data[:8])
    body = data[8:-2].decode("utf-8")
    return pkt_id, pkt_type, body


class _FakeRconServer:
    """A minimal in-process RCON server for testing RconClient against real
    socket behavior, not mocks. Accepts one connection, authenticates against
    a fixed password, and echoes back "echo: <command>" for any command."""

    def __init__(self, password):
        self._password = password
        self._server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._server_sock.bind(("127.0.0.1", 0))
        self._server_sock.listen(1)
        self.port = self._server_sock.getsockname()[1]
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def _serve(self):
        conn, _ = self._server_sock.accept()
        with conn:
            pkt_id, _, body = _read_packet(conn)
            if body == self._password:
                conn.sendall(_pack_packet(pkt_id, 2, ""))
            else:
                conn.sendall(_pack_packet(-1, 2, ""))
                return
            while True:
                try:
                    pkt_id, _, body = _read_packet(conn)
                except (ConnectionError, struct.error, IndexError):
                    return
                conn.sendall(_pack_packet(pkt_id, 0, f"echo: {body}"))

    def close(self):
        self._server_sock.close()


class TestRconClient(unittest.TestCase):
    def test_successful_auth_and_command(self):
        server = _FakeRconServer(password="correct-password")
        try:
            client = RconClient("127.0.0.1", server.port, "correct-password")
            client.connect()
            self.assertEqual(client.command("hello"), "echo: hello")
            client.close()
        finally:
            server.close()

    def test_failed_auth_raises(self):
        server = _FakeRconServer(password="correct-password")
        try:
            client = RconClient("127.0.0.1", server.port, "wrong-password")
            with self.assertRaises(RconError):
                client.connect()
        finally:
            server.close()


if __name__ == "__main__":
    unittest.main()
