import FlutterMacOS
import Foundation
import XPC

/// Backs the `kapynotes/tool_runner` channel: Codex and Claude Code for the
/// sandboxed app, run by KapyToolRunner.xpc, which is embedded in the
/// Developer ID build and in development builds, and never in the Mac App
/// Store build (KAPY_TOOL_RUNNER in packaging/release.sh).
///
/// The app checks the service as the service checks the app: our team's
/// signature and the service's own identifier, read from the bundle that
/// is embedded rather than assumed. A build without the service, or with
/// one that does not pass, answers the ping with false, and Dart does not
/// offer either tool.
///
/// Requests and responses are JSON, passed through unread: what a request
/// may hold is the service's to decide (KapyToolRunner/ToolRunner.swift).
enum ToolRunnerClient {
  static let channelName = "kapynotes/tool_runner"
  static let team = "96V66447C6"

  static func register(with messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      handle(call, result)
    }
    return channel
  }

  private static func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "ping":
      send({ xpc_dictionary_set_bool($0, "ping", true) }, within: 5) { reply in
        result(reply.map { xpc_dictionary_get_bool($0, "pong") } ?? false)
      }

    case "run":
      guard let request = call.arguments as? String else {
        result(FlutterError(code: "bad-arguments", message: "Expected a request.", details: nil))
        return
      }
      let bytes = Data(request.utf8)
      send(
        { message in
          bytes.withUnsafeBytes { buffer in
            if let base = buffer.baseAddress {
              xpc_dictionary_set_data(message, "request", base, buffer.count)
            }
          }
        },
        within: 180
      ) { reply in
        var length = 0
        guard let reply, let data = xpc_dictionary_get_data(reply, "response", &length) else {
          result(FlutterError(code: "unavailable", message: nil, details: nil))
          return
        }
        result(String(decoding: Data(bytes: data, count: length), as: UTF8.self))
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// The embedded service's name, which is its bundle identifier.
  static var serviceName: String? {
    let url = Bundle.main.bundleURL.appendingPathComponent(
      "Contents/XPCServices/KapyToolRunner.xpc")
    return Bundle(url: url)?.bundleIdentifier
  }

  static func requirement(forService identifier: String) -> String? {
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
    guard
      identifier.hasPrefix("com.kapybara.kapynotes."),
      identifier.unicodeScalars.allSatisfy(allowed.contains)
    else { return nil }
    return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
      + " and identifier \"\(identifier)\""
  }

  /// One message on a connection of its own, and one call of [completion]
  /// on the main queue: with the reply, or with nil when there is no
  /// service, the service fails its check, the connection breaks, or no
  /// reply comes in time.
  private static func send(
    _ fill: (xpc_object_t) -> Void, within seconds: TimeInterval,
    completion: @escaping (xpc_object_t?) -> Void
  ) {
    guard let name = serviceName, let requirement = requirement(forService: name) else {
      completion(nil)
      return
    }
    let connection = xpc_connection_create(name, .main)
    guard xpc_connection_set_peer_code_signing_requirement(connection, requirement) == 0 else {
      xpc_connection_cancel(connection)
      completion(nil)
      return
    }
    xpc_connection_set_event_handler(connection) { _ in }
    xpc_connection_resume(connection)

    var done = false
    let finish: (xpc_object_t?) -> Void = { reply in
      guard !done else { return }
      done = true
      completion(reply)
      xpc_connection_cancel(connection)
    }
    let message = xpc_dictionary_create(nil, nil, 0)
    fill(message)
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { finish(nil) }
    xpc_connection_send_message_with_reply(connection, message, .main) { reply in
      finish(xpc_get_type(reply) == XPC_TYPE_DICTIONARY ? reply : nil)
    }
  }
}
