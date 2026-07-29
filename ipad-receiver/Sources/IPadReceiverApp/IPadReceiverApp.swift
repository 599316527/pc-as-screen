#if os(iOS)
import AVFoundation
#if !PC_AS_SCREEN_SINGLE_TARGET_APP
import IPadReceiverCore
#endif
import SwiftUI
import UIKit
import Darwin

@main
struct IPadReceiverApp: App {
    var body: some Scene {
        WindowGroup {
            ReceiverView()
        }
    }
}

@MainActor
private final class ReceiverViewModel: ObservableObject {
    @Published var port = "6000"
    @Published var password = ""
    @Published var status = "Disconnected"
    @Published var streamDescription = "No stream"
    @Published var cursorDescription = ""
    @Published var displayDescription = ""
    @Published var localAddresses = LocalNetworkAddressProvider.ipv4Addresses()
    @Published var cursorPosition: CursorPosition?

    let displayController = SampleBufferDisplayController()
    private var receiver: IPadStreamReceiver?
    private var pendingSamples: [VideoSample] = []
    private var streamHeader: StreamHeader?
    private var didSendE2EMouseClick = false

    var isRunning: Bool {
        receiver != nil
    }

    var hasVideo: Bool {
        streamDescription != "No stream"
    }

    func start() {
        guard receiver == nil else {
            return
        }
        localAddresses = LocalNetworkAddressProvider.ipv4Addresses()
        guard let portValue = UInt16(port) else {
            status = "Enter port"
            return
        }
        do {
            let nextReceiver = try IPadStreamReceiver(
                configuration: ReceiverConfiguration(
                    port: portValue,
                    password: password.isEmpty ? nil : password
                )
            )
            receiver = nextReceiver
            status = "Starting"
            nextReceiver.start { [weak self] result in
                DispatchQueue.main.async {
                    self?.handle(result, from: nextReceiver)
                }
            }
        } catch {
            status = String(describing: error)
        }
    }

    func startE2EIfConfigured() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PC_AS_SCREEN_E2E"] == "1" else {
            return
        }
        port = environment["PC_AS_SCREEN_E2E_PORT"] ?? port
        password = environment["PC_AS_SCREEN_E2E_PASSWORD"] ?? ""
        start()
    }

    func stop() {
        let stoppedReceiver = receiver
        receiver = nil
        stoppedReceiver?.stop()
        displayController.reset()
        pendingSamples.removeAll()
        streamHeader = nil
        status = "Disconnected"
        streamDescription = "No stream"
        cursorDescription = ""
        cursorPosition = nil
        displayDescription = ""
    }

    private func resetCurrentStream() {
        displayController.reset()
        pendingSamples.removeAll()
        streamHeader = nil
        didSendE2EMouseClick = false
        streamDescription = "No stream"
        cursorDescription = ""
        cursorPosition = nil
        displayDescription = ""
        if let portValue = UInt16(port), receiver != nil {
            status = "Ready on \(portValue)"
        } else {
            status = "Disconnected"
        }
    }

    private func handle(_ result: Result<ReceiverEvent, Error>, from eventReceiver: IPadStreamReceiver) {
        guard receiver === eventReceiver else {
            return
        }
        switch result {
        case .success(.listening(let port)):
            status = "Ready on \(port)"
            NSLog("PC_AS_SCREEN_E2E_LISTENING port=\(port)")
        case .success(.connected(let header)):
            status = "Connected"
            streamHeader = header
            cursorPosition = CursorPosition(x: UInt16.max / 2, y: UInt16.max / 2)
            streamDescription = "\(header.width)x\(header.height) H.264"
            NSLog("PC_AS_SCREEN_E2E_CONNECTED width=\(header.width) height=\(header.height)")
        case .success(.videoSample(let sample)):
            enqueueOrBuffer(sample)
            NSLog("PC_AS_SCREEN_E2E_VIDEO_SAMPLE")
        case .success(.cursor(let cursor)):
            cursorDescription = "Cursor \(cursor.x), \(cursor.y)"
            cursorPosition = CursorPosition(x: cursor.x, y: cursor.y)
            NSLog("PC_AS_SCREEN_E2E_CURSOR x=\(cursor.x) y=\(cursor.y)")
        case .success(.disconnected):
            resetCurrentStream()
        case .failure(let error):
            status = String(describing: error)
            NSLog("PC_AS_SCREEN_E2E_ERROR \(String(describing: error))")
            let failedReceiver = receiver
            receiver = nil
            failedReceiver?.stop()
        }
    }

    func displayLayerDidLayout() {
        flushPendingSamples()
        sendE2EMouseClickIfNeeded()
    }

    func sendMouseClick(x: UInt16, y: UInt16) {
        guard let receiver else {
            return
        }
        cursorPosition = CursorPosition(x: x, y: y)
        let click = MouseClick(x: x, y: y, timestampMicros: Self.currentTimeMicros())
        receiver.sendMouseClick(click)
        NSLog("PC_AS_SCREEN_E2E_MOUSE_CLICK x=\(x) y=\(y)")
    }

    private func sendE2EMouseClickIfNeeded() {
        guard ProcessInfo.processInfo.environment["PC_AS_SCREEN_E2E"] == "1",
              !didSendE2EMouseClick,
              receiver != nil,
              streamHeader != nil,
              displayController.isReadyForEnqueue else {
            return
        }
        didSendE2EMouseClick = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.receiver != nil, self.streamHeader != nil else {
                return
            }
            self.sendMouseClick(x: UInt16.max / 2, y: UInt16.max / 2)
        }
    }

    var videoPixelSize: CGSize? {
        guard let streamHeader else {
            return nil
        }
        return CGSize(width: Int(streamHeader.width), height: Int(streamHeader.height))
    }

    private func enqueueOrBuffer(_ sample: VideoSample) {
        guard displayController.isReadyForEnqueue else {
            pendingSamples.append(sample)
            NSLog("PC_AS_SCREEN_E2E_DISPLAY_PENDING count=\(pendingSamples.count)")
            return
        }
        enqueue(sample)
        flushPendingSamples()
    }

    private func flushPendingSamples() {
        guard displayController.isReadyForEnqueue, !pendingSamples.isEmpty else {
            return
        }
        let samples = pendingSamples
        pendingSamples.removeAll()
        for sample in samples {
            enqueue(sample)
        }
    }

    private func enqueue(_ sample: VideoSample) {
        let report = displayController.enqueue(sample.sampleBuffer)
        displayDescription = "Display \(report.status)"
        logDisplayReport(report)
        scheduleDisplayStatusCheck()
    }

    private func scheduleDisplayStatusCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.receiver != nil else {
                return
            }
            let report = self.displayController.report()
            self.displayDescription = "Display \(report.status)"
            self.logDisplayReport(report)
        }
    }

    private func logDisplayReport(_ report: SampleBufferDisplayReport) {
        if let error = report.errorDescription {
            NSLog("PC_AS_SCREEN_E2E_DISPLAY_FAILED status=\(report.status) ready=\(report.isReadyForMoreMediaData) error=\(error)")
        } else {
            NSLog("PC_AS_SCREEN_E2E_DISPLAY_STATUS status=\(report.status) ready=\(report.isReadyForMoreMediaData)")
        }
        if report.isRendering {
            NSLog("PC_AS_SCREEN_E2E_VIDEO_DISPLAYED status=\(report.status)")
        }
    }

    private static func currentTimeMicros() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1_000_000)
    }
}

private struct CursorPosition: Equatable {
    var x: UInt16
    var y: UInt16
}

private struct ReceiverView: View {
    @StateObject private var model = ReceiverViewModel()

    var body: some View {
        ZStack {
            if model.hasVideo {
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        DisplayLayerView(
                            displayLayer: model.displayController.displayLayer,
                            videoPixelSize: model.videoPixelSize,
                            cursorPosition: model.cursorPosition,
                            onLayout: {
                                model.displayLayerDidLayout()
                            },
                            onMouseClick: { x, y in
                                model.sendMouseClick(x: x, y: y)
                            }
                        )
                        .background(Color.black)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .background(Color.black)
                    .ignoresSafeArea()
                }
            } else {
                Color(.systemBackground)
                    .ignoresSafeArea()
                setupView
            }

        }
        .onAppear {
            model.startE2EIfConfigured()
        }
    }

    private var setupView: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Text("iPad Receiver")
                    .font(.title)
                    .fontWeight(.semibold)
                Text(model.status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Local IP")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.localAddresses.isEmpty {
                    Text("No Wi-Fi IPv4 address")
                        .font(.title3.monospaced())
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.localAddresses, id: \.self) { address in
                        Text(address)
                            .font(.title3.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: 360, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                Text("Port")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Port", text: $model.port)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
            }
            .frame(maxWidth: 360, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                Text("Password")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("Optional", text: $model.password)
                    .textFieldStyle(.roundedBorder)
            }
            .frame(maxWidth: 360, alignment: .leading)

            Button(model.isRunning ? "Stop" : "Start") {
                model.isRunning ? model.stop() : model.start()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: 360)

            if !model.streamDescription.isEmpty, model.streamDescription != "No stream" {
                Text(model.streamDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

}

private struct DisplayLayerView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer
    let videoPixelSize: CGSize?
    let cursorPosition: CursorPosition?
    let onLayout: () -> Void
    let onMouseClick: (UInt16, UInt16) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = DisplayLayerHostView(
            displayLayer: displayLayer,
            videoPixelSize: videoPixelSize,
            cursorPosition: cursorPosition,
            onLayout: onLayout,
            onMouseClick: onMouseClick
        )
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let hostView = uiView as? DisplayLayerHostView else {
            return
        }
        hostView.update(
            displayLayer: displayLayer,
            videoPixelSize: videoPixelSize,
            cursorPosition: cursorPosition,
            onLayout: onLayout,
            onMouseClick: onMouseClick
        )
        hostView.setNeedsLayout()
        hostView.layoutIfNeeded()
    }
}

private final class DisplayLayerHostView: UIView {
    private var displayLayer: AVSampleBufferDisplayLayer
    private var videoPixelSize: CGSize?
    private var cursorPosition: CursorPosition?
    private var onLayout: () -> Void
    private var onMouseClick: (UInt16, UInt16) -> Void
    private let cursorLayer = CAShapeLayer()

    init(
        displayLayer: AVSampleBufferDisplayLayer,
        videoPixelSize: CGSize?,
        cursorPosition: CursorPosition?,
        onLayout: @escaping () -> Void,
        onMouseClick: @escaping (UInt16, UInt16) -> Void
    ) {
        self.displayLayer = displayLayer
        self.videoPixelSize = videoPixelSize
        self.cursorPosition = cursorPosition
        self.onLayout = onLayout
        self.onMouseClick = onMouseClick
        super.init(frame: .zero)
        layer.addSublayer(displayLayer)
        configureCursorLayer()
        layer.addSublayer(cursorLayer)
        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tapRecognizer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        updateCursorLayer()
        CATransaction.commit()
        if !bounds.isEmpty {
            onLayout()
        }
    }

    func update(
        displayLayer: AVSampleBufferDisplayLayer,
        videoPixelSize: CGSize?,
        cursorPosition: CursorPosition?,
        onLayout: @escaping () -> Void,
        onMouseClick: @escaping (UInt16, UInt16) -> Void
    ) {
        if self.displayLayer !== displayLayer {
            self.displayLayer.removeFromSuperlayer()
            self.displayLayer = displayLayer
            layer.insertSublayer(displayLayer, below: cursorLayer)
        }
        self.videoPixelSize = videoPixelSize
        self.cursorPosition = cursorPosition
        self.onLayout = onLayout
        self.onMouseClick = onMouseClick
        setNeedsLayout()
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let videoPixelSize,
              let point = normalizedVideoPoint(for: recognizer.location(in: self), videoPixelSize: videoPixelSize) else {
            return
        }
        onMouseClick(point.x, point.y)
    }

    private func normalizedVideoPoint(for location: CGPoint, videoPixelSize: CGSize) -> (x: UInt16, y: UInt16)? {
        guard let contentRect = videoContentRect(videoPixelSize: videoPixelSize) else {
            return nil
        }
        guard contentRect.contains(location) else {
            return nil
        }
        let x = normalizedCoordinate(location.x - contentRect.minX, length: contentRect.width)
        let y = normalizedCoordinate(location.y - contentRect.minY, length: contentRect.height)
        return (x, y)
    }

    private func normalizedCoordinate(_ value: CGFloat, length: CGFloat) -> UInt16 {
        let clamped = min(max(value / length, 0), 1)
        return UInt16((clamped * CGFloat(UInt16.max)).rounded())
    }

    private func configureCursorLayer() {
        cursorLayer.fillColor = UIColor.white.cgColor
        cursorLayer.strokeColor = UIColor.black.cgColor
        cursorLayer.lineWidth = 1.25
        cursorLayer.lineJoin = .round
        cursorLayer.shadowColor = UIColor.black.cgColor
        cursorLayer.shadowOpacity = 0.28
        cursorLayer.shadowRadius = 1
        cursorLayer.shadowOffset = CGSize(width: 0, height: 0.5)
        cursorLayer.isHidden = true
    }

    private func updateCursorLayer() {
        guard let cursorPosition,
              let videoPixelSize,
              let contentRect = videoContentRect(videoPixelSize: videoPixelSize) else {
            cursorLayer.isHidden = true
            return
        }
        let origin = CGPoint(
            x: contentRect.minX + CGFloat(cursorPosition.x) / CGFloat(UInt16.max) * contentRect.width,
            y: contentRect.minY + CGFloat(cursorPosition.y) / CGFloat(UInt16.max) * contentRect.height
        )
        cursorLayer.isHidden = false
        cursorLayer.frame = CGRect(origin: origin, size: CGSize(width: 24, height: 32))
        cursorLayer.path = Self.cursorPath(in: CGRect(x: 0, y: 0, width: 20, height: 29)).cgPath
        cursorLayer.zPosition = 1
    }

    private func videoContentRect(videoPixelSize: CGSize) -> CGRect? {
        guard bounds.width > 0, bounds.height > 0, videoPixelSize.width > 0, videoPixelSize.height > 0 else {
            return nil
        }
        let scale = min(bounds.width / videoPixelSize.width, bounds.height / videoPixelSize.height)
        let contentSize = CGSize(width: videoPixelSize.width * scale, height: videoPixelSize.height * scale)
        return CGRect(
            x: (bounds.width - contentSize.width) / 2,
            y: (bounds.height - contentSize.height) / 2,
            width: contentSize.width,
            height: contentSize.height
        )
    }

    private static func cursorPath(in rect: CGRect) -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY * 0.78))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.maxY * 0.57))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.6, y: rect.maxY * 0.94))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.46, y: rect.maxY * 0.53))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY * 0.53))
        path.close()
        return path
    }
}

private enum LocalNetworkAddressProvider {
    static func ipv4Addresses() -> [String] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return []
        }
        defer { freeifaddrs(pointer) }

        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  !String(cString: current.pointee.ifa_name).hasPrefix("lo") else {
                continue
            }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if result == 0 {
                let end = hostname.firstIndex(of: 0) ?? hostname.endIndex
                addresses.append(String(decoding: hostname[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self))
            }
        }

        return Array(Set(addresses)).sorted()
    }
}

#else
@main
struct IPadReceiverCommand {
    static func main() {
        print("IPadReceiverApp is an iOS SwiftUI entry point. Run the package from Xcode on an iPad or iPad Simulator.")
    }
}
#endif
