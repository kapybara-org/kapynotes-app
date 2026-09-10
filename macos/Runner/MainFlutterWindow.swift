import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// Held for the window's lifetime: a channel whose only owner is a local
  /// stops answering as soon as `awakeFromNib` returns.
  private var loginItemChannel: FlutterMethodChannel?
  private var richClipboardChannel: FlutterMethodChannel?
  private var spellCheckChannel: FlutterMethodChannel?
  private var summariesChannel: FlutterMethodChannel?
  private var transcriptionChannel: FlutterMethodChannel?
  private var audioDecodeChannel: FlutterMethodChannel?
  private var windowMaterialChannel: FlutterMethodChannel?
  private var windowPinChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = KapyFlutterViewController()
    flutterViewController.backgroundColor = NSColor.clear

    // The desktop, blurred, behind everything Flutter paints. Flutter's
    // surfaces are opaque until the transparency setting thins them, and the
    // material thins with them: see WindowMaterial.
    let visualEffectView = NSVisualEffectView()
    visualEffectView.blendingMode = .behindWindow
    WindowMaterial.apply(glass: false, amount: 0, to: visualEffectView)

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
    richClipboardChannel = RichClipboard.register(
      with: flutterViewController.engine.binaryMessenger
    )
    spellCheckChannel = SpellCheck.register(
      with: flutterViewController.engine.binaryMessenger
    )
    summariesChannel = Summaries.register(
      with: flutterViewController.engine.binaryMessenger
    )
    transcriptionChannel = Transcription.register(
      with: flutterViewController.engine.binaryMessenger
    )
    audioDecodeChannel = AudioDecode.register(
      with: flutterViewController.engine.binaryMessenger
    )
    windowMaterialChannel = WindowMaterial.register(
      with: flutterViewController.engine.binaryMessenger,
      view: visualEffectView
    )
    windowPinChannel = WindowPin.register(
      with: flutterViewController.engine.binaryMessenger
    )

    super.awakeFromNib()
  }
}

/// The Flutter view, drawn in 8-bit colour.
///
/// On Apple silicon the engine gives its window surfaces the 64-bit
/// `BGRA10_XR` layout so that Display P3 colours survive to the screen. This
/// app paints nothing that needs them — every colour in the palette is an
/// sRGB value — and the price is real: eight bytes a pixel instead of four, on
/// every window-sized buffer the renderer keeps. At a Retina window of
/// ordinary size that is eighteen megabytes a surface rather than nine, times
/// the two or three the swapchain holds, plus the multisample target that
/// mirrors the window, plus the pool the driver keeps behind them.
///
/// There is no setting for this. The engine decides in a private
/// `enableWideGamut` accessor on the view controller and reads it through
/// `self`, so a subclass that answers the same selector answers first. The
/// engine's own screen-change path (`updateWideGamutForScreen`) also checks
/// this accessor before touching the view, so it does not switch the format
/// back when the window moves to a P3 display.
///
/// Because the accessor is private, it is not an override in Swift's eyes,
/// only in the runtime's. If a future engine renames it, this quietly stops
/// applying and the surfaces go back to wide gamut; nothing breaks. The
/// pixel format of the window's IOSurface (`vmmap`, look for `FlutterMacOS`)
/// is the way to check it still holds after an engine upgrade: `BGRA` means
/// this is in effect, `w40a` means it is not.
final class KapyFlutterViewController: FlutterViewController {
  @objc func enableWideGamut() -> Bool { false }

  /// Keeps the engine's accessibility tree on so dictation tools can write
  /// into the editor. Owned here because the engine's life is tied to this
  /// controller: `viewWillAppear` is where the engine is launched, and the
  /// tree can only be switched on after that.
  private lazy var accessibilityTree = AccessibilityTree(engine: engine)

  override func viewWillAppear() {
    super.viewWillAppear()
    accessibilityTree.enable()
    AccessibilityText.routeWritesToEngine()
  }
}
