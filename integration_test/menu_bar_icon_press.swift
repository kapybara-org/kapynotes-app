// Presses the Kapy Notes menu bar icon through accessibility, as VoiceOver
// does, and checks that the panel opens and that a second press closes it. It
// posts no key or mouse event, so nothing can reach another app.
//
// Run against a build of integration_test/menu_bar_panel_test.dart made with
// --dart-define=MENUBAR_DRIVEN=true, from a process that already has
// accessibility access:
//
//   swift integration_test/menu_bar_icon_press.swift <pid> <done-flag>
//
// <done-flag> is menubar-driven-done in the app's temp directory, which for a
// sandboxed build is ~/Library/Containers/<bundle id>/Data/tmp/.
import ApplicationServices
import Foundation

let pid = pid_t(CommandLine.arguments[1])!
let flag = CommandLine.arguments[2]

func finish(_ message: String, _ code: Int32) -> Never {
  print("PRESS \(message)")
  FileManager.default.createFile(atPath: flag, contents: nil)
  exit(code)
}

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
  var value: AnyObject?
  return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

/// Polls for up to [seconds], letting the app's run loop go on meanwhile.
func waitFor(_ seconds: Double, _ condition: () -> Bool) -> Bool {
  let end = Date().addingTimeInterval(seconds)
  while Date() < end {
    if condition() { return true }
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
  }
  return condition()
}

let app = AXUIElementCreateApplication(pid)

/// The panel is the app's one window 360 points wide.
func panelIsOpen() -> Bool {
  let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
  return windows.contains { window in
    guard let value = attribute(window, kAXSizeAttribute) else { return false }
    var size = CGSize.zero
    AXValueGetValue(value as! AXValue, .cgSize, &size)
    return abs(size.width - 360) < 1
  }
}

func icon() -> AXUIElement? {
  guard let bar = attribute(app, "AXExtrasMenuBar") else { return nil }
  return (attribute(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement])?.first
}

guard AXIsProcessTrusted() else { finish("FAIL this process has no accessibility access", 2) }
var found: AXUIElement?
guard waitFor(10, { found = icon(); return found != nil }), let item = found else {
  finish("FAIL the app shows no menu bar icon", 1)
}
let label = attribute(item, kAXDescriptionAttribute) as? String ?? ""
let actions: [String] = {
  var names: CFArray?
  AXUIElementCopyActionNames(item, &names)
  return names as? [String] ?? []
}()
print("PRESS icon label=\"\(label)\" actions=\(actions)")
guard label == "Kapy Notes" else { finish("FAIL the icon has no accessibility label", 1) }
guard !panelIsOpen() else { finish("FAIL the panel was open before any press", 1) }

guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
  finish("FAIL the icon refused the press", 1)
}
guard waitFor(3, panelIsOpen) else { finish("FAIL a press did not open the panel", 1) }
print("PRESS the panel opened")

guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
  finish("FAIL the icon refused the second press", 1)
}
guard waitFor(3, { !panelIsOpen() }) else { finish("FAIL a second press did not close the panel", 1) }
finish("PASS a press opens the panel and a second one closes it", 0)
