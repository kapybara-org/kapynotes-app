// Presses the Kapy Notes menu bar icon through accessibility, as VoiceOver
// does, and checks that the panel opens, that its tabs and field are in the
// panel's own window where they are drawn, that a press on Tasks switches to
// it, and that a second press on the icon closes the panel. It posts no key or
// mouse event, so nothing can reach another app.
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

func frame(_ element: AXUIElement) -> CGRect {
  var origin = CGPoint.zero
  var size = CGSize.zero
  if let value = attribute(element, kAXPositionAttribute) { AXValueGetValue(value as! AXValue, .cgPoint, &origin) }
  if let value = attribute(element, kAXSizeAttribute) { AXValueGetValue(value as! AXValue, .cgSize, &size) }
  return CGRect(origin: origin, size: size)
}

/// The panel is the app's one window 360 points wide.
func panel() -> AXUIElement? {
  let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
  return windows.first { abs(frame($0).width - 360) < 1 }
}

func panelIsOpen() -> Bool { panel() != nil }

/// The first element under [root] whose label, value or placeholder is [text].
func find(_ text: String, in root: AXUIElement, depth: Int = 0) -> AXUIElement? {
  let names = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXPlaceholderValueAttribute]
  if names.contains(where: { (attribute(root, $0) as? String)?.contains(text) == true }) { return root }
  guard depth < 40 else { return nil }
  for child in attribute(root, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
    if let found = find(text, in: child, depth: depth + 1) { return found }
  }
  return nil
}

/// [text] in the panel's window and inside its frame, and in no other window.
func inPanel(_ text: String) -> AXUIElement? {
  guard let window = panel() else { return nil }
  let others = (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).filter { $0 != window }
  guard let element = find(text, in: window),
        frame(window).insetBy(dx: -1, dy: -1).contains(frame(element)),
        !others.contains(where: { find(text, in: $0) != nil })
  else { return nil }
  return element
}

func icon() -> AXUIElement? {
  guard let bar = attribute(app, "AXExtrasMenuBar") else { return nil }
  return (attribute(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement])?.first
}

guard AXIsProcessTrusted() else { finish("FAIL this process has no accessibility access", 2) }
// What VoiceOver sets on the app it reads; the engine builds its tree then.
AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
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

var tasks: AXUIElement?
guard waitFor(5, { tasks = inPanel("Tasks"); return tasks != nil && inPanel("Write a note") != nil }),
      let tasksTab = tasks
else { finish("FAIL the panel's tabs and field are not in its window", 1) }
print("PRESS Tasks at \(frame(tasksTab)) in the panel at \(frame(panel()!))")
guard AXUIElementPerformAction(tasksTab, kAXPressAction as CFString) == .success else {
  finish("FAIL the Tasks tab refused the press", 1)
}
guard waitFor(3, { inPanel("Add a task") != nil }) else { finish("FAIL a press on Tasks did not switch to it", 1) }
print("PRESS a press on Tasks switched to it")

guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
  finish("FAIL the icon refused the second press", 1)
}
guard waitFor(3, { !panelIsOpen() }) else { finish("FAIL a second press did not close the panel", 1) }
finish("PASS a press opens the panel, its contents are usable, and a second press closes it", 0)
