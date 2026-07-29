import CoreMedia
import CoreVideo
import Dispatch
import Foundation

public final class TestPatternStreamingSession {
    private let config: StreamConfiguration
    private let durationSeconds: Double
    private let encoder: H264Encoder
    private let sender: TCPSender

    public init(config: StreamConfiguration, durationSeconds: Double) throws {
        self.config = config
        self.durationSeconds = max(durationSeconds, 0.1)
        self.sender = try TCPSender(host: config.host, port: config.port, password: config.password)
        let frameQueue = DispatchQueue(label: "pc-as-screen.test-pattern.sender")
        self.encoder = H264Encoder(
            width: config.width,
            height: config.height,
            bitrate: config.bitrate,
            fps: config.refreshRate
        ) { [sender] frame in
            frameQueue.async {
                Task {
                    try? await sender.sendFrame(frame)
                }
            }
        }
    }

    public func run() async throws {
        try encoder.start()
        try await sender.connect(
            header: StreamHeader(
                width: UInt16(config.width),
                height: UInt16(config.height)
            )
        )
        sender.startReceivingInput { click in
            print("PC_AS_SCREEN_E2E_SENDER_MOUSE_CLICK x=\(click.x) y=\(click.y)")
            fflush(stdout)
        }
        if config.showsCursor {
            try await sender.sendCursor(
                CursorPosition(
                    x: UInt16.max / 2,
                    y: UInt16.max / 2,
                    timestampMicros: Self.currentTimeMicros()
                )
            )
        }

        let frameCount = max(1, Int((durationSeconds * Double(config.refreshRate)).rounded(.up)))
        let frameIntervalNanos = UInt64(1_000_000_000 / max(config.refreshRate, 1))
        for index in 0..<frameCount {
            let sampleBuffer = try Self.makeSampleBuffer(width: config.width, height: config.height, frameIndex: index)
            try encoder.encode(sampleBuffer: sampleBuffer)
            try await Task.sleep(nanoseconds: frameIntervalNanos)
        }
        encoder.stop()
        try await Task.sleep(nanoseconds: 300_000_000)
        sender.close()
    }

    private static func currentTimeMicros() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1_000_000)
    }

    private static func makeSampleBuffer(width: Int, height: Int, frameIndex: Int) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        let pixelStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard pixelStatus == kCVReturnSuccess, let pixelBuffer else {
            throw PCScreenError.encoding("Failed to create test pattern pixel buffer: \(pixelStatus)")
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw PCScreenError.encoding("Missing test pattern pixel buffer base address.")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
        let moving = frameIndex * 9
        for y in 0..<height {
            let row = pointer.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let offset = x * 4
                let band = ((x + moving) * 6) / max(width, 1)
                let r: UInt8
                let g: UInt8
                let b: UInt8
                switch band % 6 {
                case 0:
                    (r, g, b) = (240, 40, 40)
                case 1:
                    (r, g, b) = (240, 220, 40)
                case 2:
                    (r, g, b) = (40, 220, 80)
                case 3:
                    (r, g, b) = (40, 210, 230)
                case 4:
                    (r, g, b) = (60, 80, 240)
                default:
                    (r, g, b) = (210, 60, 230)
                }
                let checker: UInt8 = ((x / 32 + y / 32 + frameIndex) % 2 == 0) ? 30 : 0
                row[offset] = b &+ checker
                row[offset + 1] = g &+ checker
                row[offset + 2] = r &+ checker
                row[offset + 3] = 255
            }
        }

        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw PCScreenError.encoding("Failed to create test pattern format description: \(formatStatus)")
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: CMTimeValue(frameIndex), timescale: 30),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw PCScreenError.encoding("Failed to create test pattern sample buffer: \(sampleStatus)")
        }
        return sampleBuffer
    }
}
