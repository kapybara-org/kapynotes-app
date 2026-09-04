import FlutterMacOS
import Foundation
import ServiceManagement

/// Backs the `kapynotes/login_item` channel: "Open at login" in Settings.
///
/// `SMAppService` rather than a LaunchAgent plist because this bundle is
/// sandboxed and may not write into `~/Library/LaunchAgents` — which is also
/// why the Flutter packages that offer this cannot be used here. It arrived in
/// macOS 13, so Ventura is the floor; earlier systems report the feature as
/// missing and the settings pane leaves the row out.
enum LoginItem {
  static let channelName = "kapynotes/login_item"

  static func register(with messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      handle(call, result)
    }
    return channel
  }

  private static func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard #available(macOS 13.0, *) else {
      switch call.method {
      case "isSupported", "isEnabled":
        result(false)
      default:
        result(
          FlutterError(
            code: "unsupported",
            message: "Opening at login needs macOS 13 or later.",
            details: nil
          )
        )
      }
      return
    }

    let service = SMAppService.mainApp

    switch call.method {
    case "isSupported":
      result(true)

    case "isEnabled":
      // `.requiresApproval` means the registration exists but the user has it
      // switched off in System Settings, where it will stay until they say
      // otherwise. Reporting that as on would promise a launch that is not
      // going to happen.
      result(service.status == .enabled)

    case "setEnabled":
      guard
        let arguments = call.arguments as? [String: Any],
        let enabled = arguments["enabled"] as? Bool
      else {
        result(
          FlutterError(code: "bad-arguments", message: "Expected an enabled flag.", details: nil)
        )
        return
      }
      setEnabled(enabled, on: service, result)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  @available(macOS 13.0, *)
  private static func setEnabled(
    _ enabled: Bool,
    on service: SMAppService,
    _ result: @escaping FlutterResult
  ) {
    do {
      if enabled {
        // Registering an already-registered app throws rather than passing.
        if service.status != .enabled {
          try service.register()
        }
        if service.status == .requiresApproval {
          result(
            FlutterError(
              code: "requires-approval",
              message: "Allow Kapy Notes in System Settings › General › Login Items.",
              details: nil
            )
          )
          return
        }
      } else {
        try service.unregister()
      }
      result(nil)
    } catch {
      result(
        FlutterError(
          code: "login-item",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }
}
