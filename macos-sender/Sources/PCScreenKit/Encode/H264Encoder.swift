import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public final class H264Encoder: @unchecked Sendable {
    public typealias OutputHandler = @Sendable (EncodedFrame) -> Void

    private let width: Int32
    private let height: Int32
    private let bitrate: Int
    private let fps: Int32
    private let outputHandler: OutputHandler
    private var session: VTCompressionSession?

    public init(width: Int, height: Int, bitrate: Int, fps: Int, outputHandler: @escaping OutputHandler) {
        self.width = Int32(width)
        self.height = Int32(height)
        self.bitrate = bitrate
        self.fps = Int32(fps)
        self.outputHandler = outputHandler
    }

    public func start() throws {
        let callback: VTCompressionOutputCallback = { outputCallbackRefCon, _, status, flags, sampleBuffer in
            guard
                status == noErr,
                let outputCallbackRefCon,
                let sampleBuffer
            else { return }

            let encoder = Unmanaged<H264Encoder>.fromOpaque(outputCallbackRefCon).takeUnretainedValue()
            encoder.handleEncodedSampleBuffer(sampleBuffer, flags: flags)
        }

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let session else {
            throw PCScreenError.encoding("Failed to create VTCompressionSession: \(status)")
        }

        self.session = session
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)

        let bitrateNumber = bitrate as CFNumber
        let frameRateNumber = fps as CFNumber
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrateNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: frameRateNumber)
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: 2 as CFNumber
        )

        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    public func encode(sampleBuffer: CMSampleBuffer) throws {
        guard let session else {
            throw PCScreenError.encoding("Encoder session has not been started.")
        }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw PCScreenError.encoding("Sample buffer did not contain a CVImageBuffer.")
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )

        guard status == noErr else {
            throw PCScreenError.encoding("VTCompressionSessionEncodeFrame failed: \(status)")
        }
    }

    public func stop() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    private func handleEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer, flags: VTEncodeInfoFlags) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        let isKeyFrame: Bool = {
            guard
                let array = attachments as? [[CFString: Any]],
                let first = array.first
            else { return false }
            let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            return !notSync
        }()

        var payload = Data()
        if isKeyFrame, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            payload.append(contentsOf: Self.makeParameterSetsAnnexB(formatDescription: format))
        }
        payload.append(contentsOf: Self.makeSampleDataAnnexB(sampleBuffer: sampleBuffer))

        let ptsMicros = Self.microseconds(from: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let dtsMicros = Self.microseconds(from: CMSampleBufferGetDecodeTimeStamp(sampleBuffer))
        outputHandler(
            EncodedFrame(
                isKeyFrame: isKeyFrame,
                presentationTimestampMicros: ptsMicros,
                decodeTimestampMicros: dtsMicros,
                payload: payload
            )
        )
    }

    private static func microseconds(from time: CMTime) -> UInt64 {
        guard time.isValid else { return 0 }
        return UInt64((CMTimeGetSeconds(time) * 1_000_000).rounded())
    }

    private static func makeParameterSetsAnnexB(formatDescription: CMFormatDescription) -> Data {
        var data = Data()
        var parameterSetCount: Int = 0
        var nalLength: Int32 = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalLength
        )
        guard status == noErr else { return data }

        for index in 0..<parameterSetCount {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            if let pointer {
                data.append([0, 0, 0, 1], count: 4)
                data.append(pointer, count: size)
            }
        }
        return data
    }

    private static func makeSampleDataAnnexB(sampleBuffer: CMSampleBuffer) -> Data {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return Data() }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let dataPointer else { return Data() }

        let buffer = UnsafeBufferPointer(start: UnsafePointer<UInt8>(OpaquePointer(dataPointer)), count: totalLength)
        var offset = 0
        var data = Data()
        while offset + 4 <= buffer.count {
            let nalLength = buffer[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            offset += 4
            guard offset + Int(nalLength) <= buffer.count else { break }
            data.append([0, 0, 0, 1], count: 4)
            data.append(buffer.baseAddress!.advanced(by: offset), count: Int(nalLength))
            offset += Int(nalLength)
        }
        return data
    }
}
