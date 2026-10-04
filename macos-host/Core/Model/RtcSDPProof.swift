import Foundation

/// Read-only offer/answer admission checks; WebRTC remains the SDP parser and
/// negotiator. Never rewrite SDP or infer a codec from a merely listed format.
enum RtcSDPProof {
  /// Only the exact parameters on the negotiated H264 payload count as proof;
  /// substring matches also admit a different profile or packetization mode.
  static func highParameters(_ fmtp: String) -> Bool {
    var values: [String: String] = [:]
    for part in fmtp.split(separator: ";", omittingEmptySubsequences: false) {
      let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard pair.count == 2 else { continue }
      let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
      let value = pair[1].trimmingCharacters(in: .whitespaces).lowercased()
      guard !key.isEmpty, values.updateValue(value, forKey: key) == nil else { return false }
    }
    return values["profile-level-id"] == "640034" && values["packetization-mode"] == "1"
  }
  static func videoOnlyHigh(sdp: String, direction: String, mid: String) -> Bool {
    let lines = sdp.split(whereSeparator: \.isNewline).map(String.init)
    let media = lines.filter { $0.hasPrefix("m=") }
    guard media.count == 1, media[0].hasPrefix("m=video "),
      lines.contains("a=mid:\(mid)"), lines.contains("a=\(direction)") else { return false }
    let payloads = media[0].split(separator: " ").dropFirst(3)
    let types = Set(payloads.map(String.init))
    for line in lines where line.hasPrefix("a=rtpmap:") {
      let parts = line.dropFirst("a=rtpmap:".count).split(separator: " ")
      guard parts.count == 2, types.contains(String(parts[0])),
        parts[1].lowercased() == "h264/90000" else { continue }
      let prefix = "a=fmtp:\(parts[0]) "
      if lines.contains(where: { $0.hasPrefix(prefix) &&
        highParameters(String($0.dropFirst(prefix.count))) }) { return true }
    }
    return false
  }
}
