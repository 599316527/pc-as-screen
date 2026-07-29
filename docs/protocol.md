# Stream Protocol

The MVP transport is a single TCP connection carrying one H.264 video stream in Annex-B format plus a small mouse-click return path for the iPad receiver.

## Connection model

1. The Windows receiver binds a TCP port and waits for one sender connection.
2. The macOS sender connects.
3. If both sides are configured with a shared password, they complete the authentication handshake.
4. The sender writes a fixed-size stream header.
5. The sender continuously writes frame packets until disconnect.
6. The iPad receiver may write mouse-click packets back on the same TCP connection after the stream header is received.
7. After a disconnect, the receiver closes the current player process and waits for the next sender.

No keepalive, retransmission, or multiplexing is included in this MVP. The receiver handles one active sender at a time.

## Optional authentication

Authentication is enabled when the receiver is configured with a password. The sender must use the same password.

The handshake is:

1. Sender writes ASCII `PCSHELLO`.
2. Receiver writes ASCII `PCSAUTH1` followed by a 32-byte random nonce.
3. Sender writes ASCII `PCSRESP1` followed by `HMAC-SHA256(password, "pc-as-screen auth v1" || nonce)`.
4. Receiver writes ASCII `PCSOKAY1` if the digest matches, otherwise ASCII `PCSFAIL1` and closes the stream.

This protects the receiver from unauthenticated LAN connections. The video stream itself is still sent over plain TCP and is not encrypted.

## Stream header

Sent once, exactly 16 bytes:

| Offset | Size | Type   | Description |
| ------ | ---- | ------ | ----------- |
| 0      | 7    | bytes  | ASCII magic `PCSCRN1` |
| 7      | 1    | u8     | codec id. `1` means H.264 |
| 8      | 2    | u16 be | width |
| 10     | 2    | u16 be | height |
| 12     | 4    | u32 be | timestamp timescale. Current sender uses `1000000` |

All integer fields are big-endian.

## Frame packet

Each packet after the stream header uses this envelope:

| Offset | Size | Type   | Description |
| ------ | ---- | ------ | ----------- |
| 0      | 1    | u8     | frame type |
| 1      | 4    | u32 be | payload length in bytes |
| 5      | 8    | u64 be | presentation timestamp in microseconds |
| 13     | 8    | u64 be | decode timestamp in microseconds |
| 21     | N    | bytes  | H.264 Annex-B payload |

Frame types:

- `0`: reserved config packet
- `1`: delta frame
- `2`: key frame
- `3`: cursor position
- `4`: mouse click

## Video payload

- The sender emits Annex-B H.264 elementary stream data.
- Key frames prepend SPS/PPS NAL units before the access unit.
- The receiver forwards the payload bytes directly to `ffplay -f h264 -i -`.

## Cursor payload

Cursor packets use frame type `3` and a 4-byte payload:

| Offset | Size | Type   | Description |
| ------ | ---- | ------ | ----------- |
| 0      | 2    | u16 be | x position normalized to `0...65535` across the captured display |
| 2      | 2    | u16 be | y position normalized to `0...65535` across the captured display |

The macOS sender does not embed the cursor into the H.264 video stream. It sends cursor packets separately so receivers can draw or move a pointer with less video pipeline latency. The iPad receiver draws a local pointer overlay at the normalized position.

## Mouse click payload

The iPad receiver sends mouse-click packets back to the macOS sender with frame type `4` and a 4-byte payload:

| Offset | Size | Type   | Description |
| ------ | ---- | ------ | ----------- |
| 0      | 2    | u16 be | x position normalized to `0...65535` across the displayed video content |
| 2      | 2    | u16 be | y position normalized to `0...65535` across the displayed video content |

The macOS sender maps the normalized coordinates onto the virtual display bounds and posts a left mouse down/up pair. The iPad receiver computes coordinates against the aspect-fit video content rect; taps in letterboxed or pillarboxed padding are ignored.

## Decoder expectations

- A compliant receiver does not need an MP4 container or RTP framing.
- The receiver should preserve ordering exactly as received over TCP.
- Timestamps are included for future use, but the current MVP player path does not actively schedule on them.
- The iPad receiver consumes the same Annex-B payload, extracts SPS/PPS from key frames, converts NAL units to 4-byte length-prefixed AVCC payloads, and submits them to the native H.264 decode/display pipeline.
- iPad key-frame decode requires both SPS and PPS to have been received. A key frame without parameter sets is treated as a stream error rather than guessed.
- The macOS sender must keep reading from the TCP connection after startup if it wants to receive iPad mouse-click packets.

## Known limitations

- TCP head-of-line blocking can increase latency during packet loss.
- There is no codec negotiation; receiver and sender are hard-coded to H.264.
- There is no explicit parameter renegotiation on resize.
- Password authentication does not encrypt the video payload.
- The cursor side-channel moves the Windows system cursor over the `ffplay` window. The iPad receiver draws an in-app pointer overlay.
- Mouse-click return is currently implemented for the iPad receiver only; keyboard input is not included.
