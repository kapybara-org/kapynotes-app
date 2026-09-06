import Flutter
import UIKit

/// The app's half of the Write widget.
///
/// The widget opens `kapynotes://write`. UIKit hands that to the scene, the
/// scene parks it here, and Dart collects it once storage has loaded. It is a
/// single string because a single string is all the widget has to say: not
/// what to write, only that the user arrived meaning to carry on writing.
final class QuickCapture {
  static let shared = QuickCapture()

  /// The URL the Write widget and its Lock Screen control open.
  static let writeURL = URL(string: "kapynotes://write")!

  private static let channelName = "kapynotes/quick_capture"

  /// Matches `LaunchIntent.continueWriting` in lib/core/quick_capture.dart.
  private static let continueWriting = "continueWriting"

  private var pendingLaunch: String?

  private init() {}

  /// Notes that this launch, or this return to the foreground, came through
  /// the widget. Anything else in the set is left for the plugins that
  /// `super` goes on to offer it to.
  func absorb(_ urlContexts: Set<UIOpenURLContext>) {
    guard urlContexts.contains(where: { Self.opensWriting($0.url) }) else { return }
    pendingLaunch = Self.continueWriting
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
  /// first one's reason for being open.
  private func take() -> String? {
    defer { pendingLaunch = nil }
    return pendingLaunch
  }

  private static func opensWriting(_ url: URL) -> Bool {
    url.scheme == writeURL.scheme && url.host == writeURL.host
  }
}
