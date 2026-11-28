import CallKit
import Flutter
import UIKit

/// Backs the `kapynotes/camera` channel: what the note camera asks of the
/// phone around it (lib/images/camera_capture.dart).
///
/// Free space is what iOS would make room for an important file, which
/// counts the caches it can clear. A call is any CallKit call not yet ended:
/// ringing, a phone call, or a call in another app.
enum CameraSupport {
  static let channelName = "kapynotes/camera"
  private static let calls = CXCallObserver()

  static func register(with messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "freeBytes":
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        let values = try? folder.resourceValues(forKeys: [
          .volumeAvailableCapacityForImportantUsageKey
        ])
        result(values?.volumeAvailableCapacityForImportantUsage.map { Int($0) })
      case "inCall":
        result(calls.calls.contains { !$0.hasEnded })
      case "openSettings":
        if let url = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(url)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    return channel
  }
}
