import CoreGraphics
import CoreMedia
import Dispatch
import Foundation

public final class StreamingSession {
    private let config: StreamConfiguration
    private let virtualDisplayManager: VirtualDisplayManager
    private let encoder: H264Encoder
    private let sender: TCPSender
    private let displayConfiguration: VirtualDisplayConfiguration
    private var cursorTracker: CursorTracker?
    private var mouseClickInjector: MouseClickInjector?
    private lazy var captureService: DisplayCaptureService = DisplayCaptureService(
        frameHandler: StreamingSession.makeFrameHandler(encoder: encoder)
    )

    public init(config: StreamConfiguration) throws {
        self.config = config
        self.displayConfiguration = VirtualDisplayConfiguration(
            width: config.width,
            height: config.height,
            refreshRate: config.refreshRate,
            name: config.displayName
        )
        let sender = try TCPSender(host: config.host, port: config.port, password: config.password)
        let frameQueue = DispatchQueue(label: "pc-as-screen.streaming.encoder")
        self.sender = sender
        self.virtualDisplayManager = VirtualDisplayManager()
        self.encoder = H264Encoder(
            width: config.width,
            height: config.height,
            bitrate: config.bitrate,
            fps: config.refreshRate
        ) { frame in
            frameQueue.async {
                Task {
                    try? await sender.sendFrame(frame)
                }
            }
        }
    }

    public func run() async throws {
        let displayID = try virtualDisplayManager.createDisplay(configuration: displayConfiguration)
        try encoder.start()
        try await sender.connect(
            header: StreamHeader(
                width: UInt16(config.width),
                height: UInt16(config.height)
            )
        )
        let clickInjector = MouseClickInjector(displayID: displayID)
        mouseClickInjector = clickInjector
        sender.startReceivingInput { click in
            clickInjector.click(click)
        }
        try await captureService.start(
            displayID: displayID,
            width: config.width,
            height: config.height,
            fps: config.refreshRate,
            showsCursor: false
        )
        if config.showsCursor {
            let tracker = CursorTracker(displayID: displayID) { [sender] cursor in
                Task {
                    try? await sender.sendCursor(cursor)
                }
            }
            cursorTracker = tracker
            tracker.start()
        }
    }

    public func stop() async {
        cursorTracker?.stop()
        cursorTracker = nil
        mouseClickInjector = nil
        await captureService.stop()
        encoder.stop()
        sender.close()
        virtualDisplayManager.destroyDisplay()
    }

    private static func makeFrameHandler(encoder: H264Encoder) -> @Sendable (CMSampleBuffer) -> Void {
        { sampleBuffer in
            do {
                try encoder.encode(sampleBuffer: sampleBuffer)
            } catch {
                fputs("Encode error: \(error)\n", stderr)
            }
        }
    }
}
