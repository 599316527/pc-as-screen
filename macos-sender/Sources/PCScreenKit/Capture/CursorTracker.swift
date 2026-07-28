import CoreGraphics
import Dispatch
import Foundation

public final class CursorTracker: @unchecked Sendable {
    public typealias Handler = @Sendable (CursorPosition) -> Void

    private let displayID: CGDirectDisplayID
    private let fps: Int
    private let handler: Handler
    private let queue = DispatchQueue(label: "pc-as-screen.cursor")
    private var timer: DispatchSourceTimer?
    private var lastPosition: CursorPosition?

    public init(displayID: CGDirectDisplayID, fps: Int = 120, handler: @escaping Handler) {
        self.displayID = displayID
        self.fps = max(fps, 1)
        self.handler = handler
    }

    public func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .microseconds(1_000_000 / fps), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.sampleCursor()
        }
        self.timer = timer
        timer.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        lastPosition = nil
    }

    private func sampleCursor() {
        let displayBounds = CGDisplayBounds(displayID)
        guard let mouseLocation = CGEvent(source: nil)?.location else { return }
        guard displayBounds.contains(mouseLocation), displayBounds.width > 0, displayBounds.height > 0 else {
            return
        }

        let x = normalizedCoordinate(mouseLocation.x - displayBounds.minX, length: displayBounds.width)
        let y = normalizedCoordinate(mouseLocation.y - displayBounds.minY, length: displayBounds.height)
        let position = CursorPosition(x: x, y: y, timestampMicros: Self.currentTimeMicros())
        guard position.x != lastPosition?.x || position.y != lastPosition?.y else { return }
        lastPosition = position
        handler(position)
    }

    private func normalizedCoordinate(_ value: CGFloat, length: CGFloat) -> UInt16 {
        let clamped = min(max(value / length, 0), 1)
        return UInt16((clamped * CGFloat(UInt16.max)).rounded())
    }

    private static func currentTimeMicros() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1_000_000)
    }
}
