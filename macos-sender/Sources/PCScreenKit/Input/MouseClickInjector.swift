import CoreGraphics
import Foundation

public final class MouseClickInjector: @unchecked Sendable {
    private let displayID: CGDirectDisplayID

    public init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    public func click(_ click: MouseClick) {
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else {
            return
        }
        let x = bounds.minX + CGFloat(click.x) / 65535 * bounds.width
        let y = bounds.minY + CGFloat(click.y) / 65535 * bounds.height
        let point = CGPoint(x: x, y: y)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }
}
