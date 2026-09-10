import Cocoa
import FlutterMacOS
import ObjectiveC
import os

/// Makes text written through the accessibility API reach the note.
///
/// With the accessibility tree on (see AccessibilityTree), the engine backs
/// the focused editor with a real `NSTextField` whose field editor is its own
/// input plugin, an `NSTextView`. A dictation tool that has found that field
/// writes its transcript by setting `AXSelectedText` on it, or replaces a
/// range, or sets the whole value. AppKit serves each of those by editing the
/// text view's storage directly. The words appear — the accessibility value
/// reports them, and the tool, reading it back, calls the paste a success and
/// puts the clipboard back the way it was — but nothing told the engine, so
/// nothing reached Flutter, the note was never changed, and the next update
/// the engine sends the field paints the old text back over them.
///
/// Keystrokes take a different road: the text view's `insertText:` is the
/// engine's override, which adds the text to its model and sends the new
/// editing state to Flutter. So that is where the accessibility writes are
/// sent. Each setter below is replaced on the engine's classes at runtime and
/// re-expressed as the `insertText:replacementRange:` it stands for; from
/// there it is a keystroke as far as the engine and the note are concerned.
///
/// The classes are internal to the engine and reached by name. A class that
/// has been renamed logs a fault and leaves the app as it was — the words go
/// missing as before, rather than the app going down.
enum AccessibilityText {
  private static let log = Logger(subsystem: "com.kapybara.kapynotes", category: "accessibility")

  /// Also to stderr, so a build run from a shell shows the route each write
  /// took; the unified log is not always readable from where one is looking.
  private static func trace(_ message: String) {
    log.debug("\(message, privacy: .public)")
    FileHandle.standardError.write(Data(("[AccessibilityText] " + message + "\n").utf8))
  }

  /// The engine's input plugin, an `NSTextView`, and the accessibility field
  /// it serves as the field editor of.
  private static let pluginClassName = "FlutterTextInputPlugin"
  private static let fieldClassName = "FlutterTextField"

  private static var installed = false

  /// Routes accessibility text writes through the engine's input path. Safe
  /// to call more than once; only the first call does anything.
  static func routeWritesToEngine() {
    if installed { return }
    installed = true
    guard let plugin = NSClassFromString(pluginClassName) else {
      log.fault(
        "\(pluginClassName, privacy: .public) is not in this engine; dictation into the note cannot be repaired")
      return
    }
    installPluginRoutes(on: plugin)
    if let field = NSClassFromString(fieldClassName) {
      installFieldRoutes(on: field)
    } else {
      log.fault("\(fieldClassName, privacy: .public) is not in this engine; only the field editor is covered")
    }
    log.notice("accessibility text writes routed through the engine")
  }

  // MARK: - The text view (field editor)

  private static func installPluginRoutes(on cls: AnyClass) {
    // AXSelectedText: replace the selection with the text.
    let selectedText: @convention(block) (NSTextView, String?) -> Void = { view, text in
      trace("AXSelectedText write, \(text?.count ?? 0) characters")
      view.insertText(text ?? "", replacementRange: view.selectedRange())
    }
    replace(cls, "setAccessibilitySelectedText:", types: "v@:@", with: selectedText)

    // AXValue: replace everything. Tools that cannot find a selection fall
    // back to writing the whole field.
    let value: @convention(block) (NSTextView, Any?) -> Void = { view, value in
      guard let text = value as? String else { return }
      trace("AXValue write, \(text.count) characters")
      view.insertText(text, replacementRange: NSRange(location: 0, length: (view.string as NSString).length))
    }
    replace(cls, "setAccessibilityValue:", types: "v@:@", with: value)

    // AXReplaceRangeWithText, the parameterised form Apple's own dictation
    // uses.
    let replaceRange: @convention(block) (NSTextView, NSRange, String?) -> Bool = { view, range, text in
      trace("AXReplaceRangeWithText, \(text?.count ?? 0) characters at \(range.location)")
      view.insertText(text ?? "", replacementRange: range)
      return true
    }
    replace(cls, "accessibilityReplaceRange:withText:", types: "B@:{_NSRange=QQ}@", with: replaceRange)

    // Edit › Paste sent to the field editor as first responder. The keyboard
    // shortcut reaches Flutter's own paste first and never lands here; a
    // menu-driven or tool-driven paste does, and would otherwise edit the
    // storage alone.
    let paste: @convention(block) (NSTextView, Any?) -> Void = { view, _ in
      guard let text = NSPasteboard.general.string(forType: .string) else { return }
      trace("paste: into field editor, \(text.count) characters")
      view.insertText(text, replacementRange: view.selectedRange())
    }
    replace(cls, "paste:", types: "v@:@", with: paste)
  }

  // MARK: - The text field the tools address

  /// AppKit forwards a text field's accessibility text writes to its field
  /// editor while it is editing. When it is not, the write would land in the
  /// field's own cell and go nowhere; so editing is begun first, which is
  /// what the engine does when the field is focused through accessibility.
  private static func installFieldRoutes(on cls: AnyClass) {
    let selectedText: @convention(block) (NSTextField, String?) -> Void = { field, text in
      guard let view = editor(of: field) else { return }
      trace("AXSelectedText write via text field, \(text?.count ?? 0) characters")
      view.insertText(text ?? "", replacementRange: view.selectedRange())
    }
    replace(cls, "setAccessibilitySelectedText:", types: "v@:@", with: selectedText)

    let value: @convention(block) (NSTextField, Any?) -> Void = { field, value in
      guard let text = value as? String, let view = editor(of: field) else { return }
      trace("AXValue write via text field, \(text.count) characters")
      view.insertText(text, replacementRange: NSRange(location: 0, length: (view.string as NSString).length))
    }
    replace(cls, "setAccessibilityValue:", types: "v@:@", with: value)

    let replaceRange: @convention(block) (NSTextField, NSRange, String?) -> Bool = { field, range, text in
      guard let view = editor(of: field) else { return false }
      trace("AXReplaceRangeWithText via text field, \(text?.count ?? 0) characters at \(range.location)")
      view.insertText(text ?? "", replacementRange: range)
      return true
    }
    replace(cls, "accessibilityReplaceRange:withText:", types: "B@:{_NSRange=QQ}@", with: replaceRange)
  }

  /// The field's editor, begun if it has not been; failing that, the
  /// engine's input plugin itself.
  ///
  /// `startEditing` is the engine's own method for making its plugin the
  /// field's current editor, and it is what the engine calls when the field
  /// is focused through accessibility. It does not take while the window is
  /// not key — the tools write after bringing their own window up, so that
  /// is a real case — and then the plugin is reached directly: it still
  /// holds the editing model, because the editor keeps its focus through a
  /// deactivation (see focus_hold.dart), and `insertText:` on it is the same
  /// road a keystroke takes. Both are internal, so presence is checked.
  private static func editor(of field: NSTextField) -> NSTextView? {
    if let view = field.currentEditor() as? NSTextView {
      trace("field editor already current")
      return view
    }
    let start = NSSelectorFromString("startEditing")
    if field.responds(to: start) {
      field.perform(start)
      if let view = field.currentEditor() as? NSTextView {
        trace("field editor begun")
        return view
      }
    }
    trace("no field editor; window=\(field.window != nil) key=\(field.window?.isKeyWindow ?? false)")
    return enginePlugin(near: field)
  }

  /// The engine's `FlutterTextInputPlugin`, found through the view controller
  /// hosting the field (or, for a field with no window, any Flutter window).
  private static func enginePlugin(near field: NSView) -> NSTextView? {
    let controllers = [field.window?.contentViewController]
      + NSApp.windows.map { $0.contentViewController }
    for case let controller as FlutterViewController in controllers.compactMap({ $0 }) {
      let engine = controller.engine
      let key = "textInputPlugin"
      guard engine.responds(to: NSSelectorFromString(key)) else { continue }
      if let plugin = engine.value(forKey: key) as? NSTextView {
        trace("using the engine plugin directly; selection=\(NSStringFromRange(plugin.selectedRange())) chars=\((plugin.string as NSString).length)")
        return plugin
      }
    }
    log.fault("no FlutterTextInputPlugin reachable; an accessibility write was dropped")
    return nil
  }

  // MARK: - Runtime

  /// Gives `cls` its own implementation of `name`, whether it had one (then
  /// replaced) or inherited it (then added).
  private static func replace(_ cls: AnyClass, _ name: String, types: String, with block: Any) {
    let selector = NSSelectorFromString(name)
    let imp = imp_implementationWithBlock(block)
    if class_addMethod(cls, selector, imp, types) { return }
    guard let method = class_getInstanceMethod(cls, selector) else {
      log.fault("could not install \(name, privacy: .public) on \(String(describing: cls), privacy: .public)")
      return
    }
    method_setImplementation(method, imp)
  }
}
