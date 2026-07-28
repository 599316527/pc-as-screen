from __future__ import annotations

import ctypes
import os
from ctypes import wintypes
from dataclasses import dataclass

from .protocol import CursorPacket


@dataclass(frozen=True)
class Rect:
    left: int
    top: int
    right: int
    bottom: int

    @property
    def width(self) -> int:
        return max(self.right - self.left, 1)

    @property
    def height(self) -> int:
        return max(self.bottom - self.top, 1)


class CursorController:
    def __init__(self, process_id: int | None) -> None:
        self._process_id = process_id
        self._window_handle: int | None = None
        self._enabled = os.name == "nt" and process_id is not None
        self._user32 = ctypes.WinDLL("user32", use_last_error=True) if self._enabled else None

    def apply(self, packet: CursorPacket) -> None:
        if not self._enabled or self._user32 is None:
            return

        rect = self._find_window_rect()
        if rect is None:
            return

        x = rect.left + round((packet.x / 65535) * (rect.width - 1))
        y = rect.top + round((packet.y / 65535) * (rect.height - 1))
        self._user32.SetCursorPos(x, y)

    def _find_window_rect(self) -> Rect | None:
        handle = self._window_handle
        if handle and self._is_window(handle):
            return self._get_client_rect(handle)

        handle = self._find_window_for_process()
        if handle is None:
            return None
        self._window_handle = handle
        return self._get_client_rect(handle)

    def _find_window_for_process(self) -> int | None:
        if self._user32 is None or self._process_id is None:
            return None

        handles: list[int] = []
        enum_windows_proc = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)

        def callback(handle: int, _: int) -> bool:
            if not self._user32.IsWindowVisible(handle):
                return True
            process_id = wintypes.DWORD()
            self._user32.GetWindowThreadProcessId(handle, ctypes.byref(process_id))
            if process_id.value == self._process_id:
                handles.append(handle)
                return False
            return True

        self._user32.EnumWindows(enum_windows_proc(callback), 0)
        return handles[0] if handles else None

    def _is_window(self, handle: int) -> bool:
        return bool(self._user32 and self._user32.IsWindow(handle))

    def _get_client_rect(self, handle: int) -> Rect | None:
        if self._user32 is None:
            return None

        rect = wintypes.RECT()
        if not self._user32.GetClientRect(handle, ctypes.byref(rect)):
            return None

        top_left = wintypes.POINT(rect.left, rect.top)
        bottom_right = wintypes.POINT(rect.right, rect.bottom)
        if not self._user32.ClientToScreen(handle, ctypes.byref(top_left)):
            return None
        if not self._user32.ClientToScreen(handle, ctypes.byref(bottom_right)):
            return None

        return Rect(
            left=top_left.x,
            top=top_left.y,
            right=bottom_right.x,
            bottom=bottom_right.y,
        )
