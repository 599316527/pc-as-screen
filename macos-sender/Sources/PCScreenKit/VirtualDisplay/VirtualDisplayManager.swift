import CoreGraphics
import Dispatch
import Foundation
import PrivateVirtualDisplayShim

public final class VirtualDisplayManager {
    private let queue = DispatchQueue(label: "pc-as-screen.virtual-display")
    private var display: CGVirtualDisplay?

    public init() {}

    @discardableResult
    public func createDisplay(configuration: VirtualDisplayConfiguration) throws -> CGDirectDisplayID {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = configuration.name
        descriptor.maxPixelsWide = UInt32(configuration.width)
        descriptor.maxPixelsHigh = UInt32(configuration.height)
        descriptor.sizeInMillimeters = configuration.sizeInMillimeters
        descriptor.vendorID = configuration.vendorID
        descriptor.productID = configuration.productID
        descriptor.serialNum = configuration.serialNumber
        descriptor.setDispatchQueue(queue)

        let virtualDisplay = CGVirtualDisplay(descriptor: descriptor)
        let mode = CGVirtualDisplayMode(
            width: configuration.width,
            height: configuration.height,
            refreshRate: CGFloat(configuration.refreshRate)
        )
        let settings = CGVirtualDisplaySettings()
        settings.modes = [mode]
        settings.hiDPI = 1

        guard virtualDisplay.apply(settings) else {
            throw PCScreenError.virtualDisplay("CGVirtualDisplay.applySettings failed. The private API may require different signing or OS support.")
        }

        display = virtualDisplay
        return virtualDisplay.displayID
    }

    public func destroyDisplay() {
        display = nil
    }
}
