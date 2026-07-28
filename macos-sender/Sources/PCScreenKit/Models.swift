import CoreGraphics
import Foundation

public struct StreamConfiguration: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var refreshRate: Int
    public var bitrate: Int
    public var host: String
    public var port: UInt16
    public var displayName: String
    public var password: String?
    public var showsCursor: Bool

    public init(
        width: Int = 1920,
        height: Int = 1080,
        refreshRate: Int = 60,
        bitrate: Int = 8_000_000,
        host: String,
        port: UInt16 = 6000,
        displayName: String = "PC as Screen",
        password: String? = nil,
        showsCursor: Bool = true
    ) {
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.bitrate = bitrate
        self.host = host
        self.port = port
        self.displayName = displayName
        self.password = password
        self.showsCursor = showsCursor
    }
}

public struct VirtualDisplayConfiguration: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var refreshRate: Int
    public var name: String
    public var sizeInMillimeters: CGSize
    public var vendorID: UInt32
    public var productID: UInt32
    public var serialNumber: UInt32

    public init(
        width: Int,
        height: Int,
        refreshRate: Int,
        name: String,
        sizeInMillimeters: CGSize = CGSize(width: 340, height: 190),
        vendorID: UInt32 = 0x756E,
        productID: UInt32 = 0x5053,
        serialNumber: UInt32 = 1
    ) {
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.name = name
        self.sizeInMillimeters = sizeInMillimeters
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
    }
}

public struct StreamHeader: Sendable, Equatable {
    public static let version: UInt8 = 1

    public var codec: UInt8
    public var width: UInt16
    public var height: UInt16
    public var timescale: UInt32

    public init(codec: UInt8 = 1, width: UInt16, height: UInt16, timescale: UInt32 = 1_000_000) {
        self.codec = codec
        self.width = width
        self.height = height
        self.timescale = timescale
    }
}

public struct EncodedFrame: Sendable, Equatable {
    public var isKeyFrame: Bool
    public var presentationTimestampMicros: UInt64
    public var decodeTimestampMicros: UInt64
    public var payload: Data

    public init(
        isKeyFrame: Bool,
        presentationTimestampMicros: UInt64,
        decodeTimestampMicros: UInt64,
        payload: Data
    ) {
        self.isKeyFrame = isKeyFrame
        self.presentationTimestampMicros = presentationTimestampMicros
        self.decodeTimestampMicros = decodeTimestampMicros
        self.payload = payload
    }
}

public struct CursorPosition: Sendable, Equatable {
    public var x: UInt16
    public var y: UInt16
    public var timestampMicros: UInt64

    public init(x: UInt16, y: UInt16, timestampMicros: UInt64) {
        self.x = x
        self.y = y
        self.timestampMicros = timestampMicros
    }
}

public enum PCScreenError: Error, CustomStringConvertible, Sendable {
    case invalidArgument(String)
    case capture(String)
    case encoding(String)
    case network(String)
    case virtualDisplay(String)

    public var description: String {
        switch self {
        case .invalidArgument(let message),
             .capture(let message),
             .encoding(let message),
             .network(let message),
             .virtualDisplay(let message):
            return message
        }
    }
}
