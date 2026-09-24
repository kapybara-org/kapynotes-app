import Cocoa
import FlutterMacOS
import Sparkle

/// Backs the `kapynotes/updater` channel: Sparkle, driven so that a release
/// downloads in the background and installs with one click.
///
/// Sparkle's own scheduler stays off (`SUEnableAutomaticChecks` in
/// Info.plist), because it puts its update panel on screen the moment it finds
/// something. Dart decides when there is a release, from the manifest, and
/// asks for it here. A background check with automatic downloads allowed runs
/// Sparkle's automatic driver: it downloads the release, checks its EdDSA and
/// code signatures, and prepares the installer, all without a window. Then it
/// offers `immediateInstallationBlock`, which is the whole of the "Update and
/// restart" button — Sparkle installs and relaunches, and shows nothing.
///
/// Answering `true` there takes the reminder away from Sparkle, which would
/// otherwise nag about the update after a week of not quitting. The release
/// still installs whenever the app quits, whether or not the button was used.
///
/// The one path that does show Sparkle's own window is a release that cannot
/// install silently — an app bundle the user may not write to, say. Then
/// Sparkle asks for permission in its usual panel, which is the right thing
/// for it to do.
final class AppUpdater: NSObject, SPUUpdaterDelegate {
  static let channelName = "kapynotes/updater"

  static func register(with messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    let updater = AppUpdater(channel: channel)
    channel.setMethodCallHandler { call, result in
      updater.handle(call, result)
    }
    return channel
  }

  /// The versions Sparkle's own panel lets a user skip. A background check
  /// never offers those again, and this app has no Skip button of its own:
  /// asking for a release here is asking for it.
  private static let skippedVersionKeys = [
    "SUSkippedVersion",
    "SUSkippedMajorVersion",
    "SUSkippedMajorSubreleaseVersion",
  ]

  private let channel: FlutterMethodChannel
  private var feedURL: String?

  /// Made on the first request rather than at launch, so an app that is
  /// already current never starts Sparkle at all.
  private var updater: SPUUpdater?
  private var userDriver: SPUStandardUserDriver?

  /// Set once a release is downloaded and its installer is waiting. Sparkle
  /// allows it to be invoked again if a quit was cancelled.
  private var installNow: (() -> Void)?
  private var readyItem: SUAppcastItem?

  private init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "download":
      guard
        let arguments = call.arguments as? [String: Any],
        let feed = arguments["feedUrl"] as? String,
        URL(string: feed) != nil
      else {
        result(
          FlutterError(code: "bad-arguments", message: "Expected a feed URL.", details: nil)
        )
        return
      }
      feedURL = feed
      result(download())

    case "install":
      guard let installNow else {
        result(false)
        return
      }
      installNow()
      result(true)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Starts a download, and answers with where things stand. Anything that
  /// happens after that arrives as an event.
  private func download() -> [String: Any] {
    if let item = readyItem, installNow != nil {
      return details(of: item, status: "ready")
    }

    let updater: SPUUpdater
    do {
      updater = try started()
    } catch {
      return ["status": "error", "message": error.localizedDescription]
    }

    // A background check does nothing at all while Sparkle is busy — with an
    // earlier download, or a window of its own — so say so, and let the end
    // of that session report instead.
    if updater.sessionInProgress {
      return ["status": "busy"]
    }

    for key in Self.skippedVersionKeys {
      UserDefaults.standard.removeObject(forKey: key)
    }
    // Without automatic downloads a background check is the scheduled kind,
    // which shows Sparkle's panel as soon as it finds the release. It also
    // needs `SUAllowsAutomaticUpdates` in Info.plist: with automatic checks
    // off, Sparkle refuses to turn this on otherwise.
    updater.automaticallyDownloadsUpdates = true
    guard updater.automaticallyDownloadsUpdates else {
      return [
        "status": "error",
        "message": "Sparkle will not download automatically; is SUAllowsAutomaticUpdates set?",
      ]
    }
    updater.checkForUpdatesInBackground()
    return ["status": "started"]
  }

  private func started() throws -> SPUUpdater {
    if let updater {
      return updater
    }
    let driver = SPUStandardUserDriver(hostBundle: Bundle.main, delegate: nil)
    let updater = SPUUpdater(
      hostBundle: Bundle.main,
      applicationBundle: Bundle.main,
      userDriver: driver,
      delegate: self
    )
    try updater.start()
    self.userDriver = driver
    self.updater = updater
    return updater
  }

  private func details(of item: SUAppcastItem, status: String? = nil) -> [String: Any] {
    var details: [String: Any] = [
      "version": item.displayVersionString,
      "build": item.versionString,
    ]
    if let status {
      details["status"] = status
    }
    return details
  }

  private func send(_ event: String, _ details: [String: Any] = [:]) {
    channel.invokeMethod(event, arguments: details)
  }

  // MARK: SPUUpdaterDelegate

  func feedURLString(for updater: SPUUpdater) -> String? {
    feedURL
  }

  func updater(
    _ updater: SPUUpdater,
    willInstallUpdateOnQuit item: SUAppcastItem,
    immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
  ) -> Bool {
    readyItem = item
    installNow = immediateInstallHandler
    send("ready", details(of: item))
    return true
  }

  func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
    send("notFound")
  }

  func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
    send("failed", ["message": error.localizedDescription])
  }

  func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
    // "No update" ends a cycle this way too, after the call above has
    // already said so.
    let error = error as NSError
    if error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue) {
      return
    }
    send("failed", ["message": error.localizedDescription])
  }

  func updater(
    _ updater: SPUUpdater,
    didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
    error: Error?
  ) {
    var details: [String: Any] = [:]
    if let error {
      details["message"] = error.localizedDescription
    }
    send("finished", details)
  }
}
