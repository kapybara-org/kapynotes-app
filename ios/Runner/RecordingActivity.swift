import ActivityKit
import Flutter
import UIKit

/// A voice recording's Live Activity, on the Lock Screen and in the Dynamic
/// Island: the `kapynotes/recording_controls` channel on the iPhone, for
/// lib/audio/recording_controls.dart. The extension draws it, in
/// RecordingLiveActivity.swift.
///
/// The `audio` background mode is what keeps the recorder going with the
/// screen off; this keeps the recording in view meanwhile, with Pause or
/// Resume, and Stop, from iOS 17. Below iOS 16.1 there are no Live
/// Activities, and everything here answers and does nothing.
final class RecordingActivity {
  static let shared = RecordingActivity()

  /// The engine a press on the activity goes to, once there is one.
  private(set) var channel: FlutterMethodChannel?

  /// What ActivityKit has been asked to do, one after another, in the order
  /// Dart asked: each call is asynchronous, and an update must never land
  /// after the end that followed it.
  private var queue: Task<Void, Never>?

  private init() {}

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "kapynotes/recording_controls", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      switch call.method {
      case "prepare":
        result(nil)
      case "show":
        let arguments = call.arguments as? [String: Any] ?? [:]
        self.show(
          elapsed: ((arguments["elapsedMs"] as? NSNumber)?.doubleValue ?? 0) / 1000,
          paused: arguments["paused"] as? Bool ?? false,
          interrupted: arguments["interrupted"] as? Bool ?? false,
          phrase: arguments["phrase"] as? String,
          heard: arguments["heard"] as? String
        ) { refusal in
          result(refusal.map { FlutterError(code: "unavailable", message: $0, details: nil) })
        }
      case "hide":
        self.hide()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
    // A new run of the app has nothing recording yet, so an activity still
    // up was left by one that ended without warning.
    hide()
  }

  /// Starts the activity, or brings it up to date, and answers with why
  /// ActivityKit would not start it, or nil.
  ///
  /// `phrase` and `heard` come only while live translation is on and the
  /// person lets its words onto the Lock Screen. An update carrying them is
  /// as quiet as every other: no alert, so the Dynamic Island never opens by
  /// itself for a new phrase.
  private func show(
    elapsed: TimeInterval, paused: Bool, interrupted: Bool, phrase: String?, heard: String?,
    answer: @escaping (String?) -> Void
  ) {
    guard #available(iOS 16.1, *) else { return answer(nil) }
    let state = RecordingAttributes.ContentState(
      startedAt: Date().addingTimeInterval(-elapsed),
      elapsed: elapsed,
      paused: paused,
      interrupted: interrupted,
      phrase: phrase,
      heard: heard)
    enqueue {
      if let activity = Activity<RecordingAttributes>.activities.first {
        await RecordingActivity.update(activity, to: state)
        answer(nil)
      } else {
        answer(RecordingActivity.start(state))
      }
    }
  }

  func hide() {
    guard #available(iOS 16.1, *) else { return }
    enqueue { await RecordingActivity.endAll() }
  }

  /// The app is going: swiped away from the app switcher while it records in
  /// the background. The recorder closes its file on the way out, and the
  /// activity goes with the app rather than counting on with nothing behind
  /// it. The wait is the moment both of those need.
  func endBeforeExit() {
    guard #available(iOS 16.1, *), !Activity<RecordingAttributes>.activities.isEmpty
    else { return }
    let ended = DispatchSemaphore(value: 0)
    Task.detached {
      await RecordingActivity.endAll()
      ended.signal()
    }
    _ = ended.wait(timeout: .now() + 2)
  }

  private func enqueue(_ work: @escaping () async -> Void) {
    let previous = queue
    queue = Task { @MainActor in
      await previous?.value
      await work()
    }
  }

  /// Nil once started, else why not: Live Activities switched off for the
  /// app in Settings, or too many already up. The recording carries on all
  /// the same, and Dart says why in the log.
  @available(iOS 16.1, *)
  private static func start(_ state: RecordingAttributes.ContentState) -> String? {
    do {
      if #available(iOS 16.2, *) {
        _ = try Activity.request(
          attributes: RecordingAttributes(),
          content: ActivityContent(state: state, staleDate: nil))
      } else {
        _ = try Activity.request(attributes: RecordingAttributes(), contentState: state)
      }
      return nil
    } catch {
      return "no Live Activity for the recording: \(error)"
    }
  }

  @available(iOS 16.1, *)
  private static func update(
    _ activity: Activity<RecordingAttributes>, to state: RecordingAttributes.ContentState
  ) async {
    if #available(iOS 16.2, *) {
      await activity.update(ActivityContent(state: state, staleDate: nil))
    } else {
      await activity.update(using: state)
    }
  }

  @available(iOS 16.1, *)
  private static func endAll() async {
    for activity in Activity<RecordingAttributes>.activities {
      if #available(iOS 16.2, *) {
        await activity.end(nil, dismissalPolicy: .immediate)
      } else {
        await activity.end(using: nil, dismissalPolicy: .immediate)
      }
    }
  }
}

/// A press on the Live Activity, from RecordingAttributes.swift's intents,
/// which the system performs here in the app. It goes to Dart, and the
/// activity goes when nothing is recording to take it: the app had no engine
/// yet, or Dart answered that there is no recording.
enum RecordingCommands {
  @MainActor
  static func send(_ command: String) async {
    guard let channel = RecordingActivity.shared.channel else {
      RecordingActivity.shared.hide()
      return
    }
    let handled = await withCheckedContinuation { continuation in
      channel.invokeMethod(command, arguments: nil) { result in
        continuation.resume(returning: result as? Bool == true)
      }
    }
    if !handled { RecordingActivity.shared.hide() }
  }
}
