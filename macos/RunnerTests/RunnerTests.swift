import Cocoa
import FlutterMacOS
import XCTest

@testable import Kapy_Notes

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

  /// The menu bar panel stands on a private engine switch. An engine without
  /// it must get no panel, so the icon's click falls back to the menu.
  func testMenuBarPanelNeedsTheEnginesMultiViewSwitch() {
    XCTAssertTrue(MenuBarPanel.isSupported(by: FlutterEngine.self))
    XCTAssertFalse(MenuBarPanel.isSupported(by: NSObject.self))
  }

  /// A switch that is no longer a BOOL would make key-value coding raise, so
  /// an engine like that gets no panel either.
  func testMenuBarPanelRefusesASwitchThatIsNotABool() {
    func engine(_ name: String, switchType: String) -> AnyClass {
      let engine: AnyClass = objc_allocateClassPair(NSObject.self, name, 0)!
      class_addIvar(engine, MenuBarPanel.multiViewIvar, 8, 3, switchType)
      objc_registerClassPair(engine)
      return engine
    }
    XCTAssertTrue(MenuBarPanel.isSupported(by: engine("KapyBoolEngine", switchType: "B")))
    XCTAssertFalse(MenuBarPanel.isSupported(by: engine("KapyObjectEngine", switchType: "@")))
  }

}
