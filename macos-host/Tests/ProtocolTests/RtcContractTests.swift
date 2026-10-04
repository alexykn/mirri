import Foundation
import CoreVideo
import VideoToolbox
import XCTest
import LiveKitWebRTC
@testable import MirriHostCore

private actor RtcRecordedConnection: ByteConnection {
  private var writes: [Data] = []
  func receive() async throws -> Data { throw HostFailure.transport }
  func write(_ data: Data) async throws {
    try await Task.sleep(for: .milliseconds(1))
    writes.append(data)
  }
  func close() async {}
  func recorded() -> [Data] { writes }
}

private final class RtcFailureCount: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func fail() { lock.withLock { count += 1 } }
  var value: Int { lock.withLock { count } }
}

final class RtcContractTests: XCTestCase {
  private let session = Data(repeating: 0x11, count: 16)
  private let attempt = Data(repeating: 0x22, count: 16)
  private var mode: WireValue {
    .object([.object([.integer(1600), .integer(2456)]), .integer(60000), .signed(7)])
  }
  private func record(_ type: MessageKind, _ fields: [WireValue]) -> WireMessage {
    RtcSignal.message(type, session: session, epoch: 1, attempt: attempt, fields: fields)
  }
  func testAllRtcRecordsRoundTripWithoutChangingLegacyFixtures() throws {
    let cases: [WireMessage] = [
      WireMessage(type: 23, sequence: 0, timestamp: 0, fields: [
        .bytes(session), .integer(1), .integer(1), .bytes(Data(repeating: 3, count: 16)),
        .integer(1), .integer(2), .integer(52), .integer(1), .integer(1)]),
      record(.rtcPrepare, [.bytes(Data(repeating: 3, count: 16)), .integer(1), .integer(2),
        .integer(52), .object([.integer(2456), .integer(1600)]), .integer(60000), .integer(1)]),
      record(.rtcPrepared, [mode, .object([.integer(2456), .integer(1600)]), .text("OMX.hisi")]),
      record(.rtcOffer, [.text("v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\n")]),
      record(.rtcAnswer, [.text("v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\n")]),
      record(.rtcIceCandidate, [.text("0"), .integer(0), .text("candidate:1 1 udp 1 192.0.2.1 9 typ host")]),
      record(.rtcIceEnd, [.text("0"), .integer(0)]),
      record(.rtcMediaReady, []), record(.rtcStart, []),
    ]
    for (offset, item) in cases.enumerated() {
      let message = WireMessage(type: item.type, sequence: UInt64(offset + 1),
        timestamp: 123, fields: item.fields)
      let encoded = try WireCodec.encode(message)
      XCTAssertEqual(try WireCodec.decode(encoded), message)
      XCTAssertEqual(try WireCodec.payloadLength(header: encoded.prefix(32)), encoded.count - 32)
      XCTAssertThrowsError(try WireCodec.payloadLength(header: encoded.prefix(32), videoChannel: true))
    }
  }
  func testBoundsVersionsStaleAttemptAndSDPAdmission() throws {
    let offer = record(.rtcOffer, [.text("v=0\r\n")])
    let bytes = try WireCodec.encode(offer)
    var oversizedHeader = Data(bytes.prefix(32))
    oversizedHeader.replaceSubrange(20..<24, with: [0, 0, 128, 41])
    XCTAssertThrowsError(try WireCodec.payloadLength(header: oversizedHeader)) {
      XCTAssertEqual($0 as? WireFailure, .tooLarge)
    }
    XCTAssertThrowsError(try WireCodec.decode(bytes.dropLast()))
    XCTAssertThrowsError(try WireCodec.decode(bytes + Data([0])))
    XCTAssertThrowsError(try WireCodec.encode(record(.rtcOffer, [.text(String(repeating: "a", count: 32769))])))
    XCTAssertThrowsError(try WireCodec.encode(record(.rtcOffer, [.text("abc\0")])))
    XCTAssertThrowsError(try WireCodec.encode(record(.rtcIceCandidate, [
      .text("0"), .integer(0), .text("candidate:bad\r\n")])))
    XCTAssertThrowsError(try WireCodec.encode(record(.rtcIceEnd, [.text(""), .integer(0)])))
    XCTAssertThrowsError(try WireCodec.encode(record(.rtcIceEnd, [.text("0"), .integer(1)])))
    XCTAssertThrowsError(try WireCodec.encode(WireMessage(type: 30, sequence: 0, timestamp: 0,
      fields: [.bytes(session), .integer(1), .integer(2), .bytes(attempt)]))) {
      XCTAssertEqual($0 as? WireFailure, .unsupported)
    }
    var badVersion = try WireCodec.encode(record(.rtcStart, []))
    badVersion[32 + 16 + 4 + 1] = 2
    XCTAssertThrowsError(try WireCodec.decode(badVersion)) {
      XCTAssertEqual($0 as? WireFailure, .unsupported)
    }
    XCTAssertThrowsError(try RtcSignal.match(record(.rtcStart, []),
      attempt: Data(repeating: 0x23, count: 16)))
    let valid = "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=mid:0\r\na=sendonly\r\na=rtpmap:96 H264/90000\r\na=fmtp:96 profile-level-id=640034;packetization-mode=1\r\n"
    XCTAssertTrue(RtcSDPProof.videoOnlyHigh(sdp: valid, direction: "sendonly", mid: "0"))
    for bad in ["42e034", "640c34", "6400340", "x640034", "640034junk"] {
      XCTAssertFalse(RtcSDPProof.videoOnlyHigh(sdp: valid.replacingOccurrences(of: "640034", with: bad), direction: "sendonly", mid: "0"))
    }
    XCTAssertFalse(RtcSDPProof.videoOnlyHigh(sdp: valid.replacingOccurrences(of: "packetization-mode=1", with: "packetization-mode=10"), direction: "sendonly", mid: "0"))
    XCTAssertFalse(RtcSDPProof.videoOnlyHigh(sdp: valid.replacingOccurrences(of: "packetization-mode=1", with: "packetization-mode=1;profile-level-id=42e034"), direction: "sendonly", mid: "0"))
    XCTAssertFalse(RtcSDPProof.videoOnlyHigh(sdp: valid + "m=audio 9 RTP/AVP 0\r\n", direction: "sendonly", mid: "0"))
  }
  func testIceStagesBeforeDescriptionAndAdvisoryEndAllowsArbitrarilyLateCandidate() throws {
    var ledger = RtcIceLedger()
    XCTAssertNil(try ledger.candidate(mid: "0", expectedMid: "0", index: 0,
      text: "candidate:staged"))
    XCTAssertEqual(ledger.applyRemoteDescription(), ["candidate:staged"])
    XCTAssertEqual(try ledger.candidate(mid: "0", expectedMid: "0", index: 0,
      text: "candidate:live"), "candidate:live")
    XCTAssertThrowsError(try ledger.candidate(mid: "other", expectedMid: "0", index: 0,
      text: "candidate:wrong-mid"))
    XCTAssertThrowsError(try ledger.end(mid: "0", expectedMid: "0", index: 1))
    try ledger.end(mid: "0", expectedMid: "0", index: 0)
    XCTAssertThrowsError(try ledger.end(mid: "0", expectedMid: "0", index: 0))
    // A synthetic 10-second callback delay exceeds the old 250ms quiet timer.
    // No wall-clock sleep: SDK gathering is advisory, never a candidate cutoff.
    var syntheticMillis: UInt64 = 0
    syntheticMillis += 10_000
    XCTAssertGreaterThan(syntheticMillis, 250)
    XCTAssertEqual(try ledger.candidate(mid: "0", expectedMid: "0", index: 0,
      text: "candidate:after-advisory"), "candidate:after-advisory")
    var many = RtcIceLedger()
    for index in 0..<64 {
      XCTAssertNil(try many.candidate(mid: "0", expectedMid: "0", index: 0,
        text: "candidate:\(index)"))
    }
    XCTAssertThrowsError(try many.candidate(mid: "0", expectedMid: "0", index: 0,
      text: "candidate:65"))
  }
  func testStaleEpochAccountsForSequenceButCannotApplyItsCandidate() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let fixture = root.appendingPathComponent("protocol/fixtures/01-client-hello-v1.bin")
    let original = try XCTUnwrap(WireCodec.decode(Data(contentsOf: fixture)))
    var fields = original.fields
    fields[0] = .integer(2)
    let hello = WireMessage(type: 1, sequence: 0, timestamp: 1, fields: fields)
    var order = WireOrder(receivingFrom: .client, on: .control, epoch: 2)
    try order.accept(try XCTUnwrap(WireCodec.decode(WireCodec.encode(hello))))
    try order.bindSession(session)
    let old = WireMessage(type: 28, sequence: 1, timestamp: 1,
      fields: [.bytes(session), .integer(1), .integer(1), .bytes(attempt),
        .text("0"), .integer(0), .text("candidate:old")])
    try order.skipStaleRtc(try XCTUnwrap(WireCodec.decode(WireCodec.encode(old))))
    let current = WireMessage(type: 28, sequence: 2, timestamp: 1,
      fields: [.bytes(session), .integer(2), .integer(1), .bytes(attempt),
        .text("0"), .integer(0), .text("candidate:new")])
    try order.accept(try XCTUnwrap(WireCodec.decode(WireCodec.encode(current))))
    XCTAssertThrowsError(try order.skipStaleRtc(current))
  }
  func testRtcWriterSerializesConcurrentCandidateWritesAndBoundsOutstandingCandidates() async throws {
    let bytes = RtcRecordedConnection()
    let writer = RtcSignalWriter(channel: WireConnection(bytes))
    let session = self.session
    let attempt = self.attempt
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<16 {
        group.addTask {
          try await writer.send(RtcSignal.message(.rtcIceCandidate, session: session,
            epoch: 1, attempt: attempt,
            fields: [.text("0"), .integer(0), .text("candidate:\(index)")]))
        }
      }
      try await group.waitForAll()
    }
    let result = await bytes.recorded()
    XCTAssertEqual(result.count, 16)
    let messages = try result.compactMap(WireCodec.decode)
    XCTAssertEqual(messages.map(\.sequence), Array(0..<16).map(UInt64.init))
    XCTAssertTrue(messages.allSatisfy { $0.type == 28 })
    for index in 16..<64 {
      try await writer.send(RtcSignal.message(.rtcIceCandidate, session: session,
        epoch: 1, attempt: attempt,
        fields: [.text("0"), .integer(0), .text("candidate:\(index)")]))
    }
    do {
      try await writer.send(RtcSignal.message(.rtcIceCandidate, session: session,
        epoch: 1, attempt: attempt,
        fields: [.text("0"), .integer(0), .text("candidate:overflow")]))
      XCTFail("65th candidate must be rejected")
    } catch { XCTAssertEqual(error as? HostFailure, .malformed) }
  }
  func testRtcFactoryNeverOffersBaselineOrSoftwareEncoder() {
    let factory = RtcHardwareEncoderFactory(onFailure: { _ in })
    let codecs = factory.supportedCodecs()
    XCTAssertEqual(codecs.count, 1)
    XCTAssertEqual(codecs[0].parameters["profile-level-id"], "640034")
    XCTAssertNil(factory.createEncoder(LKRTCVideoCodecInfo(name: "H264",
      parameters: ["profile-level-id": "640c34", "packetization-mode": "1"])))
    XCTAssertEqual(codecs[0].parameters["packetization-mode"], "1")
    XCTAssertNil(factory.createEncoder(LKRTCVideoCodecInfo(name: "H264",
      parameters: ["profile-level-id": "42e034", "packetization-mode": "1"])))
    XCTAssertEqual(factory.createEncoder(codecs[0])?.implementationName(),
      "MirriVideoToolboxHardwareH264")
  }
  func testVtCallbackTokensSurviveInlineDropAndLateCallbackWithoutDoubleRelease() throws {
    var registry = RtcCallbackRegistry<Int>()
    let inline = try XCTUnwrap(registry.begin(11))
    guard case .dropped = registry.callback(inline, status: noErr,
      flags: [.frameDropped], hasSample: false) else { return XCTFail("inline drop") }
    XCTAssertNil(registry.finish(inline)) // synchronous frameDropped must not free twice
    let dropped = try XCTUnwrap(registry.begin(22))
    XCTAssertEqual(registry.finish(dropped), 22) // frameDropped reported on encode return
    let later = try XCTUnwrap(registry.begin(33))
    guard case .ignored = registry.callback(dropped, status: noErr,
      flags: [.frameDropped], hasSample: false) else { return XCTFail("late callback") }
    guard case .dropped = registry.callback(later, status: noErr,
      flags: [], hasSample: false) else { return XCTFail("async nil sample") }
    let failure = try XCTUnwrap(registry.begin(44))
    guard case .failed = registry.callback(failure, status: -1,
      flags: [], hasSample: false) else { return XCTFail("genuine VT failure") }
    XCTAssertEqual(registry.count, 0)
  }
  func testVTAndSDKDeliveryUseTheSameFourCreditsThroughShutdown() throws {
    let owner = RtcTestCreditOwner()
    let tokens = try (0..<4).map { index -> UInt in
      let pointer = try XCTUnwrap(owner.registry.begin(index))
      guard case .ready(let value) = owner.registry.callback(pointer, status: noErr,
        flags: [], hasSample: true) else { throw HostFailure.hardwareCodec }
      XCTAssertEqual(value, index)
      XCTAssertEqual(owner.registry.transferToDelivery(pointer), index)
      return UInt(bitPattern: pointer)
    }
    let delivery = DispatchQueue(label: "rtc.credit.test.delivery")
    let entered = DispatchSemaphore(value: 0)
    let unblock = DispatchSemaphore(value: 0)
    defer { unblock.signal() }
    delivery.async {
      entered.signal()
      unblock.wait()
      owner.lock.withLock {
        for token in tokens { XCTAssertTrue(owner.registry.finishDelivery(token)) }
      }
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(owner.lock.withLock { owner.registry.count }, 4)
    XCTAssertNil(owner.lock.withLock { owner.registry.begin(99) },
      "VT callbacks must not reopen credits held by SDK delivery")
    let drained = DispatchSemaphore(value: 0)
    delivery.async { drained.signal() }
    XCTAssertEqual(drained.wait(timeout: .now()), .timedOut, "shutdown waits behind SDK delivery")
    unblock.signal()
    XCTAssertEqual(drained.wait(timeout: .now() + 2), .success)
    try owner.lock.withLock {
      XCTAssertEqual(owner.registry.count, 0)
      let stillInVT = try XCTUnwrap(owner.registry.begin(100))
      let queuedForSDK = try XCTUnwrap(owner.registry.begin(101))
      XCTAssertEqual(owner.registry.transferToDelivery(queuedForSDK), 101)
      owner.registry.discardAll()
      guard case .ignored = owner.registry.callback(stillInVT, status: noErr,
        flags: [.frameDropped], hasSample: false) else { return XCTFail("late VT callback") }
      XCTAssertFalse(owner.registry.finishDelivery(UInt(bitPattern: queuedForSDK)))
      let next = try XCTUnwrap(owner.registry.begin(102))
      XCTAssertNotEqual(UInt(bitPattern: next), UInt(bitPattern: stillInVT))
      XCTAssertEqual(owner.registry.count, 1)
    }
  }
  func testOptionalNativeRtcHardwarePauseAndResume() throws {
    guard ProcessInfo.processInfo.environment["MIRRI_RTC_HARDWARE_PROBE"] == "1" else {
      throw XCTSkip("Native hardware rate probe is opt-in")
    }
    let count = RtcFailureCount()
    let encoder = RtcHardwareEncoder(onFailure: { _ in count.fail() })
    let settings = LKRTCVideoEncoderSettings()
    settings.width = 2456
    settings.height = 1600
    settings.maxFramerate = 60
    settings.startBitrate = 4000
    settings.maxBitrate = 20_000
    XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 1), 0)
    XCTAssertEqual(encoder.setBitrate(0, framerate: 60), 0)
    XCTAssertEqual(encoder.setBitrate(4000, framerate: 0), 0)
    XCTAssertEqual(encoder.setBitrate(4000, framerate: 60), 0)
    XCTAssertEqual(encoder.release(), 0)
    XCTAssertEqual(count.value, 0)
  }
  func testRtcAttemptCountersNameMeasuredStagesAndHostOnlyAges() {
    let counters = RtcPerformanceCounters()
    counters.received(complete: true, gapNs: 17_000_000)
    counters.forwarded()
    counters.sourceCall(2_000_000)
    counters.started(mode: 1, startKbps: 4000, maxKbps: 2500)
    counters.entered(sourceAgeNs: 3_000_000, pending: 0)
    counters.admitted(pending: 1)
    counters.output(vtAgeNs: 12_000_000, pending: 0)
    counters.delivered(accepted: true, ageNs: 5_000_000)
    counters.released(pending: 0)
    counters.rate(kbps: 231, fps: 61, paused: false)
    let summary = counters.summary()
    for field in ["sourceCallbacks=1", "sourceComplete=1", "forwarded=1",
      "completeGapP95ms=<=24", "sourceCallP95ms=<=2", "encoderEntry=1", "vtAdmit=1",
      "vtOutput=1", "sdkAccept=1", "sourceToEntryP95ms=<=4", "vtP95ms=<=12",
      "callbackToSDKP95ms=<=8", "startKbps=4000", "maxKbps=2500",
      "rateKbps=231", "requestedFPS=61", "frameCredits=0"] {
      XCTAssertTrue(summary.contains(field), "Missing stage: \(field)")
    }
    XCTAssertFalse(summary.contains("one-way"))
  }
  func testEncoderRejectsInvalidGeometryBeforeHardwareSetupAndReportsOnce() {
    XCTAssertTrue(RtcOutboundGeometry.accepts(width: 0, height: 0))
    XCTAssertTrue(RtcOutboundGeometry.accepts(width: 2456, height: 1600))
    XCTAssertFalse(RtcOutboundGeometry.accepts(width: 0, height: 1600))
    XCTAssertFalse(RtcOutboundGeometry.accepts(width: 1280, height: 720))
    XCTAssertEqual(RtcHardwareEncoder.hardwareFramerate(61), 60)
    XCTAssertEqual(RtcHardwareEncoder.hardwareFramerate(59), 59)
    XCTAssertNil(RtcHardwareEncoder.hardwareFramerate(0))
    XCTAssertNil(RtcHardwareEncoder.hardwareFramerate(121))
    let count = RtcFailureCount()
    let encoder = RtcHardwareEncoder(onFailure: { _ in count.fail() })
    let settings = LKRTCVideoEncoderSettings()
    settings.width = 1280
    settings.height = 720
    settings.maxFramerate = 60
    settings.startBitrate = 4000
    XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 1), -1)
    XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 1), -1)
    XCTAssertEqual(count.value, 1)
    XCTAssertEqual(encoder.release(), 0)
  }
  func testOptionalNativeVideoToolboxHigh52SyntheticPixelProbe() throws {
    guard ProcessInfo.processInfo.environment["MIRRI_RTC_HARDWARE_PROBE"] == "1" else {
      throw XCTSkip("Hardware probe is opt-in and creates one synthetic native frame")
    }
    let probe = RtcNativeCodecProbe()
    try probe.run()
  }
  func testPinnedSdkAcceptsTruthfulOrdinaryHighCustomFactoryOffer() async throws {
    let peer = RtcPeer()
    do {
      try peer.prepare(ceiling: 20_000_000, adaptive: true)
      let offer = try await peer.offer()
      XCTAssertTrue(RtcSDPProof.videoOnlyHigh(sdp: offer, direction: "sendonly",
        mid: try XCTUnwrap(peer.videoMid)))
    } catch {
      await peer.stop()
      throw error
    }
    await peer.stop()
  }
}

private final class RtcTestCreditOwner: @unchecked Sendable {
  let lock = NSLock()
  var registry = RtcCallbackRegistry<Int>()
}

private final class RtcNativeCodecProbe {
  private let lock = NSLock()
  private var sps: [UInt8]?
  private var callbackStatus: OSStatus?
  private static let callback: VTCompressionOutputCallback = { context, _, status, _, sample in
    guard let context else { return }
    let probe = Unmanaged<RtcNativeCodecProbe>.fromOpaque(context).takeUnretainedValue()
    probe.lock.withLock {
      probe.callbackStatus = status
      guard let sample, let format = CMSampleBufferGetFormatDescription(sample) else { return }
      var pointer: UnsafePointer<UInt8>?
      var size = 0
      if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
        parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
        let pointer, size >= 4 {
        probe.sps = Array(UnsafeBufferPointer(start: pointer, count: 4))
      }
    }
  }
  func run() throws {
    var session: VTCompressionSession?
    let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true] as CFDictionary
    XCTAssertEqual(VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: 2456,
      height: 1600, codecType: kCMVideoCodecType_H264, encoderSpecification: spec,
      imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: Self.callback,
      refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &session), noErr)
    let encoder = try XCTUnwrap(session)
    defer { VTCompressionSessionInvalidate(encoder) }
    XCTAssertEqual(VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ProfileLevel,
      value: kVTProfileLevel_H264_High_5_2), noErr)
    XCTAssertEqual(VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime,
      value: kCFBooleanTrue), noErr)
    XCTAssertEqual(VTCompressionSessionPrepareToEncodeFrames(encoder), noErr)
    var usingHardware: Unmanaged<CFTypeRef>?
    XCTAssertEqual(VTSessionCopyProperty(encoder,
      key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
      allocator: kCFAllocatorDefault, valueOut: &usingHardware), noErr)
    XCTAssertEqual(usingHardware?.takeRetainedValue() as? Bool, true)
    var pixel: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 2456, 1600,
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pixel), kCVReturnSuccess)
    let buffer = try XCTUnwrap(pixel)
    CVPixelBufferLockBaseAddress(buffer, [])
    for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
      memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane), plane == 0 ? 16 : 128,
        CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let keyframe = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
    XCTAssertEqual(VTCompressionSessionEncodeFrame(encoder, imageBuffer: buffer,
      presentationTimeStamp: CMTime(value: 1, timescale: 60), duration: .invalid,
      frameProperties: keyframe, sourceFrameRefcon: nil, infoFlagsOut: nil), noErr)
    XCTAssertEqual(VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid), noErr)
    let result = lock.withLock { (callbackStatus, sps) }
    XCTAssertEqual(result.0, noErr)
    XCTAssertEqual(result.1?.first.map { $0 & 0x1f }, 7)
    XCTAssertEqual(result.1?.dropFirst().map { $0 }, [0x64, 0x00, 0x34],
      "Hardware SPS must actually emit ordinary High level 5.2")
  }
}
