import AppKit
import FlutterMacOS

/// Backs the `kapynotes/contrast` channel: whether Increase contrast is on in
/// System Settings › Accessibility › Display.
///
/// Flutter's macOS embedder never reports it, so Dart asks here once and is
/// told each time it changes. Increase contrast in Kapy Notes follows it until
/// the person sets the switch themselves.
enum ContrastSetting {
  static let channelName = "kapynotes/contrast"

  static func register(with messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "increaseContrast" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(current())
    }
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil,
      queue: .main
    ) { _ in
      channel.invokeMethod("changed", arguments: current())
    }
    return channel
  }

  private static func current() -> Bool {
    NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
  }
}
