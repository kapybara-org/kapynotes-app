import ActivityKit
import AppIntents
import Foundation

/// A voice recording, as its Live Activity shows it on the Lock Screen and in
/// the Dynamic Island. Compiled into both the app, which starts and updates
/// the activity, and this extension, which draws it.
///
/// Nothing about the note: a Lock Screen is no place to show what a note is
/// about, so the activity says "Kapy Notes" and no more.
@available(iOS 16.1, *)
struct RecordingAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    /// When the recording would have begun had it never stood still: the
    /// time counts up from here while it records.
    var startedAt: Date
    /// How long it is, which is what shows while it stands still.
    var elapsed: TimeInterval
    /// Somebody pressed Pause.
    var paused: Bool
    /// A call, or another app, took the microphone.
    var interrupted: Bool
    /// While live translation is on: the latest finished phrase in the other
    /// language, and what was heard, cut by Dart to 300 and 200 characters
    /// so the activity stays far inside ActivityKit's 4 KB. Optional, so a
    /// state encoded before they existed still decodes; nil draws today's
    /// card.
    var phrase: String?
    var heard: String?

    var recording: Bool { !paused && !interrupted }
  }
}

// The Live Activity's buttons, from iOS 17. The system performs a Live
// Activity's intent in the app, launching it in the background if it has to,
// and RecordingCommands takes each one to the recorder: the app's own, in
// RecordingActivity.swift, and a stand-in here in the extension, which never
// performs one.

@available(iOS 17.0, *)
struct PauseRecordingIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Pause recording"
  static let isDiscoverable = false

  func perform() async throws -> some IntentResult {
    await RecordingCommands.send("pause")
    return .result()
  }
}

@available(iOS 17.0, *)
struct ResumeRecordingIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Resume recording"
  static let isDiscoverable = false

  func perform() async throws -> some IntentResult {
    await RecordingCommands.send("resume")
    return .result()
  }
}

@available(iOS 17.0, *)
struct StopRecordingIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Stop recording"
  static let isDiscoverable = false

  func perform() async throws -> some IntentResult {
    await RecordingCommands.send("stop")
    return .result()
  }
}
