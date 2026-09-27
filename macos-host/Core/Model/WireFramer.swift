import Foundation

public enum FramedRecord: Sendable {
  case message(WireMessage)
  case skipped(sequence: UInt64)
}

/// Incremental bounded framing; transport owners feed slices and decode completed frames.
public struct WireFramer {
  private var pending = Data()
  private var expected: Int?
  private let videoChannel: Bool
  public init(videoChannel: Bool = false) { self.videoChannel = videoChannel }
  public mutating func append(_ chunk: Data) throws -> [FramedRecord] {
    var result: [FramedRecord] = []
    var offset = 0
    while offset < chunk.count {
      let needed = expected ?? 32
      let count = min(needed - pending.count, chunk.count - offset)
      let start = chunk.index(chunk.startIndex, offsetBy: offset)
      pending.append(chunk[start..<chunk.index(start, offsetBy: count)])
      offset += count
      if pending.count == 32 && expected == nil {
        expected = 32 + (try WireCodec.payloadLength(header: pending, videoChannel: videoChannel))
      }
      if let expected, pending.count == expected {
        if let message = try WireCodec.decode(pending) {
          result.append(.message(message))
        } else {
          let sequence = pending[12..<20].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
          result.append(.skipped(sequence: sequence))
        }
        pending.removeAll(keepingCapacity: true)
        self.expected = nil
      }
    }
    return result
  }
  public var hasIncompleteFrame: Bool { !pending.isEmpty }
}
