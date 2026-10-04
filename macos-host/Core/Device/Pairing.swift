import Crypto
import Foundation

/// What a tablet needs to find and trust this host again without a cable.
public struct PairingGrant: Sendable, Equatable {
  public let id: Data
  public let key: Data
  /// SHA-256 of the host's persistent rendezvous certificate.
  public let pin: Data
}

public struct PairedTablet: Sendable, Equatable {
  public let id: Data
  public let label: String
}

/// The host's persistent rendezvous identity and the tablets allowed to use it.
/// Files are owner-only under Application Support; a tablet's secret is stored
/// only as a SHA-256, so reading this store does not let anyone pose as a tablet.
public actor PairingStore {
  private struct StoredIdentity: Codable {
    let key: Data
    let certificate: Data
  }
  private struct StoredTablet: Codable {
    let id: Data
    let keyHash: Data
    let label: String
  }

  public static var defaultDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Mirri", isDirectory: true)
      .appendingPathComponent("Pairing", isDirectory: true)
  }

  private let directory: URL
  private var cached: NetworkIdentity?
  public init(directory: URL = PairingStore.defaultDirectory) { self.directory = directory }

  private func write(_ data: Data, to name: String) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = directory.appendingPathComponent(name)
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  private func read(_ name: String) -> Data? {
    try? Data(contentsOf: directory.appendingPathComponent(name))
  }

  /// Created on first use and then stable, so existing pairings keep working.
  public func identity() throws -> NetworkIdentity {
    if let cached { return cached }
    if let data = read("identity.json"),
      let stored = try? JSONDecoder().decode(StoredIdentity.self, from: data),
      let restored = try? NetworkIdentity.restore(
        key: stored.key, certificateDER: stored.certificate),
      restored.expiresAt > Date()
    {
      cached = restored
      return restored
    }
    let created = try NetworkIdentity.createPersistent()
    try write(
      try JSONEncoder().encode(
        StoredIdentity(key: created.key, certificate: created.identity.certificateDER)),
      to: "identity.json")
    // Tablets pinned the old certificate; their records can never match again.
    try write(try JSONEncoder().encode([StoredTablet]()), to: "tablets.json")
    cached = created.identity
    return created.identity
  }

  private func tablets() -> [StoredTablet] {
    read("tablets.json").flatMap { try? JSONDecoder().decode([StoredTablet].self, from: $0) } ?? []
  }

  /// A fresh secret for one tablet. Only the eight most recent grants are kept:
  /// a tablet paired again simply replaces the secret it holds.
  public func issue(label: String) throws -> PairingGrant {
    let pin = try identity().pin
    var generator = SystemRandomNumberGenerator()
    let id = Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    let key = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    var all = tablets()
    all.append(StoredTablet(id: id, keyHash: Data(SHA256.hash(data: key)), label: label))
    try write(try JSONEncoder().encode(Array(all.suffix(8))), to: "tablets.json")
    return PairingGrant(id: id, key: key, pin: pin)
  }

  public func verify(id: Data, key: Data) -> PairedTablet? {
    guard id.count == 16, key.count == 32 else { return nil }
    let hash = Data(SHA256.hash(data: key))
    // Compare every record so timing does not reveal which IDs exist.
    var match: StoredTablet?
    for tablet in tablets() where Authenticator.equals(tablet.keyHash, hash) && tablet.id == id {
      match = tablet
    }
    return match.map { PairedTablet(id: $0.id, label: $0.label) }
  }

  public func paired() -> [PairedTablet] {
    tablets().map { PairedTablet(id: $0.id, label: $0.label) }
  }

  public func removeAll() throws {
    try write(try JSONEncoder().encode([StoredTablet]()), to: "tablets.json")
  }
}
