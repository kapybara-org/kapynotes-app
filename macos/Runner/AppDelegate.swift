import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Keep the lightweight app alive so its global shortcut can reopen the
    // window after the user clicks the red close button. Quit still exits.
    return false
  }

  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag {
      for window in sender.windows {
        window.makeKeyAndOrderFront(self)
      }
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// The App menu's About item, which the nib now points here rather than
  /// straight at `NSApplication.orderFrontStandardAboutPanel(_:)`.
  ///
  /// The standard panel opens at the ordinary window level, so with "Keep on
  /// top" switched on it would open behind the window it was asked for from,
  /// and choosing About would look like it did nothing. The pin goes first,
  /// and the panel follows once it has: see WindowPin.
  ///
  /// It lands here because the responder chain hands menu actions to
  /// `NSApplication` before the delegate, and `NSApplication` implements
  /// `orderFrontStandardAboutPanel:` itself — an override of that would never
  /// be reached. A selector only this object answers to is.
  @objc func showAboutPanel(_ sender: Any?) {
    WindowPin.release { NSApp.orderFrontStandardAboutPanel(sender) }
  }
}
