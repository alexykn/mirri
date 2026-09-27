import Crypto
import Darwin
import Foundation
import Security
import SwiftASN1
import X509

/// A concrete interface/address binding selected by the user, never a wildcard default.
public struct LocalIPv4Address: Sendable, Equatable {
  public let interface: String
  public let address: String
  public init(interface: String, address: String) {
    self.interface = interface
    self.address = address
  }
  public static func available() -> [Self] {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return [] }
    defer { freeifaddrs(first) }
    var selected: [Self] = []
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let item = cursor {
      defer { cursor = item.pointee.ifa_next }
      let interface = item.pointee
      guard interface.ifa_flags & UInt32(IFF_UP) != 0,
        interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
        let addr = interface.ifa_addr, addr.pointee.sa_family == AF_INET
      else { continue }
      var ipv4 = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
      var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
      guard inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(buffer.count)) != nil else { continue }
      guard
        let address = String(
          bytes: buffer.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), encoding: .utf8)
      else { continue }
      let octets = address.split(separator: ".").compactMap { UInt8($0) }
      guard octets.count == 4, octets[0] != 0, octets[0] != 127, octets[0] < 224
      else { continue }
      selected.append(Self(interface: String(cString: interface.ifa_name), address: address))
    }
    return selected.sorted { ($0.interface, $0.address) < ($1.interface, $1.address) }
  }
  public func validateCurrent() throws {
    guard Self.available().contains(self) else { throw HostFailure.transport }
  }
  var octets: [UInt8] { address.split(separator: ".").compactMap { UInt8($0) } }
}

/// In-memory self-signed TLS identity. Neither key nor certificate is persisted.
public struct NetworkIdentity: @unchecked Sendable {
  public let pin: Data
  public let certificateDER: Data
  public let expiresAt: Date
  public let identity: sec_identity_t

  public static func create(for address: LocalIPv4Address, now: Date = Date()) throws -> Self {
    guard address.octets.count == 4 else { throw HostFailure.transport }
    let key = P256.Signing.PrivateKey()
    let name = try DistinguishedName { CommonName("Mirri ephemeral \(address.address)") }
    let cert = try Certificate(
      version: .v3,
      serialNumber: .init(bytes: Array((0..<16).map { _ in UInt8.random(in: 0...255) })),
      publicKey: .init(key.publicKey),
      notValidBefore: now.addingTimeInterval(-300),
      notValidAfter: now.addingTimeInterval(24 * 60 * 60),
      issuer: name, subject: name, signatureAlgorithm: .ecdsaWithSHA256,
      extensions: try Certificate.Extensions {
        Critical(BasicConstraints.notCertificateAuthority)
        Critical(KeyUsage(digitalSignature: true))
        SubjectAlternativeNames([.ipAddress(ASN1OctetString(contentBytes: address.octets[...]))])
      }, issuerPrivateKey: .init(key))
    var serializer = DER.Serializer()
    try serializer.serialize(cert)
    let der = Data(serializer.serializedBytes)
    guard let secCertificate = SecCertificateCreateWithData(nil, der as CFData) else {
      throw HostFailure.transport
    }
    // Security expects X9.63 uncompressed public point followed by 32-byte scalar.
    let x963 = Data(key.publicKey.x963Representation) + Data(key.rawRepresentation)
    let attributes =
      [
        kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        kSecAttrKeySizeInBits: 256,
      ] as CFDictionary
    var keyError: Unmanaged<CFError>?
    guard let secKey = SecKeyCreateWithData(x963 as CFData, attributes, &keyError),
      let secIdentity = SecIdentityCreate(nil, secCertificate, secKey),
      let nwIdentity = sec_identity_create(secIdentity)
    else { throw HostFailure.transport }
    return Self(
      pin: Data(SHA256.hash(data: der)), certificateDER: der,
      expiresAt: now.addingTimeInterval(24 * 60 * 60), identity: nwIdentity)
  }
  private init(pin: Data, certificateDER: Data, expiresAt: Date, identity: sec_identity_t) {
    self.pin = pin
    self.certificateDER = certificateDER
    self.expiresAt = expiresAt
    self.identity = identity
  }
}
