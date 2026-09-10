import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var richClipboardChannel: FlutterMethodChannel?
  private var summariesChannel: FlutterMethodChannel?
  private var transcriptionChannel: FlutterMethodChannel?
  private var audioDecodeChannel: FlutterMethodChannel?
  private var systemRegionChannel: FlutterMethodChannel?
  private var fileExportChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    QuickCapture.shared.register(with: engineBridge.applicationRegistrar.messenger())
    richClipboardChannel = RichClipboard.register(
      with: engineBridge.applicationRegistrar.messenger()
    )
    summariesChannel = Summaries.register(
      with: engineBridge.applicationRegistrar.messenger()
    )
    transcriptionChannel = Transcription.register(
      with: engineBridge.applicationRegistrar.messenger()
    )
    audioDecodeChannel = AudioDecode.register(
      with: engineBridge.applicationRegistrar.messenger()
    )
    systemRegionChannel = SystemRegion.register(
      with: engineBridge.applicationRegistrar.messenger()
    )
    fileExportChannel = FileExport.register(
      with: engineBridge.applicationRegistrar.messenger()
    )
  }
}
