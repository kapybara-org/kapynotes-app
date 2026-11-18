import Cocoa
import FlutterMacOS

/// The panel under the menu bar icon: a second Flutter view on the app's own
/// engine, in a non-activating panel.
///
/// One engine means one isolate, so the panel writes notes and tasks through
/// the same store objects as the window. Everything it shows is Flutter; this
/// only places the panel, orders it in and out, and says when a click
/// elsewhere has closed it. See handoffs/KAPY-32/menubar-architecture.md.
final class MenuBarPanel: NSObject, NSWindowDelegate {
  /// The engine keeps a second view behind a private switch whose public
  /// setter asserts once any view exists, and the window's always exists
  /// first. Set directly, the window stays the implicit view and the panel
  /// gets the next id. An engine that renames it has no panel: the Dart side
  /// is told so, and a click on the icon opens the menu instead. So is one
  /// whose switch is no longer a BOOL, which key-value coding could not set.
  static let multiViewIvar = "_multiViewEnabled"

  static func isSupported(by engine: AnyClass = FlutterEngine.self) -> Bool {
    guard let ivar = class_getInstanceVariable(engine, multiViewIvar),
          let type = ivar_getTypeEncoding(ivar)
    else { return false }
    return ["B", "c"].contains(String(cString: type))
  }

  static let width: CGFloat = 360

  private let engine: FlutterEngine
  private let channel: FlutterMethodChannel
  private var panel: Panel?
  private var controller: FlutterViewController?
  private var monitors: [Any] = []
  private var takesKey = true

  init(engine: FlutterEngine) {
    self.engine = engine
    channel = FlutterMethodChannel(
      name: "kapynotes/menubar_panel",
      binaryMessenger: engine.binaryMessenger
    )
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "isSupported":
      result(Self.isSupported())
    case "isControlPressed":
      result(NSEvent.modifierFlags.contains(.control))
    case "show":
      guard Self.isSupported(), !NSScreen.screens.isEmpty else {
        result(nil)
        return
      }
      let (panel, viewId) = ensurePanel()
      takesKey = args["key"] as? Bool ?? true
      place(panel, height: args["height"] as? Double ?? 400)
      // In at alpha 0, then revealed once Flutter has drawn into it: with
      // every window off screen the engine draws nothing at all, so the
      // frame has to come after the panel is on screen, not before.
      panel.alphaValue = 0
      panel.orderFrontRegardless()
      result(viewId)
    case "reveal":
      guard let panel, panel.isVisible else {
        result(nil)
        return
      }
      panel.alphaValue = 1
      panel.invalidateShadow()
      if takesKey { panel.makeKey() }
      watchForClicksElsewhere()
      result(nil)
    case "resize":
      if let panel {
        var frame = panel.frame
        let height = args["height"] as? Double ?? frame.height
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
      }
      result(nil)
    case "hide":
      close()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func ensurePanel() -> (Panel, Int64) {
    if let panel, let controller { return (panel, controller.viewIdentifier) }
    engine.setValue(true, forKey: Self.multiViewIvar)
    let controller = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    controller.backgroundColor = .clear
    let panel = Panel(
      contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .popUpMenu
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    panel.contentViewController = controller
    panel.delegate = self
    self.panel = panel
    self.controller = controller
    return (panel, controller.viewIdentifier)
  }

  /// Under the app's own status item, centred on it and kept on its screen.
  /// The item is never under the notch, so neither is the panel.
  private func place(_ panel: Panel, height: Double) {
    let item = NSApp.windows.first { $0.className == "NSStatusBarWindow" }?.frame
    guard let screen = NSScreen.screens.first(where: { item.map($0.frame.intersects) ?? false })
      ?? NSScreen.main
      ?? NSScreen.screens.first
    else { return }
    let visible = screen.visibleFrame
    let anchor = item ?? NSRect(x: visible.maxX - 24, y: visible.maxY, width: 0, height: 0)
    let margin: CGFloat = 6
    let x = min(max(anchor.midX - Self.width / 2, visible.minX + margin), visible.maxX - Self.width - margin)
    let top = min(anchor.minY, visible.maxY) - margin
    panel.setFrame(NSRect(x: x, y: top - height, width: Self.width, height: height), display: false)
  }

  /// Any click outside the panel closes it, as a menu bar popover does,
  /// except one on the icon itself, which the icon toggles.
  private func watchForClicksElsewhere() {
    guard monitors.isEmpty else { return }
    let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
      self?.dismiss()
    }) {
      monitors.append(global)
    }
    if let local = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
      if let self, event.window !== self.panel, event.window?.className != "NSStatusBarWindow" {
        self.dismiss()
      }
      return event
    }) {
      monitors.append(local)
    }
  }

  func windowDidResignKey(_ notification: Notification) {
    if takesKey { dismiss() }
  }

  private func dismiss() {
    guard panel?.isVisible == true else { return }
    close()
    channel.invokeMethod("dismissed", arguments: nil)
  }

  private func close() {
    monitors.forEach(NSEvent.removeMonitor)
    monitors.removeAll()
    panel?.orderOut(nil)
  }

  private final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
  }
}
