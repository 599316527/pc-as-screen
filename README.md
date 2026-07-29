# pc-as-screen

`pc-as-screen` is a minimal MVP that lets a Windows machine or iPad act as a software-only external display receiver for macOS over a LAN.

This repository intentionally focuses on the first working chain only:

- macOS creates a virtual display with the private `CGVirtualDisplay` API.
- macOS captures that display with `ScreenCaptureKit`.
- macOS encodes frames with `VideoToolbox` H.264.
- macOS pushes the stream over a simple custom TCP protocol.
- Windows receives the H.264 Annex-B stream and displays it with `ffplay`.
- iPad listens for the same sender protocol, converts Annex-B H.264 into iOS sample buffers, and displays with `AVSampleBufferDisplayLayer`.

Out of scope for this MVP:

- WebRTC, ICE, STUN, TURN
- audio transport
- keyboard input return or multi-touch gesture return
- multiple virtual displays
- congestion control or retransmission
- a polished Windows native shell

## Repository layout

- `macos-sender/`: Swift Package for the macOS sender.
- `windows-receiver/`: minimal Windows receiver implemented in Python and backed by `ffplay`.
- `ipad-receiver/`: Swift Package for the iPad receiver core, tests, and SwiftUI app entry.
- `docs/protocol.md`: binary protocol definition.
- `docs/private-api-and-limitations.md`: private API requirements, permissions, and known limitations.
- `scripts/verify.sh`: targeted local validation used by OMH verify.

## Prerequisites

### macOS sender

- macOS 15+ recommended
- Xcode 26.4.1+
- Swift 6.3.1+
- Screen Recording permission for the terminal or host app running the sender
- private `CGVirtualDisplay` availability on the current OS build

### Windows receiver

- Python 3.11+
- `ffplay.exe` available on `PATH`, or passed explicitly with `--ffplay`

### iPad receiver

- Xcode with iOS 17 SDK or newer
- An iPad or iPad Simulator on the same LAN route as the macOS sender for live streaming
- Local Network permission accepted when the app starts listening

## Build and validate

Run the targeted checks used for this MVP:

```bash
bash ./scripts/verify.sh
```

Run the sender package checks only:

```bash
swift test --package-path ./macos-sender
```

Run the receiver protocol tests only:

```bash
python3 -m unittest discover -s ./windows-receiver/tests -v
```

Run the iPad receiver protocol and H.264 conversion tests only:

```bash
swift test --package-path ./ipad-receiver
```

Run the iPad Simulator E2E check:

```bash
bash ./scripts/e2e-ipad-simulator.sh
```

The simulator E2E builds `IPadReceiverApp`, boots an iPad Simulator, installs and launches the app, starts the receiver in automated listening mode, and runs the local `PCScreenSender` executable in test-pattern mode twice. It verifies authenticated receive, native H.264 display, non-black simulator screenshot pixels, disconnect, and reconnect. To include it in the main verify script:

```bash
PC_AS_SCREEN_RUN_IPAD_E2E=1 bash ./scripts/verify.sh
```

## Run the Windows receiver

On a Windows machine with Python and `ffplay.exe` installed:

```bat
cd windows-receiver
run_receiver.bat --host 0.0.0.0 --port 6000 --password "shared-pass"
```

Or directly:

```powershell
$env:PYTHONPATH = "."
python -m pc_as_screen_receiver.receiver --host 0.0.0.0 --port 6000 --password "shared-pass" --ffplay "C:\ffmpeg\bin\ffplay.exe"
```

You can also set `PC_AS_SCREEN_PASSWORD` instead of passing `--password`, which avoids showing the password in process arguments.

## Run the iPad receiver

Open `ipad-receiver/Package.swift` in Xcode and use the `IPadReceiverApp` SwiftUI entry point from an iOS app target or package-aware Xcode workspace. Run that target on an iPad or iPad Simulator.

In the app:

- `Port`: the TCP sender port, default `6000`.
- `Password`: optional shared password. Leave empty when the sender is launched without `--password`.
- `Start`: starts listening for sender TCP connections, optional authentication, stream header parsing, frame parsing, Annex-B to AVCC conversion, and `AVSampleBufferDisplayLayer` display. After Start, the receiver keeps listening so a sender can disconnect and reconnect.

The iPad receiver parses cursor packets and draws the remote pointer over the displayed video. It also sends taps on the displayed video content back to macOS as normalized left mouse clicks. Taps in aspect-fit padding are ignored.

## Run the macOS sender

Start the receiver first, then run the sender from macOS:

```bash
swift run --package-path ./macos-sender PCScreenSender \
  --host 192.168.1.50 \
  --port 6000 \
  --width 1920 \
  --height 1080 \
  --fps 60 \
  --bitrate 8000000 \
  --display-name "PC as Screen" \
  --password "shared-pass"
```

Sender arguments:

- `--host`: receiver IP or hostname, required
- `--port`: receiver TCP port, default `6000`
- `--width`: virtual display width, default `1920`
- `--height`: virtual display height, default `1080`
- `--fps`: capture and encode frame rate, default `60`
- `--bitrate`: H.264 average bitrate, default `8000000`
- `--display-name`: virtual display name shown in macOS, default `PC as Screen`
- `--password`: optional shared password. Can also be set via `PC_AS_SCREEN_PASSWORD`
- `--hide-cursor`: set to `true` to disable cursor synchronization. The cursor is sent separately from the video stream by default

When connected to the iPad receiver, taps on the iPad video surface are returned to the sender as left mouse clicks on the virtual display. macOS may require Accessibility/Input Monitoring permission for the terminal or wrapper app before synthetic clicks can affect other apps.

Password authentication prevents an unauthenticated LAN client from starting a stream, but the video payload is still plain TCP rather than encrypted.

## Verification scope for this MVP

Locally validated in this repository:

- Swift sender package compiles
- protocol framing tests pass
- Python receiver protocol tests pass
- iPad receiver protocol, authentication digest, cursor parsing, and H.264 Annex-B conversion tests pass
- iPad Simulator app build, install, launch, listener startup, authenticated protocol connection, stream header parsing, native H.264 display, non-black screenshot validation, and reconnect pass via `scripts/e2e-ipad-simulator.sh` with the local `PCScreenSender` executable in test-pattern mode

Not locally validated in this environment:

- end-to-end macOS to Windows live playback on a real Windows host
- end-to-end macOS virtual-display capture to iPad live playback on a real iPad
- runtime success of `CGVirtualDisplay` on the current machine and signing context
- ScreenCaptureKit permission prompts and acceptance flow

See [docs/private-api-and-limitations.md](docs/private-api-and-limitations.md) and [docs/protocol.md](docs/protocol.md) for the concrete operating constraints.
