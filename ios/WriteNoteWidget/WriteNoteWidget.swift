import AppIntents
import SwiftUI
import UIKit
import WidgetKit

/// What every surface here opens. The app reads it as "carry on writing"
/// rather than "new note" — see QuickCapture.swift in the Runner target.
private let writeURL = URL(string: "kapynotes://write")!

/// The paper and ink of the editor this opens onto, so the tap looks like the
/// app unfolding rather than replacing something else. Matches
/// InstantCaptureApp in lib/ui/instant_capture.dart.
private let paper = Color(
  uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(red: 0.141, green: 0.125, blue: 0.094, alpha: 1)
      : UIColor(red: 0.969, green: 0.941, blue: 0.871, alpha: 1)
  })

private let ink = Color(
  uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(red: 0.929, green: 0.886, blue: 0.792, alpha: 1)
      : UIColor(red: 0.149, green: 0.212, blue: 0.290, alpha: 1)
  })

struct WriteNoteEntry: TimelineEntry {
  let date: Date
}

/// Nothing on this widget changes, so nothing about it needs refreshing.
///
/// Showing no note text is the deliberate part. A preview of what somebody
/// wrote would have to be shared out of the app, kept current against a
/// refresh budget, and shown on a locked phone to whoever is holding it. The
/// action alone costs none of that.
struct WriteNoteProvider: TimelineProvider {
  func placeholder(in context: Context) -> WriteNoteEntry {
    WriteNoteEntry(date: .now)
  }

  func getSnapshot(in context: Context, completion: @escaping (WriteNoteEntry) -> Void) {
    completion(WriteNoteEntry(date: .now))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<WriteNoteEntry>) -> Void) {
    completion(Timeline(entries: [WriteNoteEntry(date: .now)], policy: .never))
  }
}

struct WriteNoteView: View {
  @Environment(\.widgetFamily) private var family

  var body: some View {
    content.widgetURL(writeURL)
  }

  @ViewBuilder private var content: some View {
    switch family {
    // The Lock Screen pair. Both are tinted by the system, so they set no
    // colour of their own and take no background but the one it draws.
    case .accessoryCircular:
      ZStack {
        AccessoryWidgetBackground()
        Image(systemName: "square.and.pencil")
          .font(.system(size: 20, weight: .medium))
      }
      .containerBackground(.clear, for: .widget)

    case .accessoryRectangular:
      HStack(spacing: 6) {
        Image(systemName: "square.and.pencil")
        Text("Write")
          .font(.headline)
        Spacer(minLength: 0)
      }
      .containerBackground(.clear, for: .widget)

    default:
      VStack(spacing: 8) {
        Image(systemName: "square.and.pencil")
          .font(.system(size: 30, weight: .regular))
        Text("Write")
          .font(.system(size: 16, weight: .semibold, design: .rounded))
      }
      .foregroundStyle(ink)
      .containerBackground(paper, for: .widget)
    }
  }
}

struct WriteNoteWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: "com.kapybara.kapynotes.write-note",
      provider: WriteNoteProvider()
    ) { _ in
      WriteNoteView()
    }
    .configurationDisplayName("Write")
    .description("Carry on the note you were writing, ready to type.")
    .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
  }
}

/// The same action as a control: offered in Control Centre, as a Lock Screen
/// button, and on the Action button. `OpenURLIntent` carries the URL through,
/// so a control reaches the app saying the same thing the widget does.
@available(iOS 18.0, *)
struct WriteNoteControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "com.kapybara.kapynotes.write-control") {
      ControlWidgetButton(action: OpenURLIntent(writeURL)) {
        Label("Write", systemImage: "square.and.pencil")
      }
    }
    .displayName("Write")
    .description("Carry on the note you were writing.")
  }
}

@main
struct WriteNoteWidgetBundle: WidgetBundle {
  var body: some Widget {
    WriteNoteWidget()
    if #available(iOS 18.0, *) {
      WriteNoteControl()
    }
  }
}
