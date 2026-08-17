import Foundation

actor ReconnectingSender {
    typealias TransportFactory = @Sendable () throws -> any StreamTransport

    private let retryDelay: Duration
    private let transportFactory: TransportFactory
    private var header: StreamHeader?
    private var mouseClickHandler: (@Sendable (MouseClick) -> Void)?
    private var transport: (any StreamTransport)?
    private var reconnectTask: Task<Void, Never>?

    init(retryDelay: Duration = .seconds(2), transportFactory: @escaping TransportFactory) {
        self.retryDelay = retryDelay
        self.transportFactory = transportFactory
    }

    func start(header: StreamHeader) async throws {
        self.header = header
        while !Task.isCancelled {
            var nextTransport: (any StreamTransport)?
            do {
                let transport = try transportFactory()
                nextTransport = transport
                try await transport.connect(header: header)
                if let mouseClickHandler {
                    transport.startReceivingInput(onMouseClick: mouseClickHandler)
                }
                self.transport = transport
                return
            } catch {
                nextTransport?.close()
                if Task.isCancelled {
                    throw CancellationError()
                }
                print("Initial connection failed. Retrying in \(retryDelay)...")
                try await Task.sleep(for: retryDelay)
            }
        }
        throw CancellationError()
    }

    func sendFrame(_ frame: EncodedFrame) async {
        guard let transport else { return }
        do {
            try await transport.sendFrame(frame, typeOverride: nil)
        } catch {
            beginReconnect(afterFailureFrom: transport)
        }
    }

    func sendCursor(_ cursor: CursorPosition) async {
        guard let transport else { return }
        do {
            try await transport.sendCursor(cursor)
        } catch {
            beginReconnect(afterFailureFrom: transport)
        }
    }

    func startReceivingInput(onMouseClick: @escaping @Sendable (MouseClick) -> Void) {
        mouseClickHandler = onMouseClick
        transport?.startReceivingInput(onMouseClick: onMouseClick)
    }

    func stop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        transport?.close()
        transport = nil
        header = nil
        mouseClickHandler = nil
    }

    private func beginReconnect(afterFailureFrom failedTransport: any StreamTransport) {
        guard transport === failedTransport, let header else { return }
        failedTransport.close()
        transport = nil
        guard reconnectTask == nil else { return }
        print("Stream connection lost. Reconnecting automatically...")
        reconnectTask = Task {
            await reconnect(header: header)
        }
    }

    private func reconnect(header: StreamHeader) async {
        while !Task.isCancelled {
            var nextTransport: (any StreamTransport)?
            do {
                try await Task.sleep(for: retryDelay)
                let transport = try transportFactory()
                nextTransport = transport
                try await transport.connect(header: header)
                if let mouseClickHandler {
                    transport.startReceivingInput(onMouseClick: mouseClickHandler)
                }
                guard !Task.isCancelled else {
                    transport.close()
                    break
                }
                self.transport = transport
                reconnectTask = nil
                print("Stream connection restored.")
                return
            } catch {
                nextTransport?.close()
                if Task.isCancelled {
                    break
                }
                print("Reconnect failed. Retrying in \(retryDelay)...")
            }
        }
        reconnectTask = nil
    }
}
