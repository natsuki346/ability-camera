#!/usr/bin/env python3
"""Minimal, non-persisting HTTP receiver for the Ability Cam XIAO v0 protocol."""

from __future__ import annotations

import argparse
from collections import defaultdict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
import time
from datetime import datetime, timezone


REPORT_INTERVAL_SECONDS = 10
AUDIO_BYTES_PER_SECOND = 32_000
JPEG_START_OF_FRAME_MARKERS = {
    0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
    0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF,
}


def jpeg_dimensions(data: bytes) -> tuple[int, int] | None:
    """Read JPEG width and height from its start-of-frame marker."""
    if not data.startswith(b"\xff\xd8"):
        return None
    index = 2
    while index < len(data):
        if data[index] != 0xFF:
            return None
        while index < len(data) and data[index] == 0xFF:
            index += 1
        if index >= len(data):
            return None
        marker = data[index]
        index += 1
        if marker in {0xD8, 0x01} or 0xD0 <= marker <= 0xD7:
            continue
        if marker in {0xD9, 0xDA} or index + 2 > len(data):
            return None
        segment_length = int.from_bytes(data[index:index + 2], "big")
        if segment_length < 2 or index + segment_length > len(data):
            return None
        if marker in JPEG_START_OF_FRAME_MARKERS:
            if segment_length < 7:
                return None
            height = int.from_bytes(data[index + 3:index + 5], "big")
            width = int.from_bytes(data[index + 5:index + 7], "big")
            return width, height
        index += segment_length
    return None


class ReceiveStats:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._received: dict[tuple[str, str], int] = defaultdict(int)
        self._missing: dict[tuple[str, str], int] = defaultdict(int)
        self._highest_seq: dict[tuple[str, str], int] = {}
        self._resets: dict[tuple[str, str], int] = defaultdict(int)

    def record(self, kind: str, device_id: str, seq: int) -> None:
        key = (kind, device_id)
        with self._lock:
            highest = self._highest_seq.get(key)
            if highest is None:
                # Sequence numbering starts at zero, so a first observation above
                # zero means earlier generated frames did not reach this receiver.
                self._missing[key] += seq
                self._highest_seq[key] = seq
            elif seq == 0 and highest > 0:
                # X-Seq restarts at zero after the device reboots.
                self._resets[key] += 1
                self._highest_seq[key] = 0
            else:
                if seq > highest + 1:
                    self._missing[key] += seq - highest - 1
                if seq > highest:
                    self._highest_seq[key] = seq
            self._received[key] += 1

    def snapshot(self) -> list[tuple[str, str, int, int, int]]:
        with self._lock:
            keys = set(self._received) | {("frame", ""), ("audio", "")}
            return [
                (kind, device_id, self._received[(kind, device_id)],
                 self._missing[(kind, device_id)], self._resets[(kind, device_id)])
                for kind, device_id in sorted(keys)
            ]


class ReceiverServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int]) -> None:
        super().__init__(address, ReceiverHandler)
        self.stats = ReceiveStats()
        self.started_at = time.monotonic()


class ReceiverHandler(BaseHTTPRequestHandler):
    server: ReceiverServer

    def log_message(self, _format: str, *_args: object) -> None:
        # Keep request-level payload and access logs out of the terminal.
        return

    def do_GET(self) -> None:
        if self.path != "/v0/time":
            self._reply(404)
            return
        now_ms = int(datetime.now(timezone.utc).timestamp() * 1000)
        self._reply(200, str(now_ms).encode("ascii"), "text/plain; charset=utf-8")

    def do_POST(self) -> None:
        routes = {
            "/v0/frame": ("frame", "image/jpeg", None),
            "/v0/audio": ("audio", "application/octet-stream", AUDIO_BYTES_PER_SECOND),
        }
        route = routes.get(self.path)
        if route is None:
            self._reply(404)
            return

        kind, expected_type, expected_size = route
        content_type = self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
        if content_type != expected_type:
            self._reply(400, b"unexpected Content-Type\n", "text/plain; charset=utf-8")
            return

        try:
            content_length = int(self.headers.get("Content-Length", ""))
            seq = int(self.headers.get("X-Seq", ""))
        except ValueError:
            self._reply(400, b"Content-Length and X-Seq are required integers\n", "text/plain; charset=utf-8")
            return
        device_id = self.headers.get("X-Device-Id", "").strip()
        captured_ms = self.headers.get("X-Captured-Ms", "")
        if not device_id or seq < 0 or not captured_ms.isdecimal():
            self._reply(400, b"X-Device-Id, non-negative X-Seq, and X-Captured-Ms are required\n",
                        "text/plain; charset=utf-8")
            return
        if content_length < 0 or (expected_size is not None and content_length != expected_size):
            self._reply(400, b"unexpected body size\n", "text/plain; charset=utf-8")
            return

        # Consume and discard the body. The receiver tracks transport only; it does
        # not persist or decode photos or audio.
        body = self.rfile.read(content_length)
        if len(body) != content_length:
            self._reply(400, b"incomplete request body\n", "text/plain; charset=utf-8")
            return
        if kind == "frame":
            if not body.endswith(b"\xff\xd9") or jpeg_dimensions(body) != (640, 480):
                self._reply(400, b"body must be a 640x480 JPEG image\n", "text/plain; charset=utf-8")
                return

        self.server.stats.record(kind, device_id, seq)
        self._reply(200)

    def _reply(self, status: int, body: bytes = b"", content_type: str | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        if content_type:
            self.send_header("Content-Type", content_type)
        self.end_headers()
        if body:
            self.wfile.write(body)


def report_periodically(server: ReceiverServer, stop: threading.Event) -> None:
    while not stop.wait(REPORT_INTERVAL_SECONDS):
        elapsed = int(time.monotonic() - server.started_at)
        entries = []
        for kind, device_id, received, missing, resets in server.stats.snapshot():
            label = f"{kind}" + (f"[{device_id}]" if device_id else "")
            entries.append(f"{label} received={received} seq_missing={missing} seq_resets={resets}")
        print(f"[status] up={elapsed}s | " + " | ".join(entries), flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description="Ability Cam XIAO v0 HTTP receiver")
    parser.add_argument("--host", default="0.0.0.0", help="listen address (default: all interfaces)")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()

    server = ReceiverServer((args.host, args.port))
    stop = threading.Event()
    reporter = threading.Thread(target=report_periodically, args=(server, stop), daemon=True)
    reporter.start()
    print(f"[receiver] listening on http://{args.host}:{args.port} (reports every {REPORT_INTERVAL_SECONDS}s)",
          flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[receiver] stopping", flush=True)
    finally:
        stop.set()
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
