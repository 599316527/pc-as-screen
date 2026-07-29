#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hmac
import hashlib
import subprocess
import socket
import struct
import time


AUTH_HELLO_MAGIC = b"PCSHELLO"
AUTH_CHALLENGE_MAGIC = b"PCSAUTH1"
AUTH_RESPONSE_MAGIC = b"PCSRESP1"
AUTH_ACCEPTED_MAGIC = b"PCSOKAY1"
AUTH_CONTEXT = b"pc-as-screen auth v1"
MAGIC = b"PCSCRN1"


def read_exact(stream: socket.socket, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        chunk = stream.recv(size - len(data))
        if not chunk:
            raise EOFError(f"expected {size} bytes, got {len(data)} before EOF")
        data.extend(chunk)
    return bytes(data)


def authenticate(stream: socket.socket, password: str | None) -> None:
    if not password:
        return
    stream.sendall(AUTH_HELLO_MAGIC)
    challenge = read_exact(stream, len(AUTH_CHALLENGE_MAGIC) + 32)
    if challenge[: len(AUTH_CHALLENGE_MAGIC)] != AUTH_CHALLENGE_MAGIC:
        raise RuntimeError(f"receiver sent unexpected auth challenge {challenge!r}")
    nonce = challenge[len(AUTH_CHALLENGE_MAGIC) :]
    expected = AUTH_RESPONSE_MAGIC + hmac.digest(
        password.encode("utf-8"), AUTH_CONTEXT + nonce, hashlib.sha256
    )
    stream.sendall(expected)
    status = read_exact(stream, len(AUTH_ACCEPTED_MAGIC))
    if status != AUTH_ACCEPTED_MAGIC:
        raise RuntimeError(f"receiver rejected auth with status {status!r}")


def frame_packet(frame_type: int, payload: bytes, pts: int, dts: int) -> bytes:
    return bytes([frame_type]) + struct.pack(">IQQ", len(payload), pts, dts) + payload


def split_annex_b_access_units(payload: bytes) -> list[bytes]:
    starts: list[tuple[int, int]] = []
    index = 0
    while index < len(payload) - 3:
        if payload[index : index + 3] == b"\x00\x00\x01":
            starts.append((index, index + 3))
            index += 3
        elif payload[index : index + 4] == b"\x00\x00\x00\x01":
            starts.append((index, index + 4))
            index += 4
        else:
            index += 1

    units: list[bytes] = []
    for unit_index, (start, payload_start) in enumerate(starts):
        end = starts[unit_index + 1][0] if unit_index + 1 < len(starts) else len(payload)
        if payload_start < end:
            units.append(payload[start:end])

    access_units: list[bytes] = []
    current = bytearray()
    for unit in units:
        payload_start = 3 if unit.startswith(b"\x00\x00\x01") else 4
        nal_type = unit[payload_start] & 0x1F
        if nal_type in (1, 5) and current:
            access_units.append(bytes(current))
            current.clear()
        current.extend(unit)
    if current:
        access_units.append(bytes(current))
    return access_units


def make_h264_access_units() -> list[bytes]:
    command = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-f",
        "lavfi",
        "-i",
        "testsrc=size=640x360:rate=2",
        "-frames:v",
        "2",
        "-c:v",
        "libx264",
        "-profile:v",
        "baseline",
        "-level",
        "3.1",
        "-preset",
        "ultrafast",
        "-tune",
        "zerolatency",
        "-x264-params",
        "keyint=2:min-keyint=2:scenecut=0",
        "-pix_fmt",
        "yuv420p",
        "-bsf:v",
        "h264_mp4toannexb",
        "-f",
        "h264",
        "-",
    ]
    return split_annex_b_access_units(subprocess.check_output(command))


def main() -> None:
    parser = argparse.ArgumentParser(description="Send one pc-as-screen test stream to the iPad receiver E2E app.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--password", default=None)
    parser.add_argument("--hold-after", type=float, default=0.2)
    args = parser.parse_args()

    with socket.create_connection((args.host, args.port), timeout=20) as stream:
        authenticate(stream, args.password)
        stream.sendall(MAGIC + bytes([1]) + struct.pack(">HHI", 640, 360, 1_000_000))
        for index, access_unit in enumerate(make_h264_access_units()):
            timestamp = index * 500_000
            stream.sendall(frame_packet(2 if index == 0 else 1, access_unit, timestamp, timestamp))
        stream.sendall(frame_packet(3, struct.pack(">HH", 1000, 2000), 1_000, 1_000))
        time.sleep(args.hold_after)


if __name__ == "__main__":
    main()
