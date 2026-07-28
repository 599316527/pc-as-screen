import Foundation
import Network

public final class TCPSender: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "pc-as-screen.transport.sender")
    private let password: String?

    public init(host: String, port: UInt16, password: String? = nil) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw PCScreenError.invalidArgument("Invalid port: \(port)")
        }
        connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        self.password = password
    }

    public func connect(header: StreamHeader) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ContinuationGate()
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.authenticateIfNeeded { error in
                        if let error {
                            gate.runOnce {
                                continuation.resume(throwing: error)
                            }
                            return
                        }
                        self.send(data: PCScreenProtocol.makeStreamHeader(header)) { error in
                            gate.runOnce {
                                if let error {
                                    continuation.resume(throwing: PCScreenError.network("Failed to send stream header: \(error.localizedDescription)"))
                                } else {
                                    continuation.resume()
                                }
                            }
                        }
                    }
                case .failed(let error):
                    gate.runOnce {
                        continuation.resume(throwing: PCScreenError.network("TCP connection failed: \(error.localizedDescription)"))
                    }
                default:
                    break
                }
            }
            self.connection.start(queue: self.queue)
        }
    }

    public func sendFrame(_ frame: EncodedFrame, typeOverride: FrameType? = nil) async throws {
        let packet = PCScreenProtocol.makeFramePacket(frame, typeOverride: typeOverride)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(data: packet) { error in
                if let error {
                    continuation.resume(throwing: PCScreenError.network("Failed to send video frame: \(error.localizedDescription)"))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    public func sendCursor(_ cursor: CursorPosition) async throws {
        let packet = PCScreenProtocol.makeCursorPacket(cursor)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(data: packet) { error in
                if let error {
                    continuation.resume(throwing: PCScreenError.network("Failed to send cursor position: \(error.localizedDescription)"))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    public func close() {
        connection.cancel()
    }

    private func authenticateIfNeeded(completion: @escaping @Sendable (Error?) -> Void) {
        guard let password else {
            completion(nil)
            return
        }
        send(data: PCScreenProtocol.authHelloMagic) { [weak self] error in
            guard let self else { return }
            if let error {
                completion(PCScreenError.network("Failed to send auth hello: \(error.localizedDescription)"))
                return
            }
            self.receiveExactly(PCScreenProtocol.authChallengeMagic.count + PCScreenProtocol.authNonceSize) { challengeResult in
                switch challengeResult {
                case .failure(let error):
                    completion(error)
                case .success(let challenge):
                    guard challenge.prefix(PCScreenProtocol.authChallengeMagic.count) == PCScreenProtocol.authChallengeMagic else {
                        completion(PCScreenError.network("Receiver sent an invalid auth challenge."))
                        return
                    }
                    let nonceStart = PCScreenProtocol.authChallengeMagic.count
                    let nonce = challenge[nonceStart...]
                    self.send(data: PCScreenProtocol.makeAuthResponse(password: password, nonce: nonce)) { error in
                        if let error {
                            completion(PCScreenError.network("Failed to send auth response: \(error.localizedDescription)"))
                            return
                        }
                        self.receiveExactly(PCScreenProtocol.authAcceptedMagic.count) { statusResult in
                            switch statusResult {
                            case .failure(let error):
                                completion(error)
                            case .success(let status):
                                if status == PCScreenProtocol.authAcceptedMagic {
                                    completion(nil)
                                } else if status == PCScreenProtocol.authRejectedMagic {
                                    completion(PCScreenError.network("Receiver rejected the password."))
                                } else {
                                    completion(PCScreenError.network("Receiver sent an invalid auth status."))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func receiveExactly(_ size: Int, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        receive(accumulated: Data(), remaining: size, completion: completion)
    }

    private func receive(
        accumulated: Data,
        remaining: Int,
        completion: @escaping @Sendable (Result<Data, Error>) -> Void
    ) {
        connection.receive(minimumIncompleteLength: remaining, maximumLength: remaining) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                completion(.failure(PCScreenError.network("TCP receive failed: \(error.localizedDescription)")))
                return
            }
            var next = accumulated
            if let data {
                next.append(data)
            }
            let nextRemaining = remaining - (data?.count ?? 0)
            if nextRemaining == 0 {
                completion(.success(next))
            } else if isComplete {
                completion(.failure(PCScreenError.network("TCP connection closed during authentication.")))
            } else {
                self.receive(accumulated: next, remaining: nextRemaining, completion: completion)
            }
        }
    }

    private func send(data: Data, completion: @escaping @Sendable (NWError?) -> Void) {
        connection.send(content: data, completion: .contentProcessed(completion))
    }
}
