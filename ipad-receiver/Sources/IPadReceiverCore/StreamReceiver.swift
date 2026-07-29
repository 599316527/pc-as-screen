import AVFoundation
import Foundation
import Network

public struct ReceiverConfiguration: Equatable, Sendable {
    public var port: UInt16
    public var password: String?

    public init(port: UInt16 = 6000, password: String? = nil) {
        self.port = port
        self.password = password
    }
}

public struct VideoSample: @unchecked Sendable {
    public let sampleBuffer: CMSampleBuffer

    public init(sampleBuffer: CMSampleBuffer) {
        self.sampleBuffer = sampleBuffer
    }
}

public enum ReceiverEvent: Sendable {
    case listening(UInt16)
    case connected(StreamHeader)
    case videoSample(VideoSample)
    case cursor(CursorPacket)
    case disconnected
}

public final class IPadStreamReceiver: @unchecked Sendable {
    private let configuration: ReceiverConfiguration
    private let listener: NWListener
    private let queue = DispatchQueue(label: "pc-as-screen.ipad.receiver")
    private let sampleFactory = H264SampleBufferFactory()
    private var streamHeader: StreamHeader?
    private var activeConnection: NWConnection?

    public init(configuration: ReceiverConfiguration) throws {
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw IPadReceiverError.network("invalid port: \(configuration.port)")
        }
        self.configuration = configuration
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: parameters, on: port)
    }

    public func start(onEvent: @escaping @Sendable (Result<ReceiverEvent, Error>) -> Void) {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                onEvent(.success(.listening(self.configuration.port)))
            case .failed(let error):
                onEvent(.failure(IPadReceiverError.network("TCP listener failed: \(error.localizedDescription)")))
            case .cancelled:
                onEvent(.success(.disconnected))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.activeConnection?.cancel()
            self.activeConnection = connection
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Task {
                        do {
                            try await self.receiveLoop(connection: connection, onEvent: onEvent)
                        } catch {
                            onEvent(.failure(error))
                        }
                    }
                case .failed:
                    self.finish(connection: connection, onEvent: onEvent)
                case .cancelled:
                    self.finish(connection: connection, onEvent: onEvent)
                default:
                    break
                }
            }
            connection.start(queue: self.queue)
        }
        listener.start(queue: queue)
    }

    public func stop() {
        activeConnection?.cancel()
        activeConnection = nil
        listener.cancel()
    }

    public func sendMouseClick(_ click: MouseClick) {
        guard let activeConnection else {
            return
        }
        let data = PCScreenProtocol.makeMouseClickPacket(click)
        activeConnection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func finish(
        connection: NWConnection,
        onEvent: @escaping @Sendable (Result<ReceiverEvent, Error>) -> Void
    ) {
        if activeConnection === connection {
            activeConnection = nil
        }
        onEvent(.success(.disconnected))
    }

    private func receiveLoop(
        connection: NWConnection,
        onEvent: @escaping @Sendable (Result<ReceiverEvent, Error>) -> Void
    ) async throws {
        try await authenticateIfNeeded(connection: connection)
        let header = try PCScreenProtocol.parseStreamHeader(
            try await receiveExactly(PCScreenProtocol.streamHeaderSize, connection: connection)
        )
        streamHeader = header
        onEvent(.success(.connected(header)))

        while true {
            do {
                let frameHeader = try await receiveExactly(PCScreenProtocol.frameHeaderSize, connection: connection)
                let payloadLength = try PCScreenProtocol.payloadLength(fromFrameHeader: frameHeader)
                let payload = try await receiveExactly(payloadLength, connection: connection)
                let packet = try PCScreenProtocol.parseFramePacket(header: frameHeader, payload: payload)
                if packet.isCursor {
                    onEvent(.success(.cursor(try PCScreenProtocol.parseCursorPacket(packet))))
                } else if let sampleBuffer = try sampleFactory.makeSampleBuffer(packet: packet, timescale: header.timescale) {
                    onEvent(.success(.videoSample(VideoSample(sampleBuffer: sampleBuffer))))
                }
            } catch IPadReceiverError.endOfStream {
                finish(connection: connection, onEvent: onEvent)
                return
            }
        }
    }

    private func authenticateIfNeeded(connection: NWConnection) async throws {
        guard let password = configuration.password, !password.isEmpty else {
            return
        }
        let hello = try await receiveExactly(PCScreenProtocol.authHelloMagic.count, connection: connection)
        guard hello == PCScreenProtocol.authHelloMagic else {
            throw IPadReceiverError.invalidAuthChallenge
        }
        let nonce = Data((0..<PCScreenProtocol.authNonceSize).map { _ in UInt8.random(in: 0...255) })
        try await send(PCScreenProtocol.authChallengeMagic + nonce, connection: connection)
        let response = try await receiveExactly(
            PCScreenProtocol.authResponseMagic.count + PCScreenProtocol.authDigestSize,
            connection: connection
        )
        let responseMagic = response.prefix(PCScreenProtocol.authResponseMagic.count)
        let responseDigest = response.suffix(PCScreenProtocol.authDigestSize)
        let expectedDigest = PCScreenProtocol.makeAuthDigest(password: password, nonce: nonce)
        if responseMagic == PCScreenProtocol.authResponseMagic, Data(responseDigest) == expectedDigest {
            try await send(PCScreenProtocol.authAcceptedMagic, connection: connection)
        } else {
            try await send(PCScreenProtocol.authRejectedMagic, connection: connection)
            throw IPadReceiverError.authenticationRejected
        }
    }

    private func receiveExactly(_ size: Int, connection: NWConnection) async throws -> Data {
        var data = Data()
        while data.count < size {
            let chunk = try await receive(
                minimumLength: size - data.count,
                maximumLength: size - data.count,
                connection: connection
            )
            guard !chunk.isEmpty else {
                throw IPadReceiverError.endOfStream(expected: size, actual: data.count)
            }
            data.append(chunk)
        }
        return data
    }

    private func receive(minimumLength: Int, maximumLength: Int, connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: minimumLength, maximumLength: maximumLength) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: IPadReceiverError.network("TCP receive failed: \(error.localizedDescription)"))
                    return
                }
                if let data {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(throwing: IPadReceiverError.network("TCP receive returned no data"))
                }
            }
        }
    }

    private func send(_ data: Data, connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: IPadReceiverError.network("TCP send failed: \(error.localizedDescription)"))
                } else {
                    continuation.resume()
                }
            })
        }
    }
}

public final class SampleBufferDisplayController {
    public let displayLayer = AVSampleBufferDisplayLayer()

    public init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.preventsDisplaySleepDuringVideoPlayback = true
    }

    public var isReadyForEnqueue: Bool {
        displayLayer.superlayer != nil && !displayLayer.bounds.isEmpty
    }

    public func enqueue(_ sampleBuffer: CMSampleBuffer) -> SampleBufferDisplayReport {
        if displayLayer.status == .failed {
            displayLayer.flushAndRemoveImage()
        }
        displayLayer.enqueue(sampleBuffer)
        return report()
    }

    public func reset() {
        displayLayer.flushAndRemoveImage()
    }

    public func report() -> SampleBufferDisplayReport {
        SampleBufferDisplayReport(
            status: Self.describe(status: displayLayer.status),
            errorDescription: displayLayer.error?.localizedDescription,
            isReadyForMoreMediaData: displayLayer.isReadyForMoreMediaData
        )
    }

    private static func describe(status: AVQueuedSampleBufferRenderingStatus) -> String {
        switch status {
        case .unknown:
            return "unknown"
        case .rendering:
            return "rendering"
        case .failed:
            return "failed"
        @unknown default:
            return "unknown(\(status.rawValue))"
        }
    }
}

public struct SampleBufferDisplayReport: Equatable, Sendable {
    public var status: String
    public var errorDescription: String?
    public var isReadyForMoreMediaData: Bool

    public init(status: String, errorDescription: String?, isReadyForMoreMediaData: Bool) {
        self.status = status
        self.errorDescription = errorDescription
        self.isReadyForMoreMediaData = isReadyForMoreMediaData
    }

    public var isFailed: Bool {
        status == "failed"
    }

    public var isRendering: Bool {
        status == "rendering"
    }
}
