import Cocoa
import ObjectiveC
import os

/// Keeps the accessibility text field's copy of the note in step by editing
/// only what changed.
///
/// With the accessibility tree on (see AccessibilityTree), the engine's input
/// plugin hands the whole text it holds to the `FlutterTextField` that stands
/// for the editor, after every keystroke and every editing state Flutter
/// sends: `updateTextAndSelection` calls the field's
/// `updateString:withSelection:`, which compares the text with the field's
/// and, if they differ at all, replaces every character with
/// `setStringValue:`. That runs on the main thread before the frame, and it
/// costs in proportion to the length of the text, not of the change: 8–12 ms
/// for 4,000 characters and 120–135 ms for 250,000, in a profile build on
/// Apple silicon.
///
/// The replacement finds where the field editor's text and the new text stop
/// agreeing from each end, widens that to whole characters, and replaces only
/// the range in between, in the field editor's own storage; then it sets the
/// selection as the engine's method does. Text and selection come out the
/// same as the engine's. Where that can't be relied on (the field is not
/// editing, its editor is not the engine's plugin, or an input method is
/// composing) the engine's own method runs.
///
/// The classes are internal to the engine and reached by name. One that has
/// been renamed logs a fault and leaves the app as it was: slower, not broken.
enum AccessibilityTextMirror {
  private static let log = Logger(subsystem: "com.kapybara.kapynotes", category: "accessibility")
  private static let update = NSSelectorFromString("updateString:withSelection:")
  private static var installed = false

  /// Safe to call more than once; only the first call does anything.
  static func editIncrementally() {
    if installed { return }
    installed = true
    guard let field = NSClassFromString("FlutterTextField"),
      let plugin = NSClassFromString("FlutterTextInputPlugin")
    else {
      log.fault("FlutterTextField or FlutterTextInputPlugin is not in this engine; the text field is still rewritten whole")
      return
    }
    install(on: field, editor: plugin)
  }

  /// Gives `fieldClass` an `updateString:withSelection:` that edits
  /// incrementally while the field's editor is an `editorClass`, and
  /// otherwise calls the method it replaces.
  static func install(on fieldClass: AnyClass, editor editorClass: AnyClass) {
    guard let method = class_getInstanceMethod(fieldClass, update) else {
      log.fault(
        "\(String(describing: fieldClass), privacy: .public) has no updateString:withSelection:; the text field is still rewritten whole")
      return
    }
    typealias Update = @convention(c) (NSTextField, Selector, NSString, NSRange) -> Void
    let original = unsafeBitCast(method_getImplementation(method), to: Update.self)
    let incremental: @convention(block) (NSTextField, NSString, NSRange) -> Void = { field, string, selection in
      guard let editor = field.currentEditor() as? NSTextView, editor.isKind(of: editorClass),
        !editor.hasMarkedText(), let storage = editor.textStorage
      else {
        original(field, update, string, selection)
        return
      }
      let change = changedRanges(from: storage.mutableString, to: string)
      if change.old.length > 0 || change.new.length > 0 {
        editor.replaceCharacters(in: change.old, with: string.substring(with: change.new))
      }
      if editor.selectedRange() != selection {
        editor.setSelectedRange(selection)
      }
    }
    let imp = imp_implementationWithBlock(incremental)
    if !class_addMethod(fieldClass, update, imp, method_getTypeEncoding(method)) {
      method_setImplementation(method, imp)
    }
  }

  /// The range of `old` to replace, and the range of `new` to replace it
  /// with, that turn `old` into `new`: what lies between their longest
  /// common prefix and longest common suffix, widened to whole composed
  /// characters in both, so that neither range splits a surrogate pair or a
  /// character from its combining marks. Both are empty when the strings are
  /// equal, unit for unit.
  static func changedRanges(from old: NSString, to new: NSString) -> (old: NSRange, new: NSRange) {
    let oldLength = old.length
    let newLength = new.length
    let shorter = min(oldLength, newLength)
    var start = matching(old, new, upTo: shorter, fromEnd: false)
    while true {
      var widened = start
      if widened < oldLength {
        widened = min(widened, old.rangeOfComposedCharacterSequence(at: widened).location)
      }
      if widened < newLength {
        widened = min(widened, new.rangeOfComposedCharacterSequence(at: widened).location)
      }
      if widened == start { break }
      start = widened
    }
    var suffix = matching(old, new, upTo: shorter - start, fromEnd: true)
    while suffix > 0 {
      var widened = suffix
      let oldCharacter = old.rangeOfComposedCharacterSequence(at: oldLength - suffix)
      if oldCharacter.location < oldLength - suffix {
        widened = min(widened, oldLength - NSMaxRange(oldCharacter))
      }
      let newCharacter = new.rangeOfComposedCharacterSequence(at: newLength - suffix)
      if newCharacter.location < newLength - suffix {
        widened = min(widened, newLength - NSMaxRange(newCharacter))
      }
      if widened == suffix { break }
      suffix = widened
    }
    return (
      NSRange(location: start, length: oldLength - suffix - start),
      NSRange(location: start, length: newLength - suffix - start)
    )
  }

  /// How many UTF-16 units `a` and `b` have in common at their starts, or
  /// at their ends, counting no further than `limit`.
  private static func matching(_ a: NSString, _ b: NSString, upTo limit: Int, fromEnd: Bool) -> Int {
    let chunk = 1024
    var unitsA = [unichar](repeating: 0, count: chunk)
    var unitsB = [unichar](repeating: 0, count: chunk)
    var matched = 0
    while matched < limit {
      let count = min(chunk, limit - matched)
      a.getCharacters(&unitsA, range: NSRange(location: fromEnd ? a.length - matched - count : matched, length: count))
      b.getCharacters(&unitsB, range: NSRange(location: fromEnd ? b.length - matched - count : matched, length: count))
      if memcmp(unitsA, unitsB, count * MemoryLayout<unichar>.size) != 0 {
        var same = 0
        if fromEnd {
          while unitsA[count - 1 - same] == unitsB[count - 1 - same] { same += 1 }
        } else {
          while unitsA[same] == unitsB[same] { same += 1 }
        }
        return matched + same
      }
      matched += count
    }
    return limit
  }
}
