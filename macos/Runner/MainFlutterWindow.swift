import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// Held for the window's lifetime: a channel whose only owner is a local
  /// stops answering as soon as `awakeFromNib` returns.
  private var loginItemChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    flutterViewController.backgroundColor = NSColor.clear

    // Keep the writing surface opaque in Flutter while allowing navigation
    // chrome to reveal a native, accessibility-aware macOS material beneath.
    let visualEffectView = NSVisualEffectView()
    visualEffectView.material = .underWindowBackground
    visualEffectView.blendingMode = .behindWindow
    visualEffectView.state = .followsWindowActiveState

    let hostViewController = NSViewController()
    hostViewController.view = visualEffectView
    hostViewController.addChild(flutterViewController)
    flutterViewController.view.translatesAutoresizingMaskIntoConstraints = false
    visualEffectView.addSubview(flutterViewController.view)
    NSLayoutConstraint.activate([
      flutterViewController.view.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
      flutterViewController.view.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
      flutterViewController.view.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
      flutterViewController.view.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
    ])

    let windowFrame = self.frame
    self.backgroundColor = NSColor.clear
    self.isOpaque = false
    self.titlebarAppearsTransparent = true
    self.contentViewController = hostViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    loginItemChannel = LoginItem.register(
      with: flutterViewController.engine.binaryMessenger
    )

    super.awakeFromNib()
  }
}
