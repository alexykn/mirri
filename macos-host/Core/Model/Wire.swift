import Foundation

/// Platform-independent, strict Mirri 1.0 wire representation. No socket or codec dependency.
public indirect enum WireValue: Equatable, Sendable {
  case integer(UInt64)
  case signed(Int32)
  case real(Float)
  case bytes(Data)
  case text(String)
  case items([WireValue])
  case object([WireValue])
}

public struct WireMessage: Equatable, Sendable {
  public let type: UInt16
  public let sequence: UInt64
  public let timestamp: UInt64
  public let fields: [WireValue]
  public init(type: UInt16, sequence: UInt64, timestamp: UInt64, fields: [WireValue]) {
    self.type = type
    self.sequence = sequence
    self.timestamp = timestamp
    self.fields = fields
  }
}

public enum WireFailure: Error, Sendable { case malformed, unsupported, tooLarge, incomplete }

public enum WireCodec {
  // Ordered wire schema; public domain message fields are WireValue trees.
  private static let common = "bytes16 epoch "
  private static let definitions: [UInt16: String] = [
    1: "epoch bytes32 str64 size u32 mode list16mode list2cap inputs",
    2: "codec profile level size u32 u32 color port inputMode bool",
    3: "mode str96 size", 4: "epoch bytes16 bytes32",
    5: "generation codec profile level color list3param",
    6: "generation u64 u64 frameFlags au",
    7: "generation", 8: "stopReason", 9: "u64 list64sample",
    10: "gesturePhase point delta delta u64",
    11: "gesturePhase point scale u64", 12: "point contextSource u64",
    13: "shortcut u64", 14: "u32 u32 keyPhase u64",
    15: "u64 u64 u64 u64", 16: "u64 u64 u64 u64",
    17: "fps u32 fps fps mode u8 u64", 18: "errorCode str128 bool",
    19: "errorCode", 20: "generation", 21: "rejectReason str128", 22: "",
  ]
  private static func schema(_ type: UInt16) throws -> [String] {
    guard let spec = definitions[type] else { throw WireFailure.unsupported }
    return ((type == 1 || type == 4 ? "" : common) + spec).split(separator: " ").map(
      String.init)
  }
  private static func cap(_ type: UInt16) -> Int {
    type == 6 ? 16_777_261 : (type == 4 || type == 5 ? 65_536 : 1_048_576)
  }
  private static func checked(_ value: UInt64, _ range: ClosedRange<UInt64>) throws {
    guard range.contains(value) else { throw WireFailure.malformed }
  }
  private static func integer(_ value: WireValue) throws -> UInt64 {
    guard case .integer(let n) = value else { throw WireFailure.malformed }
    return n
  }
  private static func object(_ value: WireValue) throws -> [WireValue] {
    guard case .object(let fields) = value else { throw WireFailure.malformed }
    return fields
  }
  private static func size(_ value: WireValue) throws -> (UInt64, UInt64) {
    let fields = try object(value)
    guard fields.count == 2 else { throw WireFailure.malformed }
    return (try integer(fields[0]), try integer(fields[1]))
  }
  private static func exactPhysicalMode(_ value: WireValue) throws -> Bool {
    let fields = try object(value)
    return try fields.count == 3 && size(fields[0]) == (1600, 2456)
      && integer(fields[1]) == 60000
  }
  private static func validate(_ message: WireMessage) throws {
    let f = message.fields
    switch message.type {
    case 1:
      guard try size(f[3]) == (1600, 2456) else { throw WireFailure.malformed }
      try checked(integer(f[4]), 1...1200)
    case 2:
      let codec = try integer(f[2])
      let profile = try integer(f[3])
      let pixelSize = try size(f[5])
      let bitrate = try integer(f[7])
      guard codec == profile, pixelSize == (2456, 1600), try integer(f[6]) == 60000,
        (codec == 1 ? 20_000_000...80_000_000 : 25_000_000...80_000_000).contains(bitrate)
      else { throw WireFailure.malformed }
    case 3:
      guard try size(f[4]) == (2456, 1600), try exactPhysicalMode(f[2]) else {
        throw WireFailure.malformed
      }
    case 5:
      let codec = try integer(f[3])
      let profile = try integer(f[4])
      guard case .items(let sets) = f[7], codec == profile,
        sets.count == (codec == 1 ? 2 : 3)
      else { throw WireFailure.malformed }
      for (index, set) in sets.enumerated() {
        guard case .bytes(let nal) = set, nal.count >= (codec == 1 ? 1 : 2) else {
          throw WireFailure.malformed
        }
        let actual = codec == 1 ? Int(nal[0] & 0x1f) : Int((nal[0] >> 1) & 0x3f)
        let expected = codec == 1 ? [7, 8][index] : [32, 33, 34][index]
        guard actual == expected else { throw WireFailure.malformed }
      }
    case 6:
      guard case .bytes(let au) = f[6], au.count >= 5,
        au.starts(with: [0, 0, 0, 1])
      else { throw WireFailure.malformed }
    default: break
    }
  }
  private static func range(_ type: String) -> ClosedRange<UInt64>? {
    switch type {
    case "bool": return 0...1
    case "codec": return 1...2
    case "profile": return 1...2
    case "color", "inputMode": return 1...1
    case "gesturePhase": return 1...4
    case "contextSource": return 1...3
    case "shortcut": return 1...5
    case "keyPhase": return 1...2
    case "stopReason": return 1...4
    case "errorCode": return 1...8
    case "rejectReason": return 1...5
    case "tool": return 1...3
    case "pointerPhase": return 1...7
    case "frameFlags": return 0...3
    case "buttons": return 0...7
    case "generation", "epoch": return 1...UInt64(UInt32.max)
    case "port": return 5560...5560
    default: return nil
    }
  }
  private static func width(_ t: String) -> Int {
    if t == "u64" { return 8 }
    if t == "u32" || t == "epoch" || t == "generation" || t == "dimension" || t == "refresh" {
      return 4
    }
    if t == "level" || t == "port" || t == "buttons" { return 2 }
    return 1
  }
  private static func children(_ t: String) -> [String]? {
    switch t {
    case "size": return ["dimension", "dimension"]
    case "mode": return ["size", "refresh", "i32"]
    case "profileLevel": return ["profile", "level"]
    case "cap": return ["codec", "list16profileLevel", "bool", "bool", "bool"]
    case "inputs": return ["touchCount", "bool", "bool", "bool", "bool", "bool"]
    case "point": return ["unit", "unit"]
    case "sample":
      return [
        "u32", "tool", "pointerPhase", "point", "unit", "tilt", "orientation", "buttons", "u64",
      ]
    default: return nil
    }
  }
  private static func list(_ t: String) -> (Int, String)? {
    for (prefix, count) in [("list16", 16), ("list2", 2), ("list3", 3), ("list64", 64)]
    where t.hasPrefix(prefix) {
      return (count, String(t.dropFirst(prefix.count)))
    }
    return nil
  }
  private static func finite(_ value: Float, _ type: String) throws {
    guard value.isFinite else { throw WireFailure.malformed }
    let bound: ClosedRange<Float>
    switch type {
    case "unit": bound = 0...1
    case "tilt": bound = (-Float.pi / 2)...(Float.pi / 2)
    case "orientation": bound = (-Float.pi)...Float.pi
    case "delta": bound = -4096...4096
    case "scale": bound = 0.25...4
    default: bound = 0...240
    }
    guard bound.contains(value) else { throw WireFailure.malformed }
  }
  private static func stringLimit(_ type: String) -> Int? {
    switch type {
    case "str64": 64
    case "str96": 96
    case "str128": 128
    default: nil
    }
  }
  private static func validText(_ value: String, _ limit: Int) throws -> Data {
    let data = Data(value.utf8)
    guard
      data.count <= limit
        && !value.unicodeScalars.contains(where: {
          CharacterSet.controlCharacters.contains($0) || $0 == "\u{FEFF}"
        })
    else { throw WireFailure.malformed }
    return data
  }
  private static func append(_ n: UInt64, width: Int, to data: inout Data) {
    for index in (0..<width).reversed() { data.append(UInt8(truncatingIfNeeded: n >> (index * 8))) }
  }
  private static func encodeScalar(_ value: WireValue, _ type: String, _ out: inout Data) throws {
    if type == "i32" {
      guard case .signed(let n) = value else { throw WireFailure.malformed }
      append(UInt64(UInt32(bitPattern: n)), width: 4, to: &out)
      return
    }
    if ["unit", "tilt", "orientation", "delta", "scale", "fps"].contains(type) {
      guard case .real(let n) = value else { throw WireFailure.malformed }
      try finite(n, type)
      append(UInt64(n.bitPattern), width: 4, to: &out)
      return
    }
    guard case .integer(let n) = value else { throw WireFailure.malformed }
    let w = width(type)
    guard n <= (w == 8 ? UInt64.max : (UInt64(1) << (w * 8)) - 1) else {
      throw WireFailure.malformed
    }
    if let bounds = range(type) { try checked(n, bounds) }
    if type == "dimension" { try checked(n, 1...8192) }
    if type == "refresh" { try checked(n, 1...240_000) }
    if type == "touchCount" { try checked(n, 1...10) }
    append(n, width: w, to: &out)
  }
  private static func encodeTextOrBytes(_ value: WireValue, _ type: String, _ out: inout Data)
    throws
  {
    if let max = stringLimit(type) {
      guard case .text(let s) = value else { throw WireFailure.malformed }
      let d = try validText(s, max)
      append(UInt64(d.count), width: 2, to: &out)
      out.append(d)
      return
    }
    guard case .bytes(let d) = value else { throw WireFailure.malformed }
    let max = type == "param" ? 4096 : 16_777_216
    guard
      type == "bytes16"
        ? d.count == 16 : type == "bytes32" ? d.count == 32 : (1...max).contains(d.count)
    else { throw WireFailure.malformed }
    if type == "param" { append(UInt64(d.count), width: 2, to: &out) }
    if type == "au" { append(UInt64(d.count), width: 4, to: &out) }
    out.append(d)
  }
  private static func encode(_ value: WireValue, _ type: String, _ out: inout Data) throws {
    if let children = children(type) {
      guard case .object(let fields) = value, fields.count == children.count else {
        throw WireFailure.malformed
      }
      for (field, child) in zip(fields, children) { try encode(field, child, &out) }
      return
    }
    if let (max, child) = list(type) {
      guard case .items(let items) = value, items.count <= max else { throw WireFailure.malformed }
      append(UInt64(items.count), width: 1, to: &out)
      for item in items { try encode(item, child, &out) }
      return
    }
    // Composite schemas, textual/blob payloads and fixed-width scalars have distinct bounds.
    if type == "bytes16" || type == "bytes32" || type == "param" || type == "au" {
      try encodeTextOrBytes(value, type, &out)
    } else if stringLimit(type) != nil {
      try encodeTextOrBytes(value, type, &out)
    } else {
      try encodeScalar(value, type, &out)
    }
  }
  private struct Reader {
    let data: Data
    var offset = 0
    mutating func take(_ count: Int) throws -> Data {
      guard count >= 0, count <= data.count - offset else { throw WireFailure.incomplete }
      let part = data.subdata(in: offset..<(offset + count))
      offset += count
      return part
    }
    mutating func number(_ width: Int) throws -> UInt64 {
      var result: UInt64 = 0
      for byte in try take(width) { result = (result << 8) | UInt64(byte) }
      return result
    }
    mutating func decodeTextOrBytes(_ type: String) throws -> WireValue {
      if let max = WireCodec.stringLimit(type) {
        let length = Int(try number(2))
        guard length <= max else { throw WireFailure.malformed }
        guard let s = String(data: try take(length), encoding: .utf8) else {
          throw WireFailure.malformed
        }
        _ = try WireCodec.validText(s, max)
        return .text(s)
      }
      if type == "bytes16" || type == "bytes32" {
        return .bytes(try take(type == "bytes16" ? 16 : 32))
      }
      let length = Int(try number(type == "param" ? 2 : 4))
      guard (1...(type == "param" ? 4096 : 16_777_216)).contains(length) else {
        throw WireFailure.malformed
      }
      return .bytes(try take(length))
    }
    mutating func decode(_ type: String) throws -> WireValue {
      if let fields = WireCodec.children(type) { return .object(try fields.map { try decode($0) }) }
      if let (max, child) = WireCodec.list(type) {
        let count = Int(try number(1))
        guard count <= max else { throw WireFailure.malformed }
        return .items(try (0..<count).map { _ in try decode(child) })
      }
      if type == "i32" { return .signed(Int32(bitPattern: UInt32(try number(4)))) }
      if ["unit", "tilt", "orientation", "delta", "scale", "fps"].contains(type) {
        let n = Float(bitPattern: UInt32(try number(4)))
        try WireCodec.finite(n, type)
        return .real(n)
      }
      if WireCodec.stringLimit(type) != nil || ["bytes16", "bytes32", "param", "au"].contains(type)
      {
        return try decodeTextOrBytes(type)
      }
      let n = try number(WireCodec.width(type))
      if let bounds = WireCodec.range(type) { try WireCodec.checked(n, bounds) }
      if type == "dimension" { try WireCodec.checked(n, 1...8192) }
      if type == "refresh" { try WireCodec.checked(n, 1...240_000) }
      if type == "touchCount" { try WireCodec.checked(n, 1...10) }
      return .integer(n)
    }
  }
  public static func encode(_ message: WireMessage) throws -> Data {
    let spec = try schema(message.type)
    guard spec.count == message.fields.count else { throw WireFailure.malformed }
    try validate(message)
    var payload = Data()
    for (field, type) in zip(message.fields, spec) { try encode(field, type, &payload) }
    guard payload.count <= cap(message.type) else { throw WireFailure.tooLarge }
    var result = Data("MRRI".utf8)
    append(1, width: 2, to: &result)
    append(0, width: 2, to: &result)
    append(UInt64(message.type), width: 2, to: &result)
    append(0, width: 2, to: &result)
    append(message.sequence, width: 8, to: &result)
    append(UInt64(payload.count), width: 4, to: &result)
    append(message.timestamp, width: 8, to: &result)
    result.append(payload)
    return result
  }
  /// Decode exactly one complete frame. The caller owns ordered sequence/channel checks.
  public static func decode(_ data: Data) throws -> WireMessage? {
    guard data.count >= 32 else { throw WireFailure.incomplete }
    var r = Reader(data: data)
    guard try r.take(4) == Data("MRRI".utf8) else { throw WireFailure.malformed }
    guard try r.number(2) == 1 else { throw WireFailure.unsupported }
    let minor = try r.number(2)
    let type = UInt16(try r.number(2))
    guard try r.number(2) == 0 else { throw WireFailure.malformed }
    let seq = try r.number(8)
    let length = try r.number(4)
    let timestamp = try r.number(8)
    guard length <= UInt64(cap(type)) else { throw WireFailure.tooLarge }
    guard data.count - 32 == Int(length) else { throw WireFailure.malformed }
    guard definitions[type] != nil else {
      if minor > 0 && type & 0x8000 != 0 { return nil }
      throw WireFailure.unsupported
    }
    let spec = try schema(type)
    let fields = try spec.map { try r.decode($0) }
    guard r.offset == data.count else { throw WireFailure.malformed }
    let message = WireMessage(type: type, sequence: seq, timestamp: timestamp, fields: fields)
    try validate(message)
    return message
  }
  /// Validates fragment lengths before a caller allocates a message payload.
  public static func payloadLength(header: Data, videoChannel: Bool = false) throws -> Int {
    guard header.count == 32 else { throw WireFailure.incomplete }
    guard header.prefix(4) == Data("MRRI".utf8) else { throw WireFailure.malformed }
    let major = UInt16(header[4]) << 8 | UInt16(header[5])
    guard major == 1 else { throw WireFailure.unsupported }
    let minor = UInt16(header[6]) << 8 | UInt16(header[7])
    let type = UInt16(header[8]) << 8 | UInt16(header[9])
    guard header[10] == 0 && header[11] == 0 else { throw WireFailure.malformed }
    guard definitions[type] != nil || (minor > 0 && type & 0x8000 != 0) else {
      throw WireFailure.unsupported
    }
    if videoChannel {
      guard type == 4 || type == 5 || type == 6 || (minor > 0 && type & 0x8000 != 0) else {
        throw WireFailure.malformed
      }
    }
    let size = header[20..<24].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    let bound = videoChannel && definitions[type] == nil ? 65_536 : cap(type)
    guard size <= UInt64(bound) else { throw WireFailure.tooLarge }
    return Int(size)
  }
}
