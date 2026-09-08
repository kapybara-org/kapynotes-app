import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

/// Publishes alternative representations without bringing another runtime
/// into the app just to own the clipboard.
enum RichClipboard {
  private static let channelName = "kapynotes/rich_clipboard"

  static func register(with messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "write":
        write(call.arguments, result: result)
      case "readHtml":
        result(NSPasteboard.general.string(forType: .html))
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

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    pasteboard.setString(html, forType: .html)

    if let typed = arguments["image"] as? FlutterStandardTypedData,
       !typed.data.isEmpty,
       let mime = arguments["imageMime"] as? String,
       let type = UTType(mimeType: mime) {
      pasteboard.setData(typed.data, forType: NSPasteboard.PasteboardType(type.identifier))
    }
    result(nil)
  }
}
