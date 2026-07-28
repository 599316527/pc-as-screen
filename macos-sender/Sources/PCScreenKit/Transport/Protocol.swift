import Foundation
import CryptoKit

public enum FrameType: UInt8, Sendable {
    case config = 0
    case delta = 1
    case key = 2
    case cursor = 3
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
}
