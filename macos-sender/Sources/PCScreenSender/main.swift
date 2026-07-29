import Foundation
import PCScreenKit

struct SenderCLI {
    let config: StreamConfiguration
    let usesTestPattern: Bool
    let durationSeconds: Double

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            if token.hasPrefix("--"), index + 1 < arguments.count {
                values[String(token.dropFirst(2))] = arguments[index + 1]
                index += 2
            } else {
                index += 1
            }
        }

        guard let host = values["host"], !host.isEmpty else {
            throw PCScreenError.invalidArgument("Missing required argument --host <ip-or-hostname>.")
        }

        let width = try Self.parseInt(values["width"], defaultValue: 1920, name: "width")
        let height = try Self.parseInt(values["height"], defaultValue: 1080, name: "height")
        let refreshRate = try Self.parseInt(values["fps"], defaultValue: 60, name: "fps")
        let bitrate = try Self.parseInt(values["bitrate"], defaultValue: 8_000_000, name: "bitrate")
        let portInt = try Self.parseInt(values["port"], defaultValue: 6000, name: "port")
        let hideCursor = try Self.parseBool(values["hide-cursor"], defaultValue: false, name: "hide-cursor")
        self.usesTestPattern = try Self.parseBool(values["test-pattern"], defaultValue: false, name: "test-pattern")
        self.durationSeconds = try Self.parseDouble(values["duration"], defaultValue: 5, name: "duration")
        guard let port = UInt16(exactly: portInt) else {
            throw PCScreenError.invalidArgument("Port must fit in UInt16, got \(portInt).")
        }

        self.config = StreamConfiguration(
            width: width,
            height: height,
            refreshRate: refreshRate,
            bitrate: bitrate,
            host: host,
            port: port,
            displayName: values["display-name"] ?? "PC as Screen",
            password: Self.normalizedPassword(values["password"] ?? ProcessInfo.processInfo.environment["PC_AS_SCREEN_PASSWORD"]),
            showsCursor: !hideCursor
        )
    }

    func run() async throws {
        if usesTestPattern {
            let session = try TestPatternStreamingSession(config: config, durationSeconds: durationSeconds)
            try await session.run()
            print("Test pattern streamed to \(config.host):\(config.port) for \(durationSeconds) seconds.")
            return
        }

        let session = try StreamingSession(config: config)
        try await session.run()
        print("Streaming started to \(config.host):\(config.port). Press Ctrl+C to stop.")
        try await waitForInterrupt()
        await session.stop()
    }

    private static func parseInt(_ value: String?, defaultValue: Int, name: String) throws -> Int {
        guard let value else { return defaultValue }
        guard let parsed = Int(value) else {
            throw PCScreenError.invalidArgument("Argument --\(name) must be an integer, got \(value).")
        }
        return parsed
    }

    private static func parseBool(_ value: String?, defaultValue: Bool, name: String) throws -> Bool {
        guard let value else { return defaultValue }
        switch value.lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            throw PCScreenError.invalidArgument("Argument --\(name) must be true or false, got \(value).")
        }
    }

    private static func parseDouble(_ value: String?, defaultValue: Double, name: String) throws -> Double {
        guard let value else { return defaultValue }
        guard let parsed = Double(value) else {
            throw PCScreenError.invalidArgument("Argument --\(name) must be a number, got \(value).")
        }
        return parsed
    }

    private static func normalizedPassword(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func waitForInterrupt() async throws {
        signal(SIGINT, SIG_IGN)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            source.setEventHandler {
                source.cancel()
                continuation.resume()
            }
            source.resume()
        }
    }
}

@main
struct Main {
    static func main() async {
        do {
            let cli = try SenderCLI(arguments: Array(CommandLine.arguments.dropFirst()))
            try await cli.run()
        } catch {
            fputs("pc-as-screen sender failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
