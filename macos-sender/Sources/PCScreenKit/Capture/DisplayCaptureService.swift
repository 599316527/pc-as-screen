import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

public final class DisplayCaptureService: NSObject, SCStreamOutput {
    public typealias FrameHandler = @Sendable (CMSampleBuffer) -> Void

    private let frameHandler: FrameHandler
    private let queue = DispatchQueue(label: "pc-as-screen.capture")
    private var stream: SCStream?

    public init(frameHandler: @escaping FrameHandler) {
        self.frameHandler = frameHandler
    }

    public func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int, showsCursor: Bool) async throws {
        let content = try await SCShareableContent.current
        guard let targetDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
            throw PCScreenError.capture("Target display \(displayID) was not found in ScreenCaptureKit shareable content.")
        }

        let filter = SCContentFilter(display: targetDisplay, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))
        configuration.queueDepth = 5
        configuration.showsCursor = showsCursor

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    public func stop() async {
        guard let stream else { return }
        do {
            try await stream.stopCapture()
        } catch {
            // Ignore teardown errors in MVP shutdown.
        }
        self.stream = nil
    }

    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen else { return }
        guard Self.isCompleteVideoFrame(sampleBuffer) else { return }
        frameHandler(sampleBuffer)
    }

    private static func isCompleteVideoFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return false }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]] else {
            return true
        }
        guard let statusValue = attachments.first?[.status] as? Int else { return true }
        return SCFrameStatus(rawValue: statusValue) == .complete
    }
}
