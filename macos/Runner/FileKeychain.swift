import FlutterMacOS
import Foundation
import Security

/// Backs the `kapynotes/file_keychain` channel: reading and deleting the
/// entries earlier versions kept in the file-based login keychain, so they
/// can move into the data-protection keychain (see MigratingSecureStore).
///
/// Not flutter_secure_storage, because asked for the file keychain it leaves
/// `kSecUseDataProtectionKeychain` unset, and in an app signed with a keychain
/// access group an unset flag reaches the data-protection keychain too:
/// deleting the old entry deleted the new copy along with it. Here the flag
/// is always an explicit false.
enum FileKeychain {
  static let channelName = "kapynotes/file_keychain"

  static func register(with messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      handle(call, result)
    }
    return channel
  }

  private static func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard
      let arguments = call.arguments as? [String: Any],
      let service = arguments["service"] as? String,
      let account = arguments["account"] as? String
    else {
      result(
        FlutterError(code: "bad-arguments", message: "Expected a service and an account.", details: nil)
      )
      return
    }
    var query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecUseDataProtectionKeychain: false,
    ]

    switch call.method {
    case "read":
      query[kSecReturnData] = true
      var item: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &item)
      if status == errSecItemNotFound {
        result(nil)
      } else if status == errSecSuccess, let data = item as? Data {
        result(String(decoding: data, as: UTF8.self))
      } else {
        result(failure(status))
      }

    case "delete":
      let status = SecItemDelete(query as CFDictionary)
      result(status == errSecSuccess || status == errSecItemNotFound ? nil : failure(status))

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func failure(_ status: OSStatus) -> FlutterError {
    FlutterError(
      code: "\(status)",
      message: SecCopyErrorMessageString(status, nil) as String?,
      details: nil
    )
  }
}
