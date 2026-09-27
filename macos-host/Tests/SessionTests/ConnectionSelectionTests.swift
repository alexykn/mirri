import Foundation
import XCTest

@testable import MirriHostCore

final class ConnectionSelectionTests: XCTestCase {
  private let first = ADBDevice(serial: "A", model: "Tablet")
  private let second = ADBDevice(serial: "B", model: "Other tablet")
  private let wifi = LocalIPv4Address(interface: "en0", address: "192.0.2.12")
  private let lan = LocalIPv4Address(interface: "en7", address: "198.51.100.2")

  func testClaimFreezesRealChoiceUntilStopAndRejectsDuplicateStart() {
    var selection = ConnectionSelection()
    selection.discovered(.success([first]))
    selection.availableAddresses([wifi])
    selection.select(.network)
    XCTAssertFalse(selection.canConnect)
    XCTAssertNotNil(selection.readinessHelp)
    selection.select(wifi)
    let target = selection.claimConnect()
    XCTAssertEqual(target?.device, first)
    XCTAssertEqual(target?.address, wifi)
    XCTAssertNil(selection.claimConnect())
    selection.select(.usb)
    selection.select(second)
    selection.availableAddresses([lan])
    selection.discovered(.success([second]))
    XCTAssertEqual(selection.mode, .network)
    XCTAssertEqual(selection.selectedDevice, first)
    XCTAssertEqual(selection.selectedAddress, wifi)
    XCTAssertTrue(selection.canStop)
    var active = HostSnapshot()
    active.state = .streaming
    selection.update(active)
    selection.finishConnect()
    XCTAssertFalse(selection.isEditable)
    XCTAssertTrue(selection.canRetry)
    XCTAssertFalse(selection.canConnect)
  }

  func testLostAddressNeedsExplicitNewChoiceNotSilentFallback() {
    var selection = ConnectionSelection()
    selection.discovered(.success([first]))
    selection.availableAddresses([wifi, lan])
    selection.select(.network)
    selection.select(wifi)
    XCTAssertTrue(selection.canConnect)
    selection.availableAddresses([lan])
    XCTAssertNil(selection.selectedAddress)
    XCTAssertFalse(selection.canConnect)
    selection.select(wifi)  // Stale UI event must not recover the old address.
    XCTAssertNil(selection.selectedAddress)
    selection.select(lan)
    XCTAssertEqual(selection.claimConnect()?.address, lan)
  }

  func testDiscoveryErrorClearsFalseReadyAndRecoveryNeverPicksAnotherTablet() {
    var selection = ConnectionSelection()
    selection.discovered(.success([first]))
    XCTAssertTrue(selection.canConnect)
    selection.discovered(.failure(HostFailure.adb))
    XCTAssertTrue(selection.discoveryFailed)
    XCTAssertFalse(selection.canConnect)
    XCTAssertNil(selection.selectedDevice)
    selection.discovered(.success([second]))
    XCTAssertFalse(selection.discoveryFailed)
    XCTAssertNil(selection.selectedDevice)
    XCTAssertFalse(selection.canConnect)
    selection.select(second)
    XCTAssertEqual(selection.claimConnect()?.device, second)
  }

  func testHeadlineOnlySaysReadyWhenChoiceCanConnect() {
    var selection = ConnectionSelection()
    XCTAssertEqual(selection.headline, "Checking for tablet…")
    selection.discovered(.success([]))
    XCTAssertEqual(selection.headline, "Connect your tablet")
    selection.discovered(.failure(HostFailure.adb))
    XCTAssertEqual(selection.headline, "Unable to find tablets")
    selection.discovered(.success([first, second]))
    XCTAssertEqual(selection.headline, "Choose a tablet")
    selection.select(first)
    selection.select(.network)
    XCTAssertEqual(selection.headline, "Connect Mac to a network")
    selection.availableAddresses([wifi])
    XCTAssertEqual(selection.headline, "Choose network address")
    selection.select(wifi)
    XCTAssertTrue(selection.canConnect)
    XCTAssertEqual(selection.headline, "Ready to connect")
  }

  func testMaintenanceNoticeClearsOnNewOperationAndSuccessAndFreezesConnect() {
    var selection = ConnectionSelection()
    selection.discovered(.success([first]))
    XCTAssertTrue(selection.claimOperation(on: first))
    XCTAssertFalse(selection.canConnect)
    XCTAssertNil(selection.claimConnect())
    selection.discovered(.failure(HostFailure.adb))  // In-flight selection is frozen.
    XCTAssertEqual(selection.selectedDevice, first)
    selection.finishOperation(issue: "USB cleanup could not complete")
    XCTAssertEqual(selection.headline, "Needs attention")
    XCTAssertEqual(selection.notice, .operation("USB cleanup could not complete"))
    XCTAssertTrue(selection.claimOperation(on: first))
    XCTAssertNil(selection.notice)
    selection.finishOperation()
    XCTAssertNil(selection.notice)
    XCTAssertEqual(selection.headline, "Ready to connect")
    _ = selection.claimConnect()
    selection.finishConnect(issue: "Tablet did not respond")
    XCTAssertEqual(selection.headline, "Connection failed")
    XCTAssertEqual(selection.notice, .connection("Tablet did not respond"))
    _ = selection.claimConnect()
    XCTAssertNil(selection.notice)
    selection.finishConnect(issue: "Tablet did not respond")
    selection.discovered(.failure(HostFailure.adb))
    XCTAssertEqual(selection.headline, "Unable to find tablets")
  }
}
