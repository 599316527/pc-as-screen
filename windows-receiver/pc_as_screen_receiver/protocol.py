from __future__ import annotations

from dataclasses import dataclass
import hmac
import hashlib
import secrets
import struct
from typing import BinaryIO


MAGIC = b"PCSCRN1"
AUTH_HELLO_MAGIC = b"PCSHELLO"
AUTH_CHALLENGE_MAGIC = b"PCSAUTH1"
AUTH_RESPONSE_MAGIC = b"PCSRESP1"
AUTH_ACCEPTED_MAGIC = b"PCSOKAY1"
AUTH_REJECTED_MAGIC = b"PCSFAIL1"
AUTH_NONCE_SIZE = 32
AUTH_DIGEST_SIZE = 32
AUTH_CONTEXT = b"pc-as-screen auth v1"
STREAM_HEADER_SIZE = 16
FRAME_HEADER_SIZE = 21


@dataclass(frozen=True)
class StreamHeader:
    codec: int
    width: int
    height: int
    timescale: int


@dataclass(frozen=True)
class FramePacket:
    frame_type: int
    presentation_timestamp_micros: int
    decode_timestamp_micros: int
    payload: bytes

    @property
    def is_config(self) -> bool:
        return self.frame_type == 0

    @property
    def is_keyframe(self) -> bool:
        return self.frame_type == 2

    @property
    def is_cursor(self) -> bool:
        return self.frame_type == 3


@dataclass(frozen=True)
class CursorPacket:
    x: int
    y: int
    timestamp_micros: int


def read_exact(stream: BinaryIO, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        chunk = stream.read(size - len(data))
        if not chunk:
            raise EOFError(f"expected {size} bytes, got {len(data)} before EOF")
        data.extend(chunk)
    return bytes(data)


def read_stream_header(stream: BinaryIO) -> StreamHeader:
    payload = read_exact(stream, STREAM_HEADER_SIZE)
    magic = payload[:7]
    if magic != MAGIC:
        raise ValueError(f"invalid magic {magic!r}, expected {MAGIC!r}")
    codec = payload[7]
    width, height, timescale = struct.unpack(">HHI", payload[8:])
    return StreamHeader(codec=codec, width=width, height=height, timescale=timescale)


def make_auth_digest(password: str, nonce: bytes) -> bytes:
    return hmac.digest(password.encode("utf-8"), AUTH_CONTEXT + nonce, hashlib.sha256)


def authenticate_stream(stream: BinaryIO, password: str | None) -> None:
    if not password:
        return

    hello = read_exact(stream, len(AUTH_HELLO_MAGIC))
    if hello != AUTH_HELLO_MAGIC:
        raise ValueError("sender did not start the password authentication handshake")

    nonce = secrets.token_bytes(AUTH_NONCE_SIZE)
    stream.write(AUTH_CHALLENGE_MAGIC + nonce)
    stream.flush()

    response = read_exact(stream, len(AUTH_RESPONSE_MAGIC) + AUTH_DIGEST_SIZE)
    response_magic = response[: len(AUTH_RESPONSE_MAGIC)]
    response_digest = response[len(AUTH_RESPONSE_MAGIC) :]
    expected_digest = make_auth_digest(password, nonce)
    if response_magic == AUTH_RESPONSE_MAGIC and hmac.compare_digest(response_digest, expected_digest):
        stream.write(AUTH_ACCEPTED_MAGIC)
        stream.flush()
        return

    stream.write(AUTH_REJECTED_MAGIC)
    stream.flush()
    raise ValueError("sender provided an invalid password")


def read_frame_packet(stream: BinaryIO) -> FramePacket:
    header = read_exact(stream, FRAME_HEADER_SIZE)
    frame_type = header[0]
    payload_length = struct.unpack(">I", header[1:5])[0]
    presentation_timestamp_micros = struct.unpack(">Q", header[5:13])[0]
    decode_timestamp_micros = struct.unpack(">Q", header[13:21])[0]
    payload = read_exact(stream, payload_length)
    return FramePacket(
        frame_type=frame_type,
        presentation_timestamp_micros=presentation_timestamp_micros,
        decode_timestamp_micros=decode_timestamp_micros,
        payload=payload,
    )


def parse_cursor_packet(packet: FramePacket) -> CursorPacket:
    if not packet.is_cursor:
        raise ValueError(f"frame type {packet.frame_type} is not a cursor packet")
    if len(packet.payload) != 4:
        raise ValueError(f"cursor packet payload must be 4 bytes, got {len(packet.payload)}")
    x, y = struct.unpack(">HH", packet.payload)
    return CursorPacket(x=x, y=y, timestamp_micros=packet.presentation_timestamp_micros)
