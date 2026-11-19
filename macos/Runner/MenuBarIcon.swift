import Cocoa
import FlutterMacOS

/// Lets the menu bar icon be pressed through accessibility, as VoiceOver
/// presses it.
///
/// tray_manager reads clicks on a view it lays over the status item's button
/// and leaves the button itself with no action, so a press that goes to the
/// button, rather than a mouse click, did nothing. This gives the button an
/// action that tells Dart, which treats it as a click on the icon. Mouse
/// clicks still land on tray_manager's view and never reach the button, so a
/// click is never counted twice and a right-click still opens the menu.
final class MenuBarIcon: NSObject {
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "kapynotes/menubar_icon", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "takePresses" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(self?.takePresses() ?? false)
    }
  }

  /// Points the button of each status item this app shows at [pressed], and
  /// answers whether there was one.
  private func takePresses() -> Bool {
    let buttons = NSApp.windows.flatMap { Self.buttons(in: $0.contentView) }
    for button in buttons {
      button.target = self
      button.action = #selector(pressed)
      button.setAccessibilityLabel("Kapy Notes")
    }
    return !buttons.isEmpty
  }

  private static func buttons(in view: NSView?) -> [NSStatusBarButton] {
    guard let view else { return [] }
    if let button = view as? NSStatusBarButton { return [button] }
    return view.subviews.flatMap { buttons(in: $0) }
  }

  @objc private func pressed() {
    channel.invokeMethod("pressed", arguments: nil)
  }
}
