import Foundation
import AVFoundation
import CoreMedia
import Testing
@testable import IPadReceiverCore

@Test
func parsesAnnexBNALUnitsWithThreeAndFourByteStartCodes() throws {
    let payload = Data([
        0x00, 0x00, 0x01, 0x67, 0x64, 0x00, 0x1F,
        0x00, 0x00, 0x00, 0x01, 0x68, 0xEE, 0x3C,
        0x00, 0x00, 0x01, 0x65, 0x88, 0x84,
    ])
    let converter = H264AnnexBConverter()

    let accessUnit = try converter.parseAccessUnit(payload)

    #expect(accessUnit.nalUnits.map(\.type) == [7, 8, 5])
    #expect(accessUnit.sps == Data([0x67, 0x64, 0x00, 0x1F]))
    #expect(accessUnit.pps == Data([0x68, 0xEE, 0x3C]))
    #expect(accessUnit.containsIDR)
}

@Test
func convertsAnnexBToAVCCLengthPrefixedPayload() throws {
    let payload = Data([
        0x00, 0x00, 0x01, 0x67, 0x64,
        0x00, 0x00, 0x01, 0x68,
        0x00, 0x00, 0x01, 0x65, 0x88,
    ])
    let converter = H264AnnexBConverter()

    let accessUnit = try converter.parseAccessUnit(payload)

    #expect(accessUnit.avccPayload == Data([
        0x00, 0x00, 0x00, 0x02, 0x65, 0x88,
    ]))
}

@Test
func rejectsPayloadWithoutAnnexBStartCode() throws {
    let converter = H264AnnexBConverter()

    #expect(throws: IPadReceiverError.invalidNALUnit) {
        _ = try converter.parseAccessUnit(Data([0x65, 0x88, 0x84]))
    }
}

@Test
func requiresParameterSetsBeforeSampleBufferCreation() throws {
    let factory = H264SampleBufferFactory()
    let packet = FramePacket(
        frameType: .key,
        presentationTimestampMicros: 123,
        decodeTimestampMicros: 120,
        payload: Data([0x00, 0x00, 0x01, 0x65, 0x88, 0x84])
    )

    #expect(throws: IPadReceiverError.missingParameterSets) {
        _ = try factory.makeSampleBuffer(packet: packet, timescale: 1_000_000)
    }
}

@Test
func createsDisplayReadySampleBufferFromParameterSetsAndIDR() throws {
    let factory = H264SampleBufferFactory()
    let packet = FramePacket(
        frameType: .key,
        presentationTimestampMicros: 33_333,
        decodeTimestampMicros: 0,
        payload: validBaselineAccessUnit(idrPayload: Data([0x65, 0x88, 0x84]))
    )

    let sampleBuffer = try #require(try factory.makeSampleBuffer(packet: packet, timescale: 1_000_000))

    #expect(CMSampleBufferGetFormatDescription(sampleBuffer) != nil)
    #expect(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).value == 33_333)
    #expect(!CMSampleBufferGetDecodeTimeStamp(sampleBuffer).isValid)
    #expect(sampleBufferHasDisplayImmediatelyAttachment(sampleBuffer))
}

@Test
func reusesFormatDescriptionForDeltaSampleBuffer() throws {
    let factory = H264SampleBufferFactory()
    let keyPacket = FramePacket(
        frameType: .key,
        presentationTimestampMicros: 0,
        decodeTimestampMicros: 0,
        payload: validBaselineAccessUnit(idrPayload: Data([0x65, 0x88, 0x84]))
    )
    _ = try #require(try factory.makeSampleBuffer(packet: keyPacket, timescale: 1_000_000))
    let deltaPacket = FramePacket(
        frameType: .delta,
        presentationTimestampMicros: 66_666,
        decodeTimestampMicros: 66_666,
        payload: annexB([Data([0x41, 0x9A, 0x20])])
    )

    let sampleBuffer = try #require(try factory.makeSampleBuffer(packet: deltaPacket, timescale: 1_000_000))

    #expect(CMSampleBufferGetFormatDescription(sampleBuffer) != nil)
    #expect(CMSampleBufferGetDecodeTimeStamp(sampleBuffer).value == 66_666)
}

@Test
func displayControllerRequiresNonEmptyAttachedLayerBeforeEnqueue() throws {
    let controller = SampleBufferDisplayController()
    let parentLayer = CALayer()

    #expect(!controller.isReadyForEnqueue)

    parentLayer.addSublayer(controller.displayLayer)
    #expect(!controller.isReadyForEnqueue)

    controller.displayLayer.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
    #expect(controller.isReadyForEnqueue)
}

private func validBaselineAccessUnit(idrPayload: Data) -> Data {
    annexB([
        Data([0x67, 0x42, 0xC0, 0x1F, 0xDA, 0x0A, 0x37, 0xE4, 0xC0, 0x44, 0x00, 0x00, 0x03, 0x00, 0x04, 0x00, 0x00, 0x03, 0x00, 0x12, 0x3C, 0x60, 0xCA, 0x80]),
        Data([0x68, 0xCE, 0x0F, 0xC8]),
        idrPayload,
    ])
}

private func annexB(_ nalUnits: [Data]) -> Data {
    nalUnits.reduce(into: Data()) { data, nalUnit in
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        data.append(nalUnit)
    }
}

private func sampleBufferHasDisplayImmediatelyAttachment(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
          CFArrayGetCount(attachments) > 0,
          let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary?.self) else {
        return false
    }
    return CFDictionaryContainsKey(
        attachment,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque()
    )
}
