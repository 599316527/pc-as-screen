from __future__ import annotations

import os
import shutil
import subprocess
from typing import BinaryIO


class FFplayProcess:
    def __init__(self, ffplay_path: str | None = None) -> None:
        resolved = ffplay_path or shutil.which("ffplay")
        if not resolved:
            raise FileNotFoundError("ffplay was not found on PATH")
        self._ffplay_path = resolved
        self._process: subprocess.Popen[bytes] | None = None

    def start(self) -> None:
        if self._process is not None:
            return
        self._process = subprocess.Popen(
            [
                self._ffplay_path,
                "-fflags",
                "nobuffer",
                "-flags",
                "low_delay",
                "-framedrop",
                "-strict",
                "experimental",
                "-probesize",
                "32",
                "-sync",
                "video",
                "-f",
                "h264",
                "-i",
                "-",
            ],
            stdin=subprocess.PIPE,
        )

    def write(self, payload: bytes) -> None:
        if self._process is None or self._process.stdin is None:
            raise RuntimeError("ffplay process has not been started")
        if self._process.poll() is not None:
            raise BrokenPipeError("ffplay exited")
        self._process.stdin.write(payload)
        self._process.stdin.flush()

    @property
    def process_id(self) -> int | None:
        return self._process.pid if self._process is not None else None

    @property
    def has_exited(self) -> bool:
        return self._process is not None and self._process.poll() is not None

    def wait(self) -> int:
        if self._process is None:
            raise RuntimeError("ffplay process has not been started")
        return self._process.wait()

    def close_input(self) -> None:
        if self._process is None or self._process.stdin is None:
            return
        try:
            os.close(self._process.stdin.fileno())
        except OSError:
            pass

    def close(self) -> None:
        if self._process is None:
            return
        if self._process.poll() is None:
            self._process.terminate()
            try:
                self._process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self._process.kill()
                self._process.wait()
        if self._process.stdin is not None:
            self.close_input()
        self._process = None
