import Flutter
import UIKit
import UniformTypeIdentifiers

/// Backs the `kapynotes/file_export` channel: "where do you want this?", asked
/// by iOS rather than drawn by the app.
///
/// `UIDocumentPickerViewController(forExporting:)` is the sheet every other app
/// uses to put a file into Files, iCloud Drive, or anywhere else a document
/// provider offers. It copies from a URL rather than writing into one, which is
/// why the Dart side builds the archive into a temporary file first and hands
/// this its path.
///
/// The picker is presented from whatever is on screen, so an export started
/// from the settings sheet opens over the settings sheet and returns to it.
final class FileExport: NSObject, UIDocumentPickerDelegate {
  static let channelName = "kapynotes/file_export"

  /// Held for the app's lifetime by whoever registered it. The picker's
  /// delegate is unowned, so an instance that only lived as long as the call
  /// would be gone by the time the user chose anything.
  private static var shared: FileExport?

  /// The call being answered, cleared the moment it is. Only one save can be
  /// open at a time: the picker is modal, so a second is not reachable.
  private var pending: FlutterResult?

  static func register(with messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    let handler = FileExport()
    shared = handler
    channel.setMethodCallHandler { call, result in
      handler.handle(call, result)
    }
    return channel
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard call.method == "save" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard
      let arguments = call.arguments as? [String: Any],
      let path = arguments["path"] as? String
    else {
      result(FlutterError(code: "arguments", message: "No file to save.", details: nil))
      return
    }

    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: path) else {
      result(FlutterError(code: "missing", message: "That file is no longer there.", details: nil))
      return
    }
    guard let presenter = Self.topViewController() else {
      result(FlutterError(code: "no-window", message: "Nothing to present from.", details: nil))
      return
    }

    // An export that was already waiting cannot be answered any more; the
    // picker on screen is the only one the user can see.
    finish(nil)
    pending = result

    let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    picker.delegate = self
    // The Dart side named the file; the picker shows that name and lets it be
    // changed, which is the whole point of asking.
    presenter.present(picker, animated: true)
  }

  /// The name it ended up with, or nil for a dismissal. Answers the call once
  /// and once only — `documentPickerWasCancelled` also arrives after a pick on
  /// some iOS versions.
  private func finish(_ name: String?) {
    guard let result = pending else { return }
    pending = nil
    result(name)
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    finish(urls.first?.lastPathComponent ?? "")
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(nil)
  }

  /// Whatever is actually on screen, so the picker opens over the settings
  /// sheet the export was started from rather than behind it.
  private static func topViewController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
      ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}
