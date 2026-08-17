import Foundation
import Synchronization
import Testing
@testable import PCScreenKit

private enum TestTransportError: Error {
    case sendFailed
}

private final class ScriptedTransport: StreamTransport, @unchecked Sendable {
    private let failsOnConnect: Bool
    private let failsOnSend: Bool

    init(failsOnConnect: Bool = false, failsOnSend: Bool) {
        self.failsOnConnect = failsOnConnect
        self.failsOnSend = failsOnSend
    }

    func connect(header: StreamHeader) async throws {
        if failsOnConnect {
            throw TestTransportError.sendFailed
        }
    }

    func sendFrame(_ frame: EncodedFrame, typeOverride: FrameType?) async throws {
        if failsOnSend {
            throw TestTransportError.sendFailed
        }
    }

    func sendCursor(_ cursor: CursorPosition) async throws {}

    func startReceivingInput(onMouseClick: @escaping @Sendable (MouseClick) -> Void) {}

    func close() {}
}

@Test
func streamHeaderUsesExpectedBinaryLayout() {
    let header = StreamHeader(codec: 1, width: 1920, height: 1080, timescale: 1_000_000)
    let data = PCScreenProtocol.makeStreamHeader(header)

    #expect(data.prefix(7) == Data("PCSCRN1".utf8))
    #expect(data.count == 16)
    #expect(Array(data[8...9]) == [0x07, 0x80])
    #expect(Array(data[10...11]) == [0x04, 0x38])
    #expect(Array(data[12...15]) == [0x00, 0x0F, 0x42, 0x40])
}

@Test
func framePacketIncludesTypeLengthAndTimestamps() {
    let frame = EncodedFrame(
        isKeyFrame: true,
        presentationTimestampMicros: 123,
        decodeTimestampMicros: 120,
        payload: Data([0x00, 0x00, 0x00, 0x01, 0x65])
    )

    let packet = PCScreenProtocol.makeFramePacket(frame)

    #expect(packet[0] == FrameType.key.rawValue)
    #expect(Array(packet[1...4]) == [0x00, 0x00, 0x00, 0x05])
    #expect(Array(packet[5...12]) == [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7B])
    #expect(Array(packet[13...20]) == [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x78])
    #expect(packet.suffix(5) == Data([0x00, 0x00, 0x00, 0x01, 0x65]))
}

@Test
func authResponseUsesExpectedBinaryLayout() {
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
func streamConfigurationShowsCursorByDefault() {
    let config = StreamConfiguration(host: "127.0.0.1")

    #expect(config.showsCursor)
}

@Test
func cursorPacketIncludesTypeLengthTimestampAndCoordinates() {
    let cursor = CursorPosition(x: 0x1234, y: 0xabcd, timestampMicros: 456)
    let packet = PCScreenProtocol.makeCursorPacket(cursor)

    #expect(packet[0] == FrameType.cursor.rawValue)
    #expect(Array(packet[1...4]) == [0x00, 0x00, 0x00, 0x04])
    #expect(Array(packet[5...12]) == [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xc8])
    #expect(Array(packet[13...20]) == [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xc8])
    #expect(Array(packet[21...24]) == [0x12, 0x34, 0xab, 0xcd])
}

@Test
func parsesMouseClickPacketFromReceiver() throws {
    let header = Data([
        FrameType.mouseClick.rawValue,
        0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xc8,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xc8,
    ])
    let payload = Data([0x12, 0x34, 0xab, 0xcd])

    let click = try PCScreenProtocol.parseMouseClickPacket(header: header, payload: payload)

    #expect(click.x == 0x1234)
    #expect(click.y == 0xabcd)
    #expect(click.timestampMicros == 456)
}

@Test
func reconnectingSenderCreatesANewTransportAfterSendFailure() async throws {
    let creationCount = Mutex(0)
    let sender = ReconnectingSender(
        retryDelay: .zero,
        transportFactory: {
            let attempt = creationCount.withLock {
                $0 += 1
                return $0
            }
            return ScriptedTransport(failsOnSend: attempt == 1)
        }
    )
    let frame = EncodedFrame(
        isKeyFrame: true,
        presentationTimestampMicros: 1,
        decodeTimestampMicros: 1,
        payload: Data([0x01])
    )

    try await sender.start(header: StreamHeader(width: 1440, height: 900))
    await sender.sendFrame(frame)

    for _ in 0..<100 where creationCount.withLock({ $0 }) < 2 {
        try await Task.sleep(for: .milliseconds(10))
    }
    await sender.stop()

    #expect(creationCount.withLock { $0 } == 2)
}

@Test
func reconnectingSenderRetriesTheInitialConnection() async throws {
    let creationCount = Mutex(0)
    let sender = ReconnectingSender(
        retryDelay: .zero,
        transportFactory: {
            let attempt = creationCount.withLock {
                $0 += 1
                return $0
            }
            return ScriptedTransport(failsOnConnect: attempt == 1, failsOnSend: false)
        }
    )

    try await sender.start(header: StreamHeader(width: 1440, height: 900))
    await sender.stop()

    #expect(creationCount.withLock { $0 } == 2)
}
