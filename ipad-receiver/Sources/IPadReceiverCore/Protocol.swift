import CryptoKit
import Foundation

public enum IPadReceiverError: Error, Equatable, CustomStringConvertible, Sendable {
    case endOfStream(expected: Int, actual: Int)
    case invalidMagic(String)
    case invalidCodec(UInt8)
    case invalidFrameType(UInt8)
    case invalidCursorPayloadLength(Int)
    case invalidAuthChallenge
    case authenticationRejected
    case invalidNALUnit
    case missingParameterSets
    case sampleBufferUnavailable(String)
    case network(String)

    public var description: String {
        switch self {
        case .endOfStream(let expected, let actual):
            return "expected \(expected) bytes, got \(actual) before EOF"
        case .invalidMagic(let message):
            return message
        case .invalidCodec(let codec):
            return "unsupported codec id \(codec); expected H.264 codec id 1"
        case .invalidFrameType(let value):
            return "unsupported frame type \(value)"
        case .invalidCursorPayloadLength(let count):
            return "cursor packet payload must be 4 bytes, got \(count)"
        case .invalidAuthChallenge:
            return "receiver sent an invalid authentication challenge"
        case .authenticationRejected:
            return "receiver rejected the password"
        case .invalidNALUnit:
            return "invalid H.264 Annex-B NAL unit"
        case .missingParameterSets:
            return "H.264 key frame did not include both SPS and PPS"
        case .sampleBufferUnavailable(let message),
             .network(let message):
            return message
        }
    }
}

public enum FrameType: UInt8, Equatable, Sendable {
    case config = 0
    case delta = 1
    case key = 2
    case cursor = 3
    case mouseClick = 4
}

public struct StreamHeader: Equatable, Sendable {
    public var codec: UInt8
    public var width: UInt16
    public var height: UInt16
    public var timescale: UInt32

    public init(codec: UInt8, width: UInt16, height: UInt16, timescale: UInt32) {
        self.codec = codec
        self.width = width
        self.height = height
        self.timescale = timescale
    }
}

public struct FramePacket: Equatable, Sendable {
    public var frameType: FrameType
    public var presentationTimestampMicros: UInt64
    public var decodeTimestampMicros: UInt64
    public var payload: Data

    public init(
        frameType: FrameType,
        presentationTimestampMicros: UInt64,
        decodeTimestampMicros: UInt64,
        payload: Data
    ) {
        self.frameType = frameType
        self.presentationTimestampMicros = presentationTimestampMicros
        self.decodeTimestampMicros = decodeTimestampMicros
        self.payload = payload
    }

    public var isCursor: Bool {
        frameType == .cursor
    }

    public var isConfig: Bool {
        frameType == .config
    }

    public var isKeyFrame: Bool {
        frameType == .key
    }
}

public struct CursorPacket: Equatable, Sendable {
    public var x: UInt16
    public var y: UInt16
    public var timestampMicros: UInt64

    public init(x: UInt16, y: UInt16, timestampMicros: UInt64) {
        self.x = x
        self.y = y
        self.timestampMicros = timestampMicros
    }
}

public struct MouseClick: Equatable, Sendable {
    public var x: UInt16
    public var y: UInt16
    public var timestampMicros: UInt64

    public init(x: UInt16, y: UInt16, timestampMicros: UInt64) {
        self.x = x
        self.y = y
        self.timestampMicros = timestampMicros
    }
}

public enum PCScreenProtocol {
    public static let magic = Data("PCSCRN1".utf8)
    public static let authHelloMagic = Data("PCSHELLO".utf8)
    public static let authChallengeMagic = Data("PCSAUTH1".utf8)
    public static let authResponseMagic = Data("PCSRESP1".utf8)
    public static let authAcceptedMagic = Data("PCSOKAY1".utf8)
    public static let authRejectedMagic = Data("PCSFAIL1".utf8)
    public static let authNonceSize = 32
    public static let authDigestSize = 32
    public static let streamHeaderSize = 16
    public static let frameHeaderSize = 21
    private static let authContext = Data("pc-as-screen auth v1".utf8)

    public static func parseStreamHeader(_ data: Data) throws -> StreamHeader {
        guard data.count == streamHeaderSize else {
            throw IPadReceiverError.endOfStream(expected: streamHeaderSize, actual: data.count)
        }
        let magicBytes = data.prefix(magic.count)
        guard magicBytes == magic else {
            throw IPadReceiverError.invalidMagic("invalid stream magic \(Array(magicBytes)), expected \(Array(magic))")
        }
        let codec = data[7]
        guard codec == 1 else {
            throw IPadReceiverError.invalidCodec(codec)
        }
        return StreamHeader(
            codec: codec,
            width: readUInt16(data, at: 8),
            height: readUInt16(data, at: 10),
            timescale: readUInt32(data, at: 12)
        )
    }

    public static func parseFramePacket(header: Data, payload: Data) throws -> FramePacket {
        guard header.count == frameHeaderSize else {
            throw IPadReceiverError.endOfStream(expected: frameHeaderSize, actual: header.count)
        }
        guard let frameType = FrameType(rawValue: header[0]) else {
            throw IPadReceiverError.invalidFrameType(header[0])
        }
        let expectedPayloadLength = Int(readUInt32(header, at: 1))
        guard payload.count == expectedPayloadLength else {
            throw IPadReceiverError.endOfStream(expected: expectedPayloadLength, actual: payload.count)
        }
        return FramePacket(
            frameType: frameType,
            presentationTimestampMicros: readUInt64(header, at: 5),
            decodeTimestampMicros: readUInt64(header, at: 13),
            payload: payload
        )
    }

    public static func payloadLength(fromFrameHeader header: Data) throws -> Int {
        guard header.count == frameHeaderSize else {
            throw IPadReceiverError.endOfStream(expected: frameHeaderSize, actual: header.count)
        }
        return Int(readUInt32(header, at: 1))
    }

    public static func parseCursorPacket(_ packet: FramePacket) throws -> CursorPacket {
        guard packet.frameType == .cursor else {
            throw IPadReceiverError.invalidFrameType(packet.frameType.rawValue)
        }
        guard packet.payload.count == 4 else {
            throw IPadReceiverError.invalidCursorPayloadLength(packet.payload.count)
        }
        return CursorPacket(
            x: readUInt16(packet.payload, at: 0),
            y: readUInt16(packet.payload, at: 2),
            timestampMicros: packet.presentationTimestampMicros
        )
    }

    public static func makeMouseClickPacket(_ click: MouseClick) -> Data {
        var payload = Data()
        payload.append(contentsOf: bigEndianBytes(click.x))
        payload.append(contentsOf: bigEndianBytes(click.y))

        var data = Data()
        data.append(FrameType.mouseClick.rawValue)
        data.append(contentsOf: bigEndianBytes(UInt32(payload.count)))
        data.append(contentsOf: bigEndianBytes(click.timestampMicros))
        data.append(contentsOf: bigEndianBytes(click.timestampMicros))
        data.append(payload)
        return data
    }

    public static func makeAuthDigest(password: String, nonce: Data) -> Data {
        let key = SymmetricKey(data: Data(password.utf8))
        var payload = Data()
        payload.append(authContext)
        payload.append(nonce)
        return Data(HMAC<SHA256>.authenticationCode(for: payload, using: key))
    }

    public static func makeAuthResponse(password: String, nonce: Data) -> Data {
        var data = Data()
        data.append(authResponseMagic)
        data.append(makeAuthDigest(password: password, nonce: nonce))
        return data
    }

    public static func parseAuthChallenge(_ data: Data) throws -> Data {
        let expectedLength = authChallengeMagic.count + authNonceSize
        guard data.count == expectedLength else {
            throw IPadReceiverError.endOfStream(expected: expectedLength, actual: data.count)
        }
        guard data.prefix(authChallengeMagic.count) == authChallengeMagic else {
            throw IPadReceiverError.invalidAuthChallenge
        }
        return Data(data.suffix(authNonceSize))
    }

    public static func parseAuthStatus(_ data: Data) throws {
        if data == authAcceptedMagic {
            return
        }
        if data == authRejectedMagic {
            throw IPadReceiverError.authenticationRejected
        }
        throw IPadReceiverError.invalidAuthChallenge
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in offset..<(offset + 8) {
            value = (value << 8) | UInt64(data[index])
        }
        return value
    }

    private static func bigEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
    }
}
