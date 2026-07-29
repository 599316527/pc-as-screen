import Foundation
import Testing
@testable import IPadReceiverCore

@Test
func parsesStreamHeaderBinaryLayout() throws {
    let payload = Data("PCSCRN1".utf8)
        + Data([1])
        + Data([0x07, 0x80, 0x04, 0x38, 0x00, 0x0F, 0x42, 0x40])

    let header = try PCScreenProtocol.parseStreamHeader(payload)

    #expect(header.codec == 1)
    #expect(header.width == 1920)
    #expect(header.height == 1080)
    #expect(header.timescale == 1_000_000)
}

@Test
func rejectsUnsupportedCodec() throws {
    let payload = Data("PCSCRN1".utf8)
        + Data([2])
        + Data([0x07, 0x80, 0x04, 0x38, 0x00, 0x0F, 0x42, 0x40])

    #expect(throws: IPadReceiverError.invalidCodec(2)) {
        _ = try PCScreenProtocol.parseStreamHeader(payload)
    }
}

@Test
func parsesFramePacketBinaryLayout() throws {
    let header = Data([
        2,
        0x00, 0x00, 0x00, 0x05,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7B,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x78,
    ])
    let payload = Data([0x00, 0x00, 0x00, 0x01, 0x65])

    let packet = try PCScreenProtocol.parseFramePacket(header: header, payload: payload)

    #expect(packet.frameType == .key)
    #expect(packet.presentationTimestampMicros == 123)
    #expect(packet.decodeTimestampMicros == 120)
    #expect(packet.payload == payload)
}

@Test
func parsesCursorPacket() throws {
    let header = Data([
        3,
        0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xC8,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xC8,
    ])
    let packet = try PCScreenProtocol.parseFramePacket(
        header: header,
        payload: Data([0x12, 0x34, 0xAB, 0xCD])
    )

    let cursor = try PCScreenProtocol.parseCursorPacket(packet)

    #expect(cursor.x == 0x1234)
    #expect(cursor.y == 0xABCD)
    #expect(cursor.timestampMicros == 456)
}

@Test
func mouseClickPacketUsesFrameEnvelope() {
    let click = MouseClick(x: 0x2222, y: 0xCCCC, timestampMicros: 789)

    let packet = PCScreenProtocol.makeMouseClickPacket(click)

    #expect(packet[0] == FrameType.mouseClick.rawValue)
    #expect(Array(packet[1...4]) == [0x00, 0x00, 0x00, 0x04])
    #expect(Array(packet[5...12]) == [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x15])
    #expect(Array(packet[13...20]) == [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x15])
    #expect(Array(packet[21...24]) == [0x22, 0x22, 0xCC, 0xCC])
}

@Test
func authResponseMatchesSenderDigest() throws {
    let nonce = Data(0..<32)
    let response = PCScreenProtocol.makeAuthResponse(password: "screen-pass", nonce: nonce)

    #expect(response.prefix(8) == Data("PCSRESP1".utf8))
    #expect(response.count == 40)
    #expect(response.suffix(32) == Data([
        0xa8, 0x59, 0xa1, 0xdb, 0x90, 0x91, 0xa0, 0x00,
        0xde, 0x0f, 0xd3, 0x08, 0xed, 0x69, 0xab, 0xa3,
        0x8d, 0xc0, 0x7d, 0x37, 0x6d, 0x61, 0x2d, 0xf4,
        0x16, 0x66, 0xc3, 0xc4, 0x74, 0x82, 0xc0, 0xd9,
    ]))
}

@Test
func parsesAuthenticationChallengeAndStatus() throws {
    let nonce = Data(0..<32)
    let challenge = Data("PCSAUTH1".utf8) + nonce

    #expect(try PCScreenProtocol.parseAuthChallenge(challenge) == nonce)
    #expect(try PCScreenProtocol.parseAuthStatus(Data("PCSOKAY1".utf8)) == ())
    #expect(throws: IPadReceiverError.authenticationRejected) {
        try PCScreenProtocol.parseAuthStatus(Data("PCSFAIL1".utf8))
    }
}
