import Cocoa
import FlutterMacOS
import XCTest

class RunnerTests: XCTestCase {

  /// Reading `spellingPanel` makes AppKit create the Spelling and Grammar,
  /// Substitutions and Languages panels together, hidden, and they stay in
  /// `NSApp.windows` from then on. A reopen with no visible window must not
  /// order them front along with the notes window.
  func testReopenWithNoVisibleWindowLeavesSystemPanelsHidden() {
    let spellChecker = NSSpellChecker.shared
    _ = spellChecker.spellingPanel
    XCTAssertFalse(spellChecker.spellingPanel.isVisible)
    XCTAssertFalse(spellChecker.substitutionsPanel.isVisible)

    let delegate = NSApp.delegate as? NSApplicationDelegate
    XCTAssertNotNil(delegate)
    let handled = delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)

    XCTAssertEqual(handled, true)
    XCTAssertFalse(spellChecker.spellingPanel.isVisible)
    XCTAssertFalse(spellChecker.substitutionsPanel.isVisible)
  }

}
