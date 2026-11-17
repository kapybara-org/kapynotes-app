import Cocoa
import XCTest

@testable import Kapy_Notes

/// The text field's incremental update. The field and its editor are
/// stand-ins for the engine's `FlutterTextField` and `FlutterTextInputPlugin`,
/// with the engine's own `updateString:withSelection:`, editing in windows
/// that are never shown.
class AccessibilityTextMirrorTests: XCTestCase {
  // MARK: - The changed range

  private func assertChange(
    _ old: String, _ new: String, old expectedOld: NSRange, new expectedNew: NSRange,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let change = AccessibilityTextMirror.changedRanges(from: old as NSString, to: new as NSString)
    XCTAssertEqual(change.old, expectedOld, "range in the old text", file: file, line: line)
    XCTAssertEqual(change.new, expectedNew, "range in the new text", file: file, line: line)
    let result = (old as NSString).replacingCharacters(
      in: change.old, with: (new as NSString).substring(with: change.new))
    XCTAssertEqual(result as NSString, new as NSString, "the edit gives the new text", file: file, line: line)
  }

  private func range(_ location: Int, _ length: Int) -> NSRange {
    NSRange(location: location, length: length)
  }

  func testEqualTextsChangeNothing() {
    assertChange("", "", old: range(0, 0), new: range(0, 0))
    assertChange("a note", "a note", old: range(6, 0), new: range(6, 0))
  }

  func testEmptyTexts() {
    assertChange("", "abc", old: range(0, 0), new: range(0, 3))
    assertChange("abc", "", old: range(0, 3), new: range(0, 0))
  }

  func testEditsAtTheStart() {
    assertChange("note", "Xnote", old: range(0, 0), new: range(0, 1))
    assertChange("note", "ote", old: range(0, 1), new: range(0, 0))
    assertChange("note", "vote", old: range(0, 1), new: range(0, 1))
  }

  func testEditsAtTheEnd() {
    assertChange("note", "notes", old: range(4, 0), new: range(4, 1))
    assertChange("notes", "note", old: range(4, 1), new: range(4, 0))
    assertChange("note", "nota", old: range(3, 1), new: range(3, 1))
  }

  func testEditInTheMiddle() {
    assertChange("one\ntwo", "one\nnew\ntwo", old: range(4, 0), new: range(4, 4))
  }

  func testWholeReplacement() {
    assertChange("abc", "xyz", old: range(0, 3), new: range(0, 3))
  }

  func testRepeatedCharactersTakeTheLongestPrefix() {
    assertChange("aaa", "aaaa", old: range(3, 0), new: range(3, 1))
  }

  func testSurrogatePairsAreNeverSplit() {
    // U+1F600 and U+1F601 share their high surrogate.
    assertChange("a😀b", "a😁b", old: range(1, 2), new: range(1, 2))
    // U+1F600 and U+1FA00 share their low surrogate.
    assertChange("a😀b", "a\u{1FA00}b", old: range(1, 2), new: range(1, 2))
    assertChange("ab", "a😀b", old: range(1, 0), new: range(1, 2))
    assertChange("a😀b", "ab", old: range(1, 2), new: range(1, 0))
  }

  func testCombiningMarksStayWithTheirCharacter() {
    assertChange("ae\u{301}b", "ae\u{300}b", old: range(1, 2), new: range(1, 2))
    assertChange("ae", "ae\u{301}", old: range(1, 1), new: range(1, 2))
    assertChange("ae\u{301}", "ae", old: range(1, 2), new: range(1, 1))
    assertChange("a\u{301}b", "e\u{301}b", old: range(0, 2), new: range(0, 2))
  }

  func testCanonicallyEquivalentTextsStillDiffer() {
    assertChange("caf\u{E9}", "cafe\u{301}", old: range(3, 1), new: range(3, 2))
  }

  func testEmojiSequencesAreReplacedWhole() {
    // Flags are pairs of regional indicators; these two share the first.
    assertChange("a🇺🇸b", "a🇺🇦b", old: range(1, 4), new: range(1, 4))
    // People joined by zero-width joiners.
    assertChange("👨‍👩‍👧", "👨‍👩‍👦", old: range(0, 8), new: range(0, 8))
  }

  func testFindsEditsAcrossChunksOfALongText() {
    let note = String(repeating: "A line of the note.\n", count: 400)
    let length = (note as NSString).length
    for at in [0, 1, 1023, 1024, 1025, 4000, length - 1025, length - 1024, length - 1, length] {
      let typed = (note as NSString).replacingCharacters(in: range(at, 0), with: "x")
      assertChange(note, typed, old: range(at, 0), new: range(at, 1))
      guard at < length else { continue }
      let deleted = (note as NSString).replacingCharacters(in: range(at, 1), with: "")
      assertChange(note, deleted, old: range(at, 1), new: range(at, 0))
    }
  }

  // MARK: - The field

  /// Stands in for the engine's `FlutterTextInputPlugin`: the field's editor,
  /// which reports whether an input method is composing.
  private final class StandInPlugin: NSTextView {
    var composing = false
    override func hasMarkedText() -> Bool { composing }
  }

  private final class StandInCell: NSTextFieldCell {
    var editor: NSTextView?
    override func fieldEditor(for controlView: NSView) -> NSTextView? { editor }
  }

  /// Stands in for the engine's `FlutterTextField`, with
  /// `updateString:withSelection:` as the engine has it.
  private class StandInField: NSTextField {
    var editor: NSTextView { (cell as! StandInCell).editor! }
    var text: NSString { editor.textStorage!.mutableString }
    private(set) var engineUpdates = 0

    @objc dynamic func updateString(_ string: NSString, withSelection selection: NSRange) {
      engineUpdates += 1
      if !(stringValue as NSString).isEqual(to: string as String) {
        stringValue = string as String
      }
      if editor.selectedRange() != selection {
        editor.setSelectedRange(selection)
      }
    }
  }

  /// The same, with the incremental update installed.
  private final class PatchedField: StandInField {
    override func updateString(_ string: NSString, withSelection selection: NSRange) {
      super.updateString(string, withSelection: selection)
    }
  }

  /// Sends `updateString:withSelection:` through the Objective-C runtime,
  /// as the engine's plugin does. A call from Swift could go straight to the
  /// stand-in's own implementation and skip the one installed in its place.
  private func update(_ field: StandInField, _ string: NSString, _ selection: NSRange) {
    let selector = NSSelectorFromString("updateString:withSelection:")
    typealias Update = @convention(c) (AnyObject, Selector, NSString, NSRange) -> Void
    unsafeBitCast(field.method(for: selector), to: Update.self)(field, selector, string, selection)
  }

  override class func setUp() {
    super.setUp()
    _ = NSApplication.shared
    AccessibilityTextMirror.install(on: PatchedField.self, editor: StandInPlugin.self)
  }

  private var hiddenWindows: [NSWindow] = []

  override func tearDown() {
    hiddenWindows.forEach { $0.close() }
    hiddenWindows = []
    super.tearDown()
  }

  /// Starts `field` editing `text` with `editor`, in a window of its own
  /// that is never ordered in, as the engine's field edits while the editor
  /// has focus.
  private func startEditing(_ field: StandInField, text: String, editor: NSTextView = StandInPlugin()) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 40), styleMask: .borderless,
      backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    hiddenWindows.append(window)
    let cell = StandInCell(textCell: text)
    cell.isEditable = true
    cell.isSelectable = true
    cell.editor = editor
    field.cell = cell
    field.frame = NSRect(x: 0, y: 0, width: 400, height: 24)
    window.contentView?.addSubview(field)
    XCTAssertTrue(window.makeFirstResponder(field))
    XCTAssertTrue(field.currentEditor() === editor)
    XCTAssertFalse(window.isVisible)
  }

  func testTheFieldEndsAsTheEnginesMethodLeavesIt() {
    let note = "Groceries\nmilk 2\neggs 12\n"
    let engine = StandInField()
    let patched = PatchedField()
    startEditing(engine, text: note)
    startEditing(patched, text: note)

    var text = note as NSString
    var steps: [(text: NSString, selection: NSRange)] = []
    func type(_ replacement: String, over replaced: NSRange) {
      text = text.replacingCharacters(in: replaced, with: replacement) as NSString
      steps.append((text, range(replaced.location + (replacement as NSString).length, 0)))
    }
    func select(_ selection: NSRange) { steps.append((text, selection)) }

    type("x", over: range(16, 0))
    type("", over: range(16, 1))
    select(range(3, 0))
    select(range(10, 4))
    type("oat milk", over: range(10, 4))
    type("😀", over: range(0, 0))
    type("😁", over: range(0, 2))
    type("\u{1FA00}", over: range(0, 2))
    type("e\u{301}", over: range(text.length, 0))
    type("\u{E9}", over: range(text.length - 2, 2))
    type("\nbread\nbutter", over: range(11, 0))
    type("", over: range(0, text.length))
    type(note, over: range(0, 0))

    for (step, expected) in steps.enumerated() {
      update(engine, expected.text, expected.selection)
      update(patched, expected.text, expected.selection)
      let label = "step \(step)"
      XCTAssertEqual(patched.text, expected.text, label)
      XCTAssertEqual(patched.text, engine.text, label)
      XCTAssertEqual(patched.editor.selectedRange(), expected.selection, label)
      XCTAssertEqual(patched.editor.selectedRange(), engine.editor.selectedRange(), label)
      XCTAssertEqual(
        patched.cell?.accessibilityValue() as? NSString, engine.cell?.accessibilityValue() as? NSString, label)
      XCTAssertEqual(patched.accessibilityValue() as? NSString, engine.accessibilityValue() as? NSString, label)
      XCTAssertEqual(patched.stringValue as NSString, engine.stringValue as NSString, label)
      XCTAssertEqual(patched.stringValue as NSString, expected.text, label)
    }
    XCTAssertEqual(patched.engineUpdates, 0)
    XCTAssertEqual(engine.engineUpdates, steps.count)
  }

  func testComposingRunsTheEnginesMethod() {
    let field = PatchedField()
    let plugin = StandInPlugin()
    startEditing(field, text: "kana", editor: plugin)
    plugin.composing = true
    update(field, "kanaか", range(5, 0))
    XCTAssertEqual(field.engineUpdates, 1)
    XCTAssertEqual(field.text, "kanaか")
    plugin.composing = false
    update(field, "kana漢字", range(6, 0))
    XCTAssertEqual(field.engineUpdates, 1)
    XCTAssertEqual(field.text, "kana漢字")
    XCTAssertEqual(field.editor.selectedRange(), range(6, 0))
  }

  func testAFieldThatIsNotEditingRunsTheEnginesMethod() {
    let field = PatchedField()
    let cell = StandInCell(textCell: "note")
    cell.editor = StandInPlugin()
    field.cell = cell
    update(field, "notes", range(5, 0))
    XCTAssertEqual(field.engineUpdates, 1)
    XCTAssertEqual(field.stringValue, "notes")
  }

  func testAnotherEditorRunsTheEnginesMethod() {
    let field = PatchedField()
    startEditing(field, text: "note", editor: NSTextView())
    update(field, "notes", range(5, 0))
    XCTAssertEqual(field.engineUpdates, 1)
    XCTAssertEqual(field.text, "notes")
  }

  func testAClassWithoutTheMethodIsLeftAsItWas() {
    final class Plain: NSTextField {}
    AccessibilityTextMirror.install(on: Plain.self, editor: StandInPlugin.self)
    XCTAssertFalse(Plain.instancesRespond(to: NSSelectorFromString("updateString:withSelection:")))
  }
}
