import Foundation

/// Mirri packetizer only: no second admission queue or ownership of capture/encoder state.
public actor MirriVideoSink: EncodedVideoSink {
  private let channel: WireConnection
  private let sessionId: Data
  private let epoch: UInt32
  private let generation: UInt32
  private let config: NegotiatedConfig
  private let latencyTrace: HostLatencyTrace?
  private var configured = false
  public init(
    channel: WireConnection, sessionId: Data, epoch: UInt32, generation: UInt32,
    config: NegotiatedConfig, latencyTrace: HostLatencyTrace? = nil
  ) {
    self.channel = channel
    self.sessionId = sessionId
    self.epoch = epoch
    self.generation = generation
    self.config = config
    self.latencyTrace = latencyTrace
  }
  public func write(_ unit: EncodedUnit, ordinal: UInt64) async throws {
    if !configured {
      guard unit.keyframe, let sets = unit.parameterSets else { throw HostFailure.hardwareCodec }
      try await channel.send(
        HostCommand.codecConfiguration(generation: generation, config: config, sets: sets)
          .wire(sessionId: sessionId, epoch: epoch))
      configured = true
    }
    let flags: UInt64 = unit.keyframe ? (ordinal == 0 ? 3 : 1) : 0
    latencyTrace?.prewrite(
      unit, sequence: ordinal, atNs: DispatchTime.now().uptimeNanoseconds)
    try await channel.send(
      HostCommand.frame(
        generation: generation, sequence: ordinal, pts: unit.pts, flags: flags,
        data: unit.accessUnit
      ).wire(sessionId: sessionId, epoch: epoch))
  }
}
