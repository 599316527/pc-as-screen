import CoreMedia
import Foundation
import VideoToolbox

public enum H264NALUnitType: UInt8, Equatable, Sendable {
    case unspecified = 0
    case slice = 1
    case idrSlice = 5
    case sei = 6
    case sps = 7
    case pps = 8
}

public struct H264NALUnit: Equatable, Sendable {
    public var type: UInt8
    public var payload: Data

    public init(type: UInt8, payload: Data) {
        self.type = type
        self.payload = payload
    }

    public var typedKind: H264NALUnitType? {
        H264NALUnitType(rawValue: type)
    }
}

public struct H264AccessUnit: Equatable, Sendable {
    public var nalUnits: [H264NALUnit]
    public var avccPayload: Data
    public var sps: Data?
    public var pps: Data?

    public init(nalUnits: [H264NALUnit], avccPayload: Data, sps: Data?, pps: Data?) {
        self.nalUnits = nalUnits
        self.avccPayload = avccPayload
        self.sps = sps
        self.pps = pps
    }

    public var containsIDR: Bool {
        nalUnits.contains { $0.type == H264NALUnitType.idrSlice.rawValue }
    }

    public var isDisplayable: Bool {
        nalUnits.contains { unit in
            unit.type == H264NALUnitType.slice.rawValue || unit.type == H264NALUnitType.idrSlice.rawValue
        }
    }
}

public final class H264AnnexBConverter: Sendable {
    public init() {}

    public func parseAccessUnit(_ data: Data) throws -> H264AccessUnit {
        let nalUnits = try parseNALUnits(data)
        let sps = nalUnits.last { $0.type == H264NALUnitType.sps.rawValue }?.payload
        let pps = nalUnits.last { $0.type == H264NALUnitType.pps.rawValue }?.payload
        return H264AccessUnit(
            nalUnits: nalUnits,
            avccPayload: Self.makeAVCCPayload(from: nalUnits.filter { $0.type != H264NALUnitType.sps.rawValue && $0.type != H264NALUnitType.pps.rawValue }),
            sps: sps,
            pps: pps
        )
    }

    public func parseNALUnits(_ data: Data) throws -> [H264NALUnit] {
        let ranges = findNALUnitRanges(in: data)
        guard !ranges.isEmpty else {
            throw IPadReceiverError.invalidNALUnit
        }
        return try ranges.map { range in
            let payload = Data(data[range])
            guard let firstByte = payload.first else {
                throw IPadReceiverError.invalidNALUnit
            }
            return H264NALUnit(type: firstByte & 0x1F, payload: payload)
        }
    }

    public static func makeAVCCPayload(from nalUnits: [H264NALUnit]) -> Data {
        var data = Data()
        for nalUnit in nalUnits {
            data.append(contentsOf: bigEndianBytes(UInt32(nalUnit.payload.count)))
            data.append(nalUnit.payload)
        }
        return data
    }

    private func findNALUnitRanges(in data: Data) -> [Range<Data.Index>] {
        let starts = findStartCodes(in: data)
        guard !starts.isEmpty else {
            return []
        }

        var ranges: [Range<Data.Index>] = []
        for index in starts.indices {
            let payloadStart = starts[index].payloadStart
            let payloadEnd = index + 1 < starts.count ? starts[index + 1].start : data.endIndex
            if payloadStart < payloadEnd {
                ranges.append(payloadStart..<payloadEnd)
            }
        }
        return ranges
    }

    private func findStartCodes(in data: Data) -> [(start: Data.Index, payloadStart: Data.Index)] {
        var starts: [(start: Data.Index, payloadStart: Data.Index)] = []
        var index = data.startIndex
        while index < data.endIndex {
            if let payloadStart = startCodePayloadStart(in: data, at: index) {
                starts.append((start: index, payloadStart: payloadStart))
                index = payloadStart
            } else {
                index = data.index(after: index)
            }
        }
        return starts
    }

    private func startCodePayloadStart(in data: Data, at index: Data.Index) -> Data.Index? {
        let remaining = data.distance(from: index, to: data.endIndex)
        guard remaining >= 3 else {
            return nil
        }
        let second = data.index(after: index)
        let third = data.index(after: second)
        if data[index] == 0, data[second] == 0, data[third] == 1 {
            return data.index(after: third)
        }
        guard remaining >= 4 else {
            return nil
        }
        let fourth = data.index(after: third)
        if data[index] == 0, data[second] == 0, data[third] == 0, data[fourth] == 1 {
            return data.index(after: fourth)
        }
        return nil
    }

    private static func bigEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
    }
}

public final class H264SampleBufferFactory {
    private let converter: H264AnnexBConverter
    private var formatDescription: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?

    public init(converter: H264AnnexBConverter = H264AnnexBConverter()) {
        self.converter = converter
    }

    public func makeSampleBuffer(packet: FramePacket, timescale: UInt32) throws -> CMSampleBuffer? {
        guard packet.frameType != .cursor else {
            return nil
        }
        let accessUnit = try converter.parseAccessUnit(packet.payload)
        if let nextSPS = accessUnit.sps {
            sps = nextSPS
        }
        if let nextPPS = accessUnit.pps {
            pps = nextPPS
        }
        if packet.isKeyFrame || accessUnit.containsIDR || formatDescription == nil {
            try updateFormatDescriptionIfNeeded()
        }
        guard accessUnit.isDisplayable, !accessUnit.avccPayload.isEmpty else {
            return nil
        }
        guard let formatDescription else {
            throw IPadReceiverError.missingParameterSets
        }
        return try makeSampleBuffer(
            avccPayload: accessUnit.avccPayload,
            formatDescription: formatDescription,
            presentationTimestampMicros: packet.presentationTimestampMicros,
            decodeTimestampMicros: packet.decodeTimestampMicros,
            timescale: timescale
        )
    }

    private func updateFormatDescriptionIfNeeded() throws {
        guard let sps, let pps else {
            throw IPadReceiverError.missingParameterSets
        }
        var parameterSetPointers: [UnsafePointer<UInt8>] = []
        var parameterSetSizes = [sps.count, pps.count]
        let status = sps.withUnsafeBytes { spsBuffer in
            pps.withUnsafeBytes { ppsBuffer in
                guard let spsPointer = spsBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let ppsPointer = ppsBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return OSStatus(-50)
                }
                parameterSetPointers = [spsPointer, ppsPointer]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &parameterSetPointers,
                    parameterSetSizes: &parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDescription
                )
            }
        }
        guard status == noErr else {
            throw IPadReceiverError.sampleBufferUnavailable("failed to create H.264 format description: \(status)")
        }
    }

    private func makeSampleBuffer(
        avccPayload: Data,
        formatDescription: CMVideoFormatDescription,
        presentationTimestampMicros: UInt64,
        decodeTimestampMicros: UInt64,
        timescale: UInt32
    ) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        let createBlockStatus = avccPayload.withUnsafeBytes { buffer in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: avccPayload.count,
                blockAllocator: nil,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: avccPayload.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }
        guard createBlockStatus == noErr, let blockBuffer else {
            throw IPadReceiverError.sampleBufferUnavailable("failed to allocate H.264 block buffer: \(createBlockStatus)")
        }
        let replaceStatus = avccPayload.withUnsafeBytes { buffer in
            CMBlockBufferReplaceDataBytes(
                with: buffer.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avccPayload.count
            )
        }
        guard replaceStatus == noErr else {
            throw IPadReceiverError.sampleBufferUnavailable("failed to fill H.264 block buffer: \(replaceStatus)")
        }

        var sampleTiming = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(presentationTimestampMicros), timescale: CMTimeScale(timescale)),
            decodeTimeStamp: Self.decodeTimeStamp(
                presentationTimestampMicros: presentationTimestampMicros,
                decodeTimestampMicros: decodeTimestampMicros,
                timescale: timescale
            )
        )
        var sampleSize = avccPayload.count
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &sampleTiming,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw IPadReceiverError.sampleBufferUnavailable("failed to create H.264 sample buffer: \(sampleStatus)")
        }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0,
           let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary?.self) {
            CFDictionarySetValue(
                attachment,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }

    private static func decodeTimeStamp(
        presentationTimestampMicros: UInt64,
        decodeTimestampMicros: UInt64,
        timescale: UInt32
    ) -> CMTime {
        guard decodeTimestampMicros > 0 || presentationTimestampMicros == 0 else {
            return .invalid
        }
        return CMTime(value: CMTimeValue(decodeTimestampMicros), timescale: CMTimeScale(timescale))
    }
}
