import Foundation
import XCTest

@testable import MirriHostCore

final class LatencyTraceTests: XCTestCase {
  private let id = Data((0..<16).map(UInt8.init))

  func testExistingPongRetainsClientReceiveAndReplyStamps() throws {
    let message = WireMessage(
      type: MessageKind.pong.rawValue, sequence: 0, timestamp: 100,
      fields: [.integer(9), .bytes(id), .integer(3), .integer(100), .integer(600), .integer(620)])
    guard
      case .pong(let sequence, let sent, let received, let replied) =
        try ClientEvent.decode(message)
    else { return XCTFail("Pong decoded as another event") }
    XCTAssertEqual([sequence, sent, received, replied], [3, 100, 600, 620])
  }

  func testSparseHostTraceAndClockOrderAreBounded() {
    let trace = HostLatencyTrace(sessionId: id, epoch: 9, generation: 1, startNs: 1_000_000_000)
    trace.activate(atNs: 1_000_000_000)
    for sequence in 0..<72 {
      let callback = UInt64(1_000_000_000 + sequence * 16_666_666)
      let unit = EncodedUnit(
        accessUnit: Data(), parameterSets: nil, keyframe: false,
        pts: UInt64(sequence * 16_666_666), encodeLatencyMs: 3,
        submittedNs: callback + 1_000_000, captureCallbackNs: callback,
        encoderCallbackNs: callback + 3_000_000, convertedNs: callback + 4_000_000)
      trace.prewrite(unit, sequence: UInt64(sequence), atNs: callback + 5_000_000)
      trace.written(sequence: UInt64(sequence), atNs: callback + 6_000_000)
    }
    trace.pong(
      sequence: 0, t1: 1_200_000_000, t2: 1_730_000_000, t3: 1_731_000_000,
      t4: 1_261_000_000)
    trace.pong(sequence: 1, t1: 2, t2: 4, t3: 3, t4: 5)
    let report = trace.report(atNs: 2_250_000_000)
    XCTAssertTrue(report.contains("selected=12 missing=0 dropped=0 rejectedClock=1"))
    XCTAssertTrue(report.contains("frames=0,0,1000000000,"))
    XCTAssertTrue(report.contains("clocks=0,1200000000,1730000000,1731000000,1261000000"))
    XCTAssertLessThan(report.utf8.count, 3_900)
    XCTAssertTrue(trace.report(final: true, atNs: 2_300_000_000).contains("final=1"))
  }

  func testProductionHostLatencyTraceEmitter() throws {
    let start: UInt64 = 1_000_000_000
    let trace = HostLatencyTrace(sessionId: id, epoch: 9, generation: 1, startNs: start)
    trace.activate(atNs: start)
    trace.pong(
      sequence: 0, t1: 1_200_000_000, t2: 1_730_000_000, t3: 1_731_000_000,
      t4: 1_261_000_000)
    var lines: [String] = []
    for sequence in 0..<120 {
      let pts = UInt64(sequence) * 16_666_666
      let callback = start + pts
      if sequence == 60 { lines.append(trace.report(atNs: 2_000_000_000)) }
      let unit = EncodedUnit(
        accessUnit: Data(), parameterSets: nil, keyframe: false, pts: pts,
        encodeLatencyMs: 3, submittedNs: callback + 1_000_000,
        captureCallbackNs: callback, encoderCallbackNs: callback + 3_000_000,
        convertedNs: callback + 4_000_000)
      trace.prewrite(unit, sequence: UInt64(sequence), atNs: callback + 5_000_000)
      trace.written(sequence: UInt64(sequence), atNs: callback + 6_000_000)
    }
    lines.append(trace.report(final: true, atNs: 3_000_000_000))
    XCTAssertTrue(lines.allSatisfy { $0.utf8.count < 3_900 })
    XCTAssertTrue(lines.last?.contains("final=1") == true)
    if let directory = ProcessInfo.processInfo.environment["MIRRI_TIMING_EMITTER_DIR"] {
      let text = lines.map { "2026-09-26T16:00:00Z metrics \($0)\n" }.joined()
      try text.write(
        to: URL(fileURLWithPath: directory).appendingPathComponent("host-latency.log"),
        atomically: true, encoding: .utf8)
    }
  }

  func testWorstCaseNumericBatchAndOverflowAreBounded() {
    let trace = HostLatencyTrace(
      sessionId: id, epoch: .max, generation: .max, route: "network", startNs: 1)
    trace.activate(atNs: 1)
    let largestSequence = UInt64.max - UInt64.max % 6
    for index in 0..<26 {
      let callback = UInt64.max - 6_000_000_000 - UInt64(index)
      let unit = EncodedUnit(
        accessUnit: Data(), parameterSets: nil, keyframe: false, pts: UInt64.max,
        encodeLatencyMs: 0, submittedNs: callback + 1, captureCallbackNs: callback,
        encoderCallbackNs: callback + 2, convertedNs: callback + 3)
      let sequence = largestSequence - UInt64(index * 6)
      trace.prewrite(unit, sequence: sequence, atNs: callback + 4)
      trace.written(sequence: sequence, atNs: callback + 5)
    }
    for sequence in 0..<10 {
      trace.pong(
        sequence: UInt64.max - UInt64(sequence), t1: UInt64.max - 3_000_000_000,
        t2: UInt64.max - 2_000_000_000, t3: UInt64.max - 1_000_000_000,
        t4: UInt64.max - 500_000_000)
    }
    let line = trace.report(atNs: .max)
    XCTAssertTrue(line.contains("selected=26 missing=0 dropped=6"))
    XCTAssertLessThan(line.utf8.count + 50, 3_900)  // Host log prefix margin.
  }
}
