import Foundation
import CryptoKit

public enum FrameType: UInt8, Sendable {
    case config = 0
    case delta = 1
    case key = 2
    case cursor = 3
    case mouseClick = 4
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
    private static let authContext = Data("pc-as-screen auth v1".utf8)

    public static func makeStreamHeader(_ header: StreamHeader) -> Data {
        var data = Data()
        data.append(magic)
        data.append(header.codec)
        data.append(contentsOf: bigEndianBytes(header.width))
        data.append(contentsOf: bigEndianBytes(header.height))
        data.append(contentsOf: bigEndianBytes(header.timescale))
        return data
    }

    public static func makeFramePacket(_ frame: EncodedFrame, typeOverride: FrameType? = nil) -> Data {
        let type = typeOverride ?? (frame.isKeyFrame ? .key : .delta)
        var data = Data()
        data.append(type.rawValue)
        data.append(contentsOf: bigEndianBytes(UInt32(frame.payload.count)))
        data.append(contentsOf: bigEndianBytes(frame.presentationTimestampMicros))
        data.append(contentsOf: bigEndianBytes(frame.decodeTimestampMicros))
        data.append(frame.payload)
        return data
    }

    public static func makeCursorPacket(_ cursor: CursorPosition) -> Data {
        var payload = Data()
        payload.append(contentsOf: bigEndianBytes(cursor.x))
        payload.append(contentsOf: bigEndianBytes(cursor.y))

        var data = Data()
        data.append(FrameType.cursor.rawValue)
        data.append(contentsOf: bigEndianBytes(UInt32(payload.count)))
        data.append(contentsOf: bigEndianBytes(cursor.timestampMicros))
        data.append(contentsOf: bigEndianBytes(cursor.timestampMicros))
        data.append(payload)
        return data
    }

    public static func parseMouseClickPacket(header: Data, payload: Data) throws -> MouseClick {
        guard header.count == 21 else {
            throw PCScreenError.network("Input packet header must be 21 bytes, got \(header.count).")
        }
        guard header[0] == FrameType.mouseClick.rawValue else {
            throw PCScreenError.network("Input packet type \(header[0]) is not a mouse click.")
        }
        let payloadLength = Int(readUInt32(header, at: 1))
        guard payloadLength == payload.count else {
            throw PCScreenError.network("Input packet payload length mismatch: expected \(payloadLength), got \(payload.count).")
        }
        guard payload.count == 4 else {
            throw PCScreenError.network("Mouse click payload must be 4 bytes, got \(payload.count).")
        }
        return MouseClick(
            x: readUInt16(payload, at: 0),
            y: readUInt16(payload, at: 2),
            timestampMicros: readUInt64(header, at: 5)
        )
    }

    public static func makeAuthDigest(password: String, nonce: Data) -> Data {
        let key = SymmetricKey(data: Data(password.utf8))
        var payload = Data()
        payload.append(authContext)
        payload.append(nonce)
        let digest = HMAC<SHA256>.authenticationCode(for: payload, using: key)
        return Data(digest)
    }

    public static func makeAuthResponse(password: String, nonce: Data) -> Data {
        var data = Data()
        data.append(authResponseMagic)
        data.append(makeAuthDigest(password: password, nonce: nonce))
        return data
    }

    public static func bigEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
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
}
