import Cocoa
import FlutterMacOS

/// Backs the `kapynotes/window_pin` channel, in the one direction it runs:
/// this side asking Dart to stop keeping the window on top.
///
/// "Keep on top" gives the window `NSWindow.Level.floating`, and anything
/// AppKit opens on the app's behalf — the standard About panel is the one
/// this app can reach — opens at `.normal`. A floating window is in front of
/// a normal one however recently the normal one was ordered front, so the
/// panel arrives underneath the window it was asked for from and the menu
/// item looks like it did nothing at all.
///
/// The ask goes over to Dart rather than being settled here, where the window
/// is in reach, because the pin is a preference as much as a window level.
/// Lowering the window alone would leave the toolbar's pin button lit above a
/// window that no longer floats, and the next press of it would try to turn
/// off something already off.
enum WindowPin {
  static let channelName = "kapynotes/window_pin"

  /// Static because the caller is the app delegate: a menu action arriving up
  /// the responder chain has no route back to whatever registered the
  /// channel, and the window that did is not in the chain for it.
  private static var channel: FlutterMethodChannel?

  static func register(with messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    Self.channel = channel
    return channel
  }

  /// Runs [show] once the window has stopped floating.
  ///
  /// Waiting for the reply is the point. Ordering the panel front first and
  /// lowering the window after leaves the two in whatever order AppKit
  /// settles on, which is the thing being fixed.
  ///
  /// A Dart side that has not started listening yet answers all the same —
  /// `FlutterMethodChannel` calls back with `FlutterMethodNotImplemented`
  /// rather than staying silent — so the panel is never lost to a reply that
  /// does not come.
  static func release(then show: @escaping () -> Void) {
    guard let channel else {
      show()
      return
    }
    channel.invokeMethod("release", arguments: nil) { _ in show() }
  }
}
