import Cocoa
import FlutterMacOS

/// Backs the `kapynotes/window_material` channel: the "Transparency" switch in
/// Settings, on the native side.
///
/// The desktop shows through this app because the Flutter view sits on an
/// `NSVisualEffectView` that blends behind the window, and Flutter paints
/// thin tints over it. The material decides how much of the desktop survives
/// the blur. With transparency off it is `underWindowBackground`, which is
/// nearly solid and reads as an ordinary window even though the Flutter
/// surfaces above it are opaque anyway. With it on it thins to a glass that
/// lets colour and shape through while its blur keeps them from competing with
/// the writing — the same trick the system's own sidebars use, only lighter.
///
/// The view also stops following the window's key state while the glass is
/// on: the material only blurs the desktop while the window is active by
/// default, and a note left floating beside another app is exactly when the
/// glass is wanted.
///
/// Reduce Transparency in System Settings still wins. AppKit flattens every
/// vibrant material to an opaque colour while it is on, and the Flutter side
/// puts its opaque paint back at the same time.
enum WindowMaterial {
  static let channelName = "kapynotes/window_material"

  static func register(
    with messenger: FlutterBinaryMessenger,
    view: NSVisualEffectView
  ) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak view] call, result in
      guard let view else {
        result(FlutterError(code: "no-window", message: "The window is gone.", details: nil))
        return
      }
      handle(call, view: view, result)
    }
    return channel
  }

  /// [amount] is the settings slider, 0 to 1, and the reason it reaches the
  /// native side at all: the material has a body of its own. Thinning only
  /// the tints Flutter paints leaves that body in place, and the window stops
  /// getting any clearer however far the slider goes.
  ///
  /// Fading the view is what gets past it. At full strength the material is
  /// an ordinary macOS blur; as the view fades, less of it is composited and
  /// more of the desktop arrives unaltered, until at the top of the slider
  /// there is only a trace of blur left holding the type off the wallpaper.
  /// It never reaches zero, because a window with no material at all is a
  /// sheet of glass with nothing behind the letters.
  static func apply(glass: Bool, amount: Double, to view: NSVisualEffectView) {
    if glass {
      // `hudWindow` is the thinnest material AppKit offers for behind-window
      // blending, in both appearances. `fullScreenUI` keeps more of the
      // desktop's colour but also more of its detail, which is what makes a
      // paragraph over a busy wallpaper hard work.
      view.material = .hudWindow
      view.state = .active
      let t = min(max(amount, 0), 1)
      view.alphaValue = 1 - (0.88 * t)
    } else {
      view.material = .underWindowBackground
      view.state = .followsWindowActiveState
      view.alphaValue = 1
    }
  }

  private static func handle(
    _ call: FlutterMethodCall,
    view: NSVisualEffectView,
    _ result: @escaping FlutterResult
  ) {
    switch call.method {
    case "setGlass":
      guard
        let arguments = call.arguments as? [String: Any],
        let enabled = arguments["enabled"] as? Bool
      else {
        result(
          FlutterError(code: "bad-arguments", message: "Expected an enabled flag.", details: nil)
        )
        return
      }
      // An older Dart side that sends no amount gets the middle of the scale
      // rather than an error: the flag is the part this cannot do without.
      let amount = arguments["amount"] as? Double ?? 0.5
      apply(glass: enabled, amount: amount, to: view)
      // AppKit always has a material to offer; the Windows runner answers
      // the same question honestly, and Dart treats the two alike.
      result(true)

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
