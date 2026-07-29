# Private API, Permissions, and Limitations

## Private API status

The macOS sender uses the undocumented `CGVirtualDisplay`, `CGVirtualDisplayDescriptor`, `CGVirtualDisplayMode`, and `CGVirtualDisplaySettings` classes through a small Objective-C shim.

This has concrete consequences:

- It is not App Store safe.
- It may break across macOS releases without source compatibility guarantees.
- It may require specific signing, entitlements, or execution context that are not documented by Apple.
- It can fail at runtime even if the project compiles successfully.

This repository isolates the private API calls under `macos-sender/Sources/PCScreenKit/VirtualDisplay/` and `macos-sender/Sources/PrivateVirtualDisplayShim/` so the risk surface is explicit.

## Required macOS permissions

The sender needs Screen Recording permission for the process that runs `PCScreenSender`, because `ScreenCaptureKit` is used to capture the virtual display.

Mouse-click return posts synthetic left-click events through `CGEvent`, so the same process may also need Accessibility and Input Monitoring permission before clicks can control other apps.

Recommended checks before running:

1. Grant Screen Recording access to the terminal, IDE, or wrapper app you will use.
2. Confirm the host can see displays through `ScreenCaptureKit`.
3. Be prepared for a permission prompt on first launch.

## Runtime limitations in this MVP

- The sender creates one virtual display only.
- The sender assumes the created display is discoverable through `SCShareableContent.current`.
- The sender does not implement display resize renegotiation.
- There is no audio path.
- Input return is limited to iPad left mouse clicks; keyboard input and gestures are not implemented.
- There is no adaptive bitrate or network recovery.
- The receiver uses `ffplay` rather than a custom Direct3D or Media Foundation renderer.

## Validation status

Locally validated:

- Swift package compilation
- sender-side protocol framing tests
- receiver-side protocol parsing tests

Not locally validated in this environment:

- successful creation of a real `CGVirtualDisplay`
- successful capture of the created virtual display after permissions are granted
- successful hardware H.264 encode from a live captured frame stream
- successful end-to-end playback on a real Windows machine

## Practical troubleshooting

If the sender starts but the virtual display path fails:

- verify the current macOS version still exposes the private classes
- run from a normal desktop session, not a headless CI shell
- inspect whether `CGVirtualDisplay.apply(_:)` returns `false`

If the sender connects but Windows shows no video:

- verify `ffplay` is installed and runnable
- confirm the sender points to the correct receiver IP and port
- capture the TCP stream and confirm the first 7 bytes are `PCSCRN1`
- confirm the H.264 payload starts with Annex-B start codes `00 00 00 01`
