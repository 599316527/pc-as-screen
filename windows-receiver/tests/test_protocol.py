from __future__ import annotations

import io
from pathlib import Path
import socket
import sys
from threading import Event
import unittest
from unittest.mock import patch
from contextlib import redirect_stdout

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from pc_as_screen_receiver.cursor import Rect, content_rect_for, map_cursor_to_screen
from pc_as_screen_receiver.player import FFplayProcess
from pc_as_screen_receiver.receiver import PlayerLifecycle, ReceiverConfig, handle_connection, run, stop_connection_when_player_exits
from pc_as_screen_receiver.protocol import parse_cursor_packet, read_frame_packet, read_stream_header
from pc_as_screen_receiver.protocol import (
    AUTH_ACCEPTED_MAGIC,
    AUTH_CHALLENGE_MAGIC,
    AUTH_REJECTED_MAGIC,
    AUTH_RESPONSE_MAGIC,
    CursorPacket,
    authenticate_stream,
    make_auth_digest,
)


class DuplexStream:
    def __init__(self, incoming: bytes) -> None:
        self._incoming = io.BytesIO(incoming)
        self.outgoing = io.BytesIO()

    def read(self, size: int) -> bytes:
        return self._incoming.read(size)

    def write(self, data: bytes) -> int:
        return self.outgoing.write(data)

    def flush(self) -> None:
        pass


class FakeConnection:
    def __init__(self, payload: bytes) -> None:
        self.payload = payload
        self.closed = False
        self.timeout_seconds: float | None = None

    def makefile(self, mode: str) -> io.BytesIO:
        return io.BytesIO(self.payload)

    def settimeout(self, timeout_seconds: float) -> None:
        self.timeout_seconds = timeout_seconds

    def close(self) -> None:
        self.closed = True


class FakeServer:
    def __init__(self) -> None:
        self.accept_count = 0
        self.closed = False

    def accept(self) -> tuple[FakeConnection, tuple[str, int]]:
        self.accept_count += 1
        if self.accept_count == 1:
            return FakeConnection(b"not-a-valid-stream"), ("127.0.0.1", 5000)
        raise KeyboardInterrupt

    def close(self) -> None:
        self.closed = True


class FakePlayer:
    def __init__(self) -> None:
        self.wait_count = 0
        self.input_closed = False

    @property
    def has_exited(self) -> bool:
        return True

    def wait(self) -> int:
        self.wait_count += 1
        return 0

    def close_input(self) -> None:
        self.input_closed = True


class FakeShutdownConnection:
    def __init__(self) -> None:
        self.shutdown_how: int | None = None

    def shutdown(self, how: int) -> None:
        self.shutdown_how = how


class TimedOutStream:
    def __init__(self, first_read: bytes) -> None:
        self._first_read = first_read

    def read(self, size: int) -> bytes:
        if self._first_read:
            chunk = self._first_read[:size]
            self._first_read = self._first_read[size:]
            return chunk
        raise TimeoutError("timed out")


class TimeoutConnection(FakeConnection):
    def makefile(self, mode: str) -> TimedOutStream:
        return TimedOutStream(self.payload)


class FakeStreamingPlayer:
    instances: list["FakeStreamingPlayer"] = []

    def __init__(self, ffplay_path: str | None = None) -> None:
        self.ffplay_path = ffplay_path
        self.payloads: list[bytes] = []
        self.closed = Event()
        self.started = False
        FakeStreamingPlayer.instances.append(self)

    def start(self) -> None:
        self.started = True

    @property
    def process_id(self) -> int | None:
        return None

    @property
    def has_exited(self) -> bool:
        return False

    def wait(self) -> int:
        self.closed.wait(timeout=1)
        return 0

    def write(self, payload: bytes) -> None:
        self.payloads.append(payload)

    def close_input(self) -> None:
        pass

    def close(self) -> None:
        self.closed.set()


class ClosableInput:
    def __init__(self) -> None:
        self.closed = False

    def close(self) -> None:
        self.closed = True


class ProcessWithClosableInput:
    def __init__(self) -> None:
        self.stdin = ClosableInput()


class ProtocolTests(unittest.TestCase):
    def test_read_stream_header(self) -> None:
        payload = b"PCSCRN1" + bytes([1]) + bytes([0x07, 0x80, 0x04, 0x38, 0x00, 0x0F, 0x42, 0x40])
        header = read_stream_header(io.BytesIO(payload))
        self.assertEqual(header.codec, 1)
        self.assertEqual(header.width, 1920)
        self.assertEqual(header.height, 1080)
        self.assertEqual(header.timescale, 1_000_000)

    def test_read_frame_packet(self) -> None:
        payload = (
            bytes([2])
            + bytes([0x00, 0x00, 0x00, 0x05])
            + bytes([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7B])
            + bytes([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x78])
            + b"\x00\x00\x00\x01\x65"
        )
        packet = read_frame_packet(io.BytesIO(payload))
        self.assertTrue(packet.is_keyframe)
        self.assertEqual(packet.presentation_timestamp_micros, 123)
        self.assertEqual(packet.decode_timestamp_micros, 120)
        self.assertEqual(packet.payload, b"\x00\x00\x00\x01\x65")

    def test_parse_cursor_packet(self) -> None:
        payload = (
            bytes([3])
            + bytes([0x00, 0x00, 0x00, 0x04])
            + bytes([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xC8])
            + bytes([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xC8])
            + bytes([0x12, 0x34, 0xAB, 0xCD])
        )
        packet = read_frame_packet(io.BytesIO(payload))
        cursor = parse_cursor_packet(packet)

        self.assertTrue(packet.is_cursor)
        self.assertEqual(cursor.x, 0x1234)
        self.assertEqual(cursor.y, 0xABCD)
        self.assertEqual(cursor.timestamp_micros, 456)

    def test_authenticate_stream_accepts_matching_password(self) -> None:
        password = "screen-pass"
        nonce = b"\x01" * 32
        response = AUTH_RESPONSE_MAGIC + make_auth_digest(password, nonce)

        stream = DuplexStream(b"PCSHELLO" + response)
        with patch("pc_as_screen_receiver.protocol.secrets.token_bytes", return_value=nonce):
            authenticate_stream(stream, password)
        self.assertTrue(stream.outgoing.getvalue().startswith(AUTH_CHALLENGE_MAGIC))
        self.assertTrue(stream.outgoing.getvalue().endswith(AUTH_ACCEPTED_MAGIC))

    def test_authenticate_stream_rejects_wrong_password(self) -> None:
        good_password = "screen-pass"
        bad_password = "wrong-pass"
        nonce = b"\x01" * 32
        response = AUTH_RESPONSE_MAGIC + make_auth_digest(bad_password, nonce)
        stream = DuplexStream(b"PCSHELLO" + response)

        with self.assertRaises(ValueError):
            with patch("pc_as_screen_receiver.protocol.secrets.token_bytes", return_value=nonce):
                authenticate_stream(stream, good_password)
        self.assertTrue(stream.outgoing.getvalue().startswith(AUTH_CHALLENGE_MAGIC))
        self.assertTrue(stream.outgoing.getvalue().endswith(AUTH_REJECTED_MAGIC))

    def test_receiver_keeps_listening_after_connection_error(self) -> None:
        fake_server = FakeServer()
        config = ReceiverConfig(host="127.0.0.1", port=6000, ffplay_path=None, password=None)

        with patch("pc_as_screen_receiver.receiver.socket.create_server", return_value=fake_server):
            with self.assertRaises(KeyboardInterrupt):
                with redirect_stdout(io.StringIO()):
                    run(config)

        self.assertEqual(fake_server.accept_count, 2)
        self.assertTrue(fake_server.closed)

    def test_player_exit_closes_the_active_stream_connection(self) -> None:
        player = FakePlayer()
        connection = FakeShutdownConnection()
        lifecycle = PlayerLifecycle(exited=Event(), receiver_stopping=Event())

        stop_connection_when_player_exits(player, connection, lifecycle)

        self.assertEqual(player.wait_count, 1)
        self.assertTrue(player.input_closed)
        self.assertEqual(connection.shutdown_how, socket.SHUT_RDWR)
        self.assertTrue(lifecycle.exited.is_set())

    def test_cursor_mapping_uses_letterboxed_video_rect(self) -> None:
        content_rect = content_rect_for(Rect(left=0, top=0, right=2560, bottom=1600), video_width=1920, video_height=1080)

        self.assertEqual(content_rect, Rect(left=0, top=80, right=2560, bottom=1520))
        self.assertEqual(map_cursor_to_screen(CursorPacket(x=0, y=0, timestamp_micros=1), content_rect), (0, 80))
        self.assertEqual(
            map_cursor_to_screen(CursorPacket(x=65535, y=65535, timestamp_micros=1), content_rect),
            (2559, 1519),
        )

    def test_config_heartbeat_is_not_written_to_player(self) -> None:
        stream = (
            b"PCSCRN1"
            + bytes([1])
            + bytes([0x07, 0x80, 0x04, 0x38, 0x00, 0x0F, 0x42, 0x40])
            + bytes([0, 0, 0, 0, 0])
            + (0).to_bytes(8, "big")
            + (0).to_bytes(8, "big")
            + bytes([2, 0, 0, 0, 5])
            + (123).to_bytes(8, "big")
            + (120).to_bytes(8, "big")
            + b"video"
        )
        connection = FakeConnection(stream)
        config = ReceiverConfig(host="127.0.0.1", port=6000, ffplay_path=None, password=None)
        FakeStreamingPlayer.instances.clear()

        with patch("pc_as_screen_receiver.receiver.FFplayProcess", FakeStreamingPlayer):
            with redirect_stdout(io.StringIO()):
                handle_connection(connection, ("127.0.0.1", 5000), config)

        self.assertEqual(connection.timeout_seconds, config.stale_timeout_seconds)
        self.assertEqual(FakeStreamingPlayer.instances[0].payloads, [b"video"])

    def test_stale_stream_timeout_closes_current_player(self) -> None:
        header = b"PCSCRN1" + bytes([1]) + bytes([0x07, 0x80, 0x04, 0x38, 0x00, 0x0F, 0x42, 0x40])
        connection = TimeoutConnection(header)
        config = ReceiverConfig(host="127.0.0.1", port=6000, ffplay_path=None, password=None)
        FakeStreamingPlayer.instances.clear()

        with patch("pc_as_screen_receiver.receiver.FFplayProcess", FakeStreamingPlayer):
            with redirect_stdout(io.StringIO()):
                handle_connection(connection, ("127.0.0.1", 5000), config)

        self.assertEqual(connection.timeout_seconds, config.stale_timeout_seconds)
        self.assertTrue(FakeStreamingPlayer.instances[0].closed.is_set())

    def test_heartbeat_after_video_timeout_closes_current_player(self) -> None:
        stream = (
            b"PCSCRN1"
            + bytes([1])
            + bytes([0x07, 0x80, 0x04, 0x38, 0x00, 0x0F, 0x42, 0x40])
            + bytes([0, 0, 0, 0, 0])
            + (0).to_bytes(8, "big")
            + (0).to_bytes(8, "big")
        )
        connection = FakeConnection(stream)
        config = ReceiverConfig(host="127.0.0.1", port=6000, ffplay_path=None, password=None)
        FakeStreamingPlayer.instances.clear()

        with patch("pc_as_screen_receiver.receiver.FFplayProcess", FakeStreamingPlayer):
            with patch("pc_as_screen_receiver.receiver.monotonic", side_effect=[0.0, 6.0]):
                with redirect_stdout(io.StringIO()):
                    handle_connection(connection, ("127.0.0.1", 5000), config)

        self.assertTrue(FakeStreamingPlayer.instances[0].closed.is_set())

    def test_ffplay_close_input_closes_stdin_file_object(self) -> None:
        player = FFplayProcess(ffplay_path="ffplay")
        process = ProcessWithClosableInput()
        player._process = process

        player.close_input()

        self.assertTrue(process.stdin.closed)


if __name__ == "__main__":
    unittest.main()
