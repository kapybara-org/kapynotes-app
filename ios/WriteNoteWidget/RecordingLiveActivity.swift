import ActivityKit
import SwiftUI
import WidgetKit

/// Where a press on the Live Activity goes in the extension: nowhere. The
/// system performs a Live Activity's intent in the app; this only lets the
/// intents in RecordingAttributes.swift compile here too.
enum RecordingCommands {
  static func send(_ command: String) async {}
}

/// A tap anywhere but a button: the note being recorded into, opened by
/// QuickCapture.swift in the Runner target.
private let recordingURL = URL(string: "kapynotes://recording")!

/// The clay the app records in, and what sits on it.
let recordingClay = dynamicColor(light: 0xD0663B, dark: 0xCF7A57)
private let recordingOnClay = dynamicColor(light: 0xFCFAF4, dark: 0x1C1A17)
/// The quieter disc beside Stop: Pause, or Resume.
private let recordingTonal = dynamicColor(light: 0xECE7DC, dark: 0x34302A)

/// The Dynamic Island is always black, so its colours never change.
private let islandClay = Color(red: 0xCF / 255, green: 0x7A / 255, blue: 0x57 / 255)
private let islandOnClay = Color(red: 0x1C / 255, green: 0x1A / 255, blue: 0x17 / 255)
private let islandTonal = Color(red: 0x2C / 255, green: 0x2A / 255, blue: 0x26 / 255)
private let islandGrey = Color(red: 0x8A / 255, green: 0x84 / 255, blue: 0x78 / 255)

/// A voice recording carrying on away from the app, on the Lock Screen and
/// in the Dynamic Island: the board "Recording away from the app", 1DX9-1.
/// Its buttons need iOS 17; iOS 16 shows the same card without them.
@available(iOS 16.1, *)
struct RecordingLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: RecordingAttributes.self) { context in
      RecordingCard(state: context.state)
        .activityBackgroundTint(widgetBackground)
        .activitySystemActionForegroundColor(widgetText)
        .widgetURL(recordingURL)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          RecordingIslandStatus(state: context.state)
        }
        DynamicIslandExpandedRegion(.trailing) {
          RecordingIslandTime(state: context.state, size: 28)
        }
        DynamicIslandExpandedRegion(.bottom) {
          RecordingIslandFooter(state: context.state)
        }
      } compactLeading: {
        RecordingMic(state: context.state, size: 18)
      } compactTrailing: {
        RecordingIslandTime(state: context.state, size: 15)
          .frame(width: 44, alignment: .trailing)
      } minimal: {
        RecordingMic(state: context.state, size: 18)
      }
      .widgetURL(recordingURL)
      .keylineTint(islandClay)
    }
  }
}

@available(iOS 16.1, *)
extension RecordingAttributes.ContentState {
  var status: LocalizedStringKey {
    if interrupted { return "Recording interrupted" }
    return paused ? "Recording paused" : "Recording"
  }
}

/// The Lock Screen's card. The board draws it dark while recording and light
/// while paused; it follows the phone's own appearance.
@available(iOS 16.1, *)
struct RecordingCard: View {
  let state: RecordingAttributes.ContentState

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        RecordingDot(recording: state.recording)
        Text(state.status)
          .font(WidgetFace.semibold(15))
          .foregroundStyle(widgetText)
        Spacer(minLength: 8)
        Text("Kapy Notes")
          .font(WidgetFace.regular(13))
          .foregroundStyle(widgetTextSecondary)
      }
      HStack(spacing: 12) {
        RecordingTime(state: state)
          .font(WidgetFace.semibold(34))
          .tracking(-0.5)
          .foregroundStyle(state.recording ? widgetText : widgetTextSecondary)
        Spacer(minLength: 8)
        if #available(iOS 17.0, *) {
          RecordingButtons(state: state, tonal: recordingTonal, onTonal: widgetText, clay: recordingClay, onClay: recordingOnClay)
        }
      }
    }
    .padding(EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 18))
  }
}

/// How long the recording is, as m:ss: counting by itself while it records,
/// standing still while it does not.
@available(iOS 16.1, *)
struct RecordingTime: View {
  let state: RecordingAttributes.ContentState

  var body: some View {
    Group {
      if state.recording {
        // Bounded an hour out, past the app's thirty-minute cap, because the
        // text takes the width of the longest time it could ever show.
        Text(
          timerInterval: state.startedAt...state.startedAt.addingTimeInterval(3600),
          countsDown: false,
          showsHours: false)
      } else {
        Text(Self.format(state.elapsed))
      }
    }
    .monospacedDigit()
    .lineLimit(1)
  }

  static func format(_ elapsed: TimeInterval) -> String {
    let seconds = max(0, Int(elapsed))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}

/// Filled clay while it records, an empty ring while it stands still.
struct RecordingDot: View {
  let recording: Bool

  var body: some View {
    Group {
      if recording {
        Circle().fill(recordingClay)
      } else {
        Circle().strokeBorder(widgetTextSecondary, lineWidth: 1.5)
      }
    }
    .frame(width: 8, height: 8)
  }
}

/// The microphone, not a dot, so that it never reads as the system's own
/// orange microphone light. Grey while the recording stands still.
@available(iOS 16.1, *)
struct RecordingMic: View {
  let state: RecordingAttributes.ContentState
  let size: CGFloat

  var body: some View {
    Image("Mic01")
      .renderingMode(.template)
      .resizable()
      .frame(width: size, height: size)
      .foregroundStyle(state.recording ? islandClay : islandGrey)
  }
}

/// White while it records, grey while it stands still.
@available(iOS 16.1, *)
struct RecordingIslandTime: View {
  let state: RecordingAttributes.ContentState
  let size: CGFloat

  var body: some View {
    RecordingTime(state: state)
      .font(WidgetFace.semibold(size))
      .foregroundStyle(state.recording ? Color.white : islandGrey)
  }
}

@available(iOS 16.1, *)
struct RecordingIslandStatus: View {
  let state: RecordingAttributes.ContentState

  var body: some View {
    HStack(spacing: 8) {
      RecordingMic(state: state, size: 22)
      Text(state.status)
        .font(WidgetFace.semibold(15))
        .foregroundStyle(Color.white)
        .lineLimit(1)
    }
    .padding(.leading, 6)
  }
}

@available(iOS 16.1, *)
struct RecordingIslandFooter: View {
  let state: RecordingAttributes.ContentState

  var body: some View {
    HStack(spacing: 12) {
      Text("Kapy Notes")
        .font(WidgetFace.regular(13))
        .foregroundStyle(islandGrey)
      Spacer(minLength: 8)
      if #available(iOS 17.0, *) {
        RecordingButtons(state: state, tonal: islandTonal, onTonal: .white, clay: islandClay, onClay: islandOnClay)
      }
    }
    .padding(.horizontal, 6)
  }
}

/// Pause or Resume, and Stop, each performed in the app without unlocking.
@available(iOS 17.0, *)
struct RecordingButtons: View {
  let state: RecordingAttributes.ContentState
  let tonal: Color
  let onTonal: Color
  let clay: Color
  let onClay: Color

  var body: some View {
    HStack(spacing: 12) {
      if state.recording {
        Button(intent: PauseRecordingIntent()) {
          RecordingDisc(glyph: "Pause", label: "Pause", fill: tonal, ink: onTonal)
        }
      } else {
        Button(intent: ResumeRecordingIntent()) {
          RecordingDisc(glyph: "Play", label: "Resume", fill: tonal, ink: onTonal)
        }
      }
      Button(intent: StopRecordingIntent()) {
        RecordingDisc(glyph: "Stop", label: "Stop", fill: clay, ink: onClay)
      }
    }
    .buttonStyle(.plain)
  }
}

struct RecordingDisc: View {
  let glyph: String
  let label: LocalizedStringKey
  let fill: Color
  let ink: Color

  var body: some View {
    Image(glyph)
      .renderingMode(.template)
      .resizable()
      .frame(width: 20, height: 20)
      .foregroundStyle(ink)
      .frame(width: 44, height: 44)
      .background(Circle().fill(fill))
      .accessibilityLabel(Text(label))
  }
}
