import Flutter
import UIKit
import UniformTypeIdentifiers

/// The system clipboard representation for a note selection containing images.
enum RichClipboard {
  private static let channelName = "kapynotes/rich_clipboard"

  static func register(with messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "write":
        write(call.arguments, result: result)
      case "readHtml":
        result(readHtml())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    return channel
  }

  private static func write(_ rawArguments: Any?, result: FlutterResult) {
    guard let arguments = rawArguments as? [String: Any],
          let text = arguments["text"] as? String,
          let html = arguments["html"] as? String else {
      result(FlutterError(code: "clipboard_arguments", message: "Missing clipboard data", details: nil))
      return
    }

    var item: [String: Any] = [
      UTType.utf8PlainText.identifier: text,
      UTType.html.identifier: html,
    ]
    if let typed = arguments["image"] as? FlutterStandardTypedData,
       !typed.data.isEmpty,
       let mime = arguments["imageMime"] as? String,
       let type = UTType(mimeType: mime) {
      item[type.identifier] = typed.data
    }
    UIPasteboard.general.setItems([item], options: [:])
    result(nil)
  }

  private static func readHtml() -> String? {
    let pasteboard = UIPasteboard.general
    if let data = pasteboard.data(forPasteboardType: UTType.html.identifier) {
      return String(data: data, encoding: .utf8)
    }
    return pasteboard.value(forPasteboardType: UTType.html.identifier) as? String
  }
}
