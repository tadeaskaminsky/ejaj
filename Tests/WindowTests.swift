import Cocoa
import SwiftUI

// Checks that need SwiftUI and a window server, kept apart so collector-tests stays plain Foundation.
// It runs in a logged-in session (scripts/build.sh from Terminal), not over SSH.
@main struct WindowTests {
  static func main() {
    MainActor.assumeIsolated {
      _ = NSApplication.shared
      // NSHostingView copies the dashboard's maximum size into the window's, so a width cap there stops a
      // title-bar double-click short of the screen. The minimum proves the sizes reached the window at all.
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled, .resizable],
        backing: .buffered, defer: false)
      window.contentView = NSHostingView(rootView: Dashboard(store: UsageStore()))
      window.updateConstraintsIfNeeded()
      precondition(window.contentMinSize.width == 880, "hosting view sizes not applied: \(window.contentMinSize)")
      precondition(window.contentMaxSize.width == .infinity, "dashboard caps the window: \(window.contentMaxSize)")
    }
    print("PASS: dashboard window has no maximum width")
  }
}
