import Foundation
import XPC

/// Who may talk to the helper, and how it answers.
///
/// Only the app it is embedded in, signed by our team: every new connection
/// gets a code-signing requirement that the XPC runtime checks against the
/// connecting process's audit token, for every message, before the message
/// is delivered. `xpc_connection_set_peer_code_signing_requirement` is public
/// from macOS 12, which is the app's deployment target, so there is no
/// older path to fall back to.
enum Listener {
  static let team = "96V66447C6"
  static let appIdentifierPrefix = "com.kapybara.kapynotes"

  /// What the connecting app must satisfy: an Apple-issued certificate for
  /// our team, and the identifier of the app this service is in. Nil, and
  /// so no connection at all, for an identifier outside our prefix or with
  /// a character the requirement language would read as syntax.
  static func requirement(forApp identifier: String) -> String? {
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
    guard
      identifier == appIdentifierPrefix || identifier.hasPrefix(appIdentifierPrefix + "."),
      identifier.unicodeScalars.allSatisfy(allowed.contains)
    else { return nil }
    return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
      + " and identifier \"\(identifier)\""
  }

  /// The identifier of the app at `<app>/Contents/XPCServices/<service>.xpc`.
  static func containingApp(of service: URL) -> String? {
    let services = service.deletingLastPathComponent()
    let app = services.deletingLastPathComponent().deletingLastPathComponent()
    guard services.lastPathComponent == "XPCServices", app.pathExtension == "app" else {
      return nil
    }
    return Bundle(url: app)?.bundleIdentifier
  }

  static let peerRequirement = containingApp(of: Bundle.main.bundleURL)
    .flatMap(requirement(forApp:))

  /// Sets up one peer. With no requirement, or one the runtime will not
  /// take, the peer is cancelled before it can send anything. A message from
  /// a peer that does not satisfy it never arrives: the runtime reports
  /// XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT instead, and the peer is
  /// cancelled.
  static func accept(
    _ peer: xpc_connection_t, requirement: String?, handle: @escaping (Data) -> Data
  ) {
    guard let requirement,
      xpc_connection_set_peer_code_signing_requirement(peer, requirement) == 0
    else {
      xpc_connection_cancel(peer)
      return
    }
    xpc_connection_set_event_handler(peer) { event in
      guard xpc_get_type(event) == XPC_TYPE_DICTIONARY else {
        xpc_connection_cancel(peer)
        return
      }
      guard let reply = xpc_dictionary_create_reply(event) else { return }
      if xpc_dictionary_get_bool(event, "ping") {
        xpc_dictionary_set_bool(reply, "pong", true)
        xpc_connection_send_message(peer, reply)
        return
      }
      var length = 0
      let bytes = xpc_dictionary_get_data(event, "request", &length)
      let request = bytes.map { Data(bytes: $0, count: length) } ?? Data()
      DispatchQueue.global(qos: .userInitiated).async {
        let response = handle(request)
        response.withUnsafeBytes { buffer in
          if let base = buffer.baseAddress {
            xpc_dictionary_set_data(reply, "response", base, buffer.count)
          }
        }
        xpc_connection_send_message(peer, reply)
      }
    }
    xpc_connection_resume(peer)
  }
}
