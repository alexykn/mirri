import AppKit
import ApplicationServices
import CoreGraphics

@MainActor final class PermissionsController {
  func screenRecordingStatus() -> Bool { CGPreflightScreenCaptureAccess() }
  func requestScreenRecording() { _ = CGRequestScreenCaptureAccess() }
  func accessibilityStatus(prompt: Bool) -> Bool {
    AXIsProcessTrustedWithOptions(
      ["AXTrustedCheckOptionPrompt": prompt]
        as CFDictionary)
  }
  func ready() -> Bool {
    if !screenRecordingStatus() {
      requestScreenRecording()
      return false
    }
    return accessibilityStatus(prompt: true)
  }
}
