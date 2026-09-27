import Foundation
import XCTest

@testable import MirriHostCore

final class WireTests: XCTestCase {
  private var fixtureDirectory: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("protocol/fixtures")
  }
  private func fixtures() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: fixtureDirectory, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "bin" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }
  private func mutated(_ source: Data, _ index: Int, _ value: UInt8) -> Data {
    var data = source
    data[index] = value
    return data
  }
  func testEveryRegisteredFixtureRoundTripsExactly() throws {
    let files = try fixtures()
    XCTAssertEqual(files.count, 24)
    for (index, file) in files.enumerated() {
      let data = try Data(contentsOf: file)
      let message = try XCTUnwrap(WireCodec.decode(data))
      let expected: UInt16 = index < 22 ? UInt16(index + 1) : (index == 22 ? 2 : 5)
      XCTAssertEqual(message.type, expected, file.lastPathComponent)
      XCTAssertEqual(try WireCodec.encode(message), data, file.lastPathComponent)
      XCTAssertEqual(try WireCodec.payloadLength(header: data.prefix(32)), data.count - 32)
    }
  }
  func testMalformedAndBounded() throws {
    let source = try Data(contentsOf: fixtures()[0])
    XCTAssertThrowsError(try WireCodec.decode(source.prefix(31)))
    XCTAssertThrowsError(try WireCodec.decode(mutated(source, 0, 0)))  // magic
    XCTAssertThrowsError(try WireCodec.decode(mutated(source, 5, 2)))  // major
    XCTAssertThrowsError(try WireCodec.decode(mutated(source, 11, 1)))  // flags
    XCTAssertThrowsError(try WireCodec.payloadLength(header: mutated(source, 0, 0).prefix(32)))
    XCTAssertThrowsError(try WireCodec.decode(mutated(source, 20, 0xff)))  // cap
    XCTAssertThrowsError(try WireCodec.decode(source + Data([0])))  // trailing bytes
    var unknown = mutated(source, 8, 0x80)
    unknown[9] = 0
    XCTAssertThrowsError(try WireCodec.decode(unknown))
    unknown[7] = 1  // future-minor ignorable extension
    XCTAssertNil(try WireCodec.decode(unknown))
    let config = try Data(contentsOf: fixtures()[1])
    // 16 byte session ID + 4 epoch + codec enum at offset 52
    XCTAssertThrowsError(try WireCodec.decode(mutated(config, 52, 9)))
    let scroll = try Data(contentsOf: fixtures()[9])
    // sessionId (16), epoch (4), phase (1), x float begins at offset 53
    var nan = scroll
    nan.replaceSubrange(53..<57, with: [0x7f, 0xc0, 0, 0])
    XCTAssertThrowsError(try WireCodec.decode(nan))
    let rejected = try Data(contentsOf: fixtures()[20])
    // last 9 bytes = synthetic string; corrupt first byte to invalid UTF-8
    XCTAssertThrowsError(try WireCodec.decode(mutated(rejected, rejected.count - 9, 0xff)))
    let hello = try Data(contentsOf: fixtures()[0])
    XCTAssertThrowsError(try WireCodec.decode(mutated(hello, hello.count - 1, 2)))  // invalid bool
    XCTAssertEqual(try WireCodec.decode(hello)?.fields[2], .text("Écran 💠"))
    let fixed = try Data(contentsOf: fixtures()[1])
    // Exact width remains mandatory.
    XCTAssertThrowsError(try WireCodec.decode(mutated(fixed, 32 + 16 + 4 + 1 + 1 + 2, 0xff)))
    // Reject a negotiated mode other than exact 60 Hz, even though the scalar is valid.
    XCTAssertThrowsError(try WireCodec.decode(mutated(fixed, 32 + 16 + 4 + 1 + 1 + 2 + 8 + 3, 59)))
    let ready = try Data(contentsOf: fixtures()[2])
    XCTAssertThrowsError(try WireCodec.decode(mutated(ready, 32 + 16 + 4 + 3, 0)))
    let parameterSets = try Data(contentsOf: fixtures()[4])
    XCTAssertThrowsError(try WireCodec.decode(mutated(parameterSets, 70, 0x67)))  // PPS != SPS
    XCTAssertThrowsError(try WireCodec.payloadLength(header: source.prefix(32), videoChannel: true))
  }
  func testFragmentedAndCoalescedReads() throws {
    let first = try Data(contentsOf: fixtures()[0])
    let second = try Data(contentsOf: fixtures()[1])
    var framer = WireFramer()
    var messages: [FramedRecord] = []
    for byte in first { messages += try framer.append(Data([byte])) }
    XCTAssertFalse(framer.hasIncompleteFrame)
    messages += try framer.append(second + first)
    XCTAssertEqual(messages.count, 3)
    let types = messages.compactMap { record -> UInt16? in
      if case .message(let message) = record { return message.type }
      return nil
    }
    XCTAssertEqual(types, [1, 2, 1])
    XCTAssertFalse(framer.hasIncompleteFrame)
    XCTAssertThrowsError(try framer.append(mutated(first, 20, 0xff)))
  }
  func testDirectionSequenceEpochAndVideoGeneration() throws {
    let files = try fixtures()
    let hello = try XCTUnwrap(WireCodec.decode(Data(contentsOf: files[0])))
    var order = WireOrder(receivingFrom: .client, on: .control, epoch: 1)
    try order.accept(hello)
    XCTAssertThrowsError(try order.accept(hello))  // duplicate sequence
    var unknown = try Data(contentsOf: files[0])
    unknown[7] = 1
    unknown[8] = 0x80
    unknown[9] = 0
    unknown[19] = 1
    var framer = WireFramer()
    let ignored = try framer.append(unknown)
    guard case .skipped(let skipped) = ignored.first else { return XCTFail("expected skip") }
    try order.skipUnknown(sequence: skipped)
    let ready = try XCTUnwrap(WireCodec.decode(Data(contentsOf: files[2])))
    try order.accept(WireMessage(type: 3, sequence: 2, timestamp: 0, fields: ready.fields))
    var wrong = WireOrder(receivingFrom: .host, on: .control, epoch: 1)
    XCTAssertThrowsError(try wrong.accept(hello))  // wrong direction
    var stale = WireOrder(receivingFrom: .client, on: .control, epoch: 2)
    XCTAssertThrowsError(try stale.accept(hello))
    let config = try XCTUnwrap(WireCodec.decode(Data(contentsOf: files[4])))
    let frame = try XCTUnwrap(WireCodec.decode(Data(contentsOf: files[5])))
    var video = WireOrder(receivingFrom: .host, on: .video, epoch: 1)
    XCTAssertThrowsError(try video.accept(frame))  // config must precede frame
    try video.accept(config)
    try video.accept(WireMessage(type: 6, sequence: 1, timestamp: 0, fields: frame.fields))
    // Duplicate frame sequence is rejected even when envelope sequence increases.
    XCTAssertThrowsError(
      try video.accept(WireMessage(type: 6, sequence: 2, timestamp: 0, fields: frame.fields)))
    var nextConfig = config.fields
    nextConfig[2] = .integer(2)
    var nextFrame = frame.fields
    nextFrame[2] = .integer(2)
    var reconnect = WireOrder(receivingFrom: .host, on: .video, epoch: 2, previousGeneration: 1)
    nextConfig[1] = .integer(2)
    nextFrame[1] = .integer(2)
    try reconnect.accept(WireMessage(type: 5, sequence: 0, timestamp: 0, fields: nextConfig))
    try reconnect.accept(WireMessage(type: 6, sequence: 1, timestamp: 0, fields: nextFrame))
  }
}
