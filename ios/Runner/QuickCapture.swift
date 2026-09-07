import Flutter
import UIKit

/// The app's half of the widgets.
///
/// A widget opens `kapynotes://write`, `kapynotes://dictate` or
/// `kapynotes://capture`. UIKit hands that to the scene, the scene parks it
/// here, and Dart collects it once storage has loaded. It is a single string
/// because a single string is all a widget has to say: not what to write,
/// only which of three ways the user arrived meaning to.
final class QuickCapture {
  static let shared = QuickCapture()

  /// The scheme every widget, control and Lock Screen button opens on.
  private static let scheme = "kapynotes"

  /// Each host a widget can arrive on, and the `LaunchIntent` name Dart knows
  /// it by — see the enum in lib/core/quick_capture.dart. `write` is
  /// `continueWriting` because that is what it does, and because it was named
  /// before there was anything else to tell it apart from.
  private static let launchNames = [
    "write": "continueWriting",
    "dictate": "dictate",
    "capture": "capture",
  ]

  private static let channelName = "kapynotes/quick_capture"

  private var pendingLaunch: String?

  private init() {}

  /// Notes that this launch, or this return to the foreground, came through a
  /// widget. Anything else in the set is left for the plugins that `super`
  /// goes on to offer it to.
  func absorb(_ urlContexts: Set<UIOpenURLContext>) {
    guard let name = urlContexts.lazy.compactMap({ Self.launchName(of: $0.url) }).first
    else { return }
    pendingLaunch = name
  }

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "launchIntent" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(self?.take())
    }
  }

  /// Answers once. A second launch, from the icon, must not inherit the
  /// first one's reason for being open — and a Capture the app has already
  /// acted on must not open the picker a second time when it next resumes.
  private func take() -> String? {
    defer { pendingLaunch = nil }
    return pendingLaunch
  }

  private static func launchName(of url: URL) -> String? {
    guard url.scheme == scheme, let host = url.host else { return nil }
    return launchNames[host]
  }
}
