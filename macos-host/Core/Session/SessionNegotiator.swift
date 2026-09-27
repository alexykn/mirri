import Foundation

public struct NegotiatedConfig: Sendable {
  public let codec: VideoCodec
  public let bitrate: UInt32
  public let profile: UInt64
  public let level: UInt64
}

public enum SessionNegotiator {
  public static func negotiate(
    _ hello: ClientGreeting, preferences: HostPreferences,
    hardwareProbe: (VideoCodec) -> Bool
  ) throws -> NegotiatedConfig {
    guard hello.nativeSize == (1600, 2456), hello.active.isExact,
      hello.modes.contains(where: \.isExact)
    else { throw HostFailure.incompatible }
    let choices: [VideoCodec] =
      preferences.codec == .hevc
      ? [.hevc]
      : preferences.codec == .avc ? [.avc] : [.avc, .hevc]
    for codec in choices {
      let supported = hello.codecs.contains {
        $0.codec == codec && $0.supports(level: codec == .avc ? 51 : 153)
      }
      if supported && hardwareProbe(codec) {
        return NegotiatedConfig(
          codec: codec,
          bitrate: codec == .avc ? preferences.avcBitrate : preferences.hevcBitrate,
          profile: codec.rawValue, level: codec == .avc ? 51 : 153)
      }
    }
    throw HostFailure.hardwareCodec
  }
}
