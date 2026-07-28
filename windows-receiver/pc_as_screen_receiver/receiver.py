from __future__ import annotations

import argparse
import os
import socket
from contextlib import closing
from dataclasses import dataclass

from .cursor import CursorController
from .player import FFplayProcess
from .protocol import authenticate_stream, parse_cursor_packet, read_frame_packet, read_stream_header


@dataclass(frozen=True)
class ReceiverConfig:
    host: str
    port: int
    ffplay_path: str | None
    password: str | None


def parse_args() -> ReceiverConfig:
    parser = argparse.ArgumentParser(description="Receive pc-as-screen TCP stream and display it via ffplay.")
    parser.add_argument("--host", default="0.0.0.0", help="Local interface to bind. Default: 0.0.0.0")
    parser.add_argument("--port", type=int, default=6000, help="TCP port to bind. Default: 6000")
    parser.add_argument("--ffplay", default=None, help="Optional explicit path to ffplay.exe")
    parser.add_argument(
        "--password",
        default=None,
        help="Optional shared password. Can also be set via PC_AS_SCREEN_PASSWORD.",
    )
    args = parser.parse_args()
    password = args.password or os.environ.get("PC_AS_SCREEN_PASSWORD")
    return ReceiverConfig(host=args.host, port=args.port, ffplay_path=args.ffplay, password=password or None)


def run(config: ReceiverConfig) -> None:
    with closing(socket.create_server((config.host, config.port), reuse_port=False)) as server:
        print(f"Listening on {config.host}:{config.port}")
        while True:
            connection, address = server.accept()
            try:
                handle_connection(connection, address, config)
            except (EOFError, OSError, ValueError) as error:
                print(f"Connection from {address[0]}:{address[1]} ended: {error}")
            finally:
                print("Waiting for the next sender...")


def handle_connection(connection: socket.socket, address: tuple[str, int], config: ReceiverConfig) -> None:
    player: FFplayProcess | None = None
    with closing(connection):
        print(f"Accepted stream from {address[0]}:{address[1]}")
        stream = connection.makefile("rwb")
        authenticate_stream(stream, config.password)
        header = read_stream_header(stream)
        print(f"Stream header: codec={header.codec} resolution={header.width}x{header.height} timescale={header.timescale}")
        player = FFplayProcess(ffplay_path=config.ffplay_path)
        player.start()
        cursor = CursorController(process_id=player.process_id)
        try:
            while True:
                packet = read_frame_packet(stream)
                if packet.is_cursor:
                    cursor.apply(parse_cursor_packet(packet))
                else:
                    player.write(packet.payload)
        except EOFError:
            print("Sender disconnected.")
        finally:
            if player is not None:
                player.close()


def main() -> None:
    run(parse_args())


if __name__ == "__main__":
    main()
