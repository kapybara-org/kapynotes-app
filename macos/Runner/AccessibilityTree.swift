import Cocoa
import FlutterMacOS
import os

/// Keeps the engine's accessibility tree switched on, so that anything which
/// writes text through the system's accessibility API finds a text field to
/// write into.
///
/// Dictation apps, text expanders and automation tools do not type into a
/// window. They ask the system for the focused accessibility element, check
/// that it is a text field, and set its selected text. When the focused
/// element is not a text field they give up and copy the words to the
/// clipboard instead, and nothing reports an error.
///
/// A native text view is a text field to the system for free. A Flutter
/// window is an opaque `AXGroup` until the engine builds its accessibility
/// tree, and the engine only builds it on request: it listens for AppKit's
/// `AXEnhancedUserInterface` notification, which VoiceOver sends and a
/// dictation tool does not, and it drops every semantics update the framework
/// sends until its own flag is set. Asking from Dart with
/// `SemanticsBinding.ensureSemantics` builds the tree on the Flutter side and
/// then has the engine throw it away, so the switch has to be thrown here.
///
/// Once the tree exists the engine backs each focused text field with a real
/// `NSTextField` whose field editor is the engine's own input plugin, so
/// setting `AXSelectedText` on it goes through the same `insertText:` path as
/// a keystroke and lands in the editor as typed text.
///
/// The flag is not in the engine's public headers. It is reached through
/// key-value coding, and its presence is checked first, so an engine that
/// renames it logs a fault and leaves the app running rather than crashing
/// it. Whether the bridge still holds after an engine upgrade is quick to
/// check: with the editor focused, the app's `AXFocusedUIElement` must be an
/// `AXTextField` (or `AXTextArea`) with a settable `AXSelectedText`, not an
/// `AXGroup`.
final class AccessibilityTree {
  private static let log = Logger(subsystem: "com.kapybara.kapynotes", category: "accessibility")

  /// The property the engine keeps its switch in. See `FlutterEngine_Internal.h`.
  private static let semanticsKey = "semanticsEnabled"
  private static let runningKey = "running"

  /// AppKit posts this when an assistive client sets `AXEnhancedUserInterface`
  /// on the application, and the engine turns its tree on or off with the
  /// flag's value. VoiceOver toggling off, or an automation tool that set the
  /// flag and cleared it on exit, would otherwise take the tree down with it.
  private static let enhancedUserInterfaceNotification = Notification.Name(
    "NSApplicationDidChangeAccessibilityEnhancedUserInterfaceNotification")

  private let engine: FlutterEngine
  private var observer: NSObjectProtocol?

  /// Watches for the tree being switched off for as long as this object
  /// lives. Nothing is switched on until `enable()` is called: the engine
  /// forwards the flag to the embedder only when it changes, and never
  /// re-sends it on launch, so setting it before the engine runs is lost.
  init(engine: FlutterEngine) {
    self.engine = engine
    observer = NotificationCenter.default.addObserver(
      forName: Self.enhancedUserInterfaceNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      // The engine observes the same notification. Observers run in the order
      // they registered, but that is not promised, so re-assert on the next
      // turn of the run loop rather than race its handler.
      DispatchQueue.main.async { self?.enable() }
    }
  }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  /// Whether the engine currently has its tree switched on. False for an
  /// engine that no longer has the flag, rather than an unknown-key exception.
  var isEnabled: Bool {
    guard engine.responds(to: NSSelectorFromString(Self.semanticsKey)) else { return false }
    return (engine.value(forKey: Self.semanticsKey) as? Bool) == true
  }

  /// Switches the tree on. Safe to call repeatedly; call it once the engine
  /// is running, which `FlutterViewController` does from `viewWillAppear`.
  func enable() {
    guard engine.responds(to: NSSelectorFromString("set\(Self.semanticsKey.capitalizedFirst):")) else {
      Self.log.fault(
        "FlutterEngine no longer exposes \(Self.semanticsKey, privacy: .public); dictation and other assistive tools cannot write into the app")
      return
    }
    // `running` is internal as well, so it is only consulted where it exists.
    // The controller launches the engine in `viewWillAppear`, before this.
    if engine.responds(to: NSSelectorFromString(Self.runningKey)),
      (engine.value(forKey: Self.runningKey) as? Bool) == false
    {
      Self.log.fault(
        "AccessibilityTree asked to enable semantics before the engine was running; the flag would not reach the embedder")
      return
    }
    if isEnabled { return }
    engine.setValue(true, forKey: Self.semanticsKey)
    if isEnabled {
      Self.log.notice("accessibility tree enabled")
    } else {
      Self.log.fault("FlutterEngine refused to enable its accessibility tree")
    }
  }
}

private extension String {
  var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
