import FlutterMacOS
import Foundation

/// Backs the `kapynotes/region` channel: the country this device is set to.
///
/// `Locale.current` carries the Region setting even when the app is being read
/// in another language — on a Mac set to English (US) with Region India its
/// identifier is `en_US@rg=inzzzz`, and `region` is `IN`. The preferred
/// languages list that Flutter builds its locale from says `en-US` and knows
/// nothing about the `IN`, which is why the Dart side has to come here.
enum SystemRegion {
  static let channelName = "kapynotes/region"

  static func register(with messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "region" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(current())
    }
    return channel
  }

  /// Nil rather than a guess where the system has no region to give. The Dart
  /// side reads that as "fall back to the language", which is what it did
  /// before it could ask at all.
  private static func current() -> String? {
    if #available(macOS 13.0, iOS 16.0, *) {
      return Locale.current.region?.identifier
    }
    return (Locale.current as NSLocale).object(forKey: .countryCode) as? String
  }
}
