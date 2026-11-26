import AppIntents
import SwiftUI
import WidgetKit

/// The square widget: one action, chosen by whoever placed it.
///
/// Nothing on it changes, so nothing about it needs refreshing — the only
/// thing that can change is which action it is, and that is a configuration,
/// not a timeline.
///
/// Showing no note text is the deliberate part. A preview of what somebody
/// wrote would have to be shared out of the app, kept current against a
/// refresh budget, and shown on a locked phone to whoever is holding it. The
/// action alone costs none of that.
@available(iOS 17.0, *)
struct QuickActionEntry: TimelineEntry {
  let date: Date
  let action: QuickAction
}

@available(iOS 17.0, *)
struct QuickActionProvider: AppIntentTimelineProvider {
  func placeholder(in context: Context) -> QuickActionEntry {
    QuickActionEntry(date: .now, action: .write)
  }

  func snapshot(for configuration: SelectQuickActionIntent, in context: Context) async
    -> QuickActionEntry
  {
    QuickActionEntry(date: .now, action: configuration.action.action)
  }

  func timeline(for configuration: SelectQuickActionIntent, in context: Context) async
    -> Timeline<QuickActionEntry>
  {
    Timeline(
      entries: [QuickActionEntry(date: .now, action: configuration.action.action)],
      policy: .never)
  }
}

@available(iOS 17.0, *)
struct QuickActionView: View {
  @Environment(\.widgetFamily) private var family

  let action: QuickAction

  var body: some View {
    content.widgetURL(action.url)
  }

  @ViewBuilder private var content: some View {
    switch family {
    case .accessoryCircular: QuickActionCircular(action: action)
    case .accessoryRectangular: QuickActionRectangular(action: action)
    default: QuickActionSmall(action: action)
    }
  }
}

/// The Home Screen square: the disc at the top, and along the bottom the
/// action and the note it works on.
@available(iOS 17.0, *)
struct QuickActionSmall: View {
  let action: QuickAction

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      QuickActionDisc(action: action, fill: widgetPrimary, ink: widgetOnPrimary)
      Spacer(minLength: 0)
      Text(action.title)
        .font(WidgetFace.semibold(17))
        .foregroundStyle(widgetText)
        .frame(height: 22)
      Text(QuickAction.lastNote)
        .font(WidgetFace.regular(13))
        .foregroundStyle(widgetTextSecondary)
        .frame(height: 18)
    }
    .lineLimit(1)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .containerBackground(widgetBackground, for: .widget)
  }
}

/// The Lock Screen pair. iOS draws them vibrant, from the wallpaper, so they
/// set no colour of their own and take no background but the one it draws.
@available(iOS 17.0, *)
struct QuickActionCircular: View {
  let action: QuickAction

  var body: some View {
    ZStack {
      AccessoryWidgetBackground()
      Image(action.glyph, label: Text(action.title))
        .renderingMode(.template)
        .resizable()
        .frame(width: 28, height: 28)
    }
    .containerBackground(.clear, for: .widget)
  }
}

@available(iOS 17.0, *)
struct QuickActionRectangular: View {
  let action: QuickAction

  var body: some View {
    HStack(spacing: 10) {
      Image(decorative: action.glyph)
        .renderingMode(.template)
        .resizable()
        .frame(width: 24, height: 24)
      VStack(alignment: .leading, spacing: 0) {
        Text(action.title)
          .font(WidgetFace.semibold(16))
          .frame(height: 20)
        Text(QuickAction.lastNote)
          .font(WidgetFace.regular(13))
          .foregroundStyle(.secondary)
          .frame(height: 18)
      }
      .lineLimit(1)
      Spacer(minLength: 0)
    }
    .containerBackground(.clear, for: .widget)
  }
}

/// Configurable since 1.14. The kind is the one this widget shipped with as
/// Write-only, and must stay that way: it is the identity the Home Screen
/// files an already-placed widget under, and changing it would leave those
/// widgets behind. The intent's default is Write for the same reason.
@available(iOS 17.0, *)
struct WriteNoteWidget: Widget {
  var body: some WidgetConfiguration {
    AppIntentConfiguration(
      kind: "com.kapybara.kapynotes.write-note",
      intent: SelectQuickActionIntent.self,
      provider: QuickActionProvider()
    ) { entry in
      QuickActionView(action: entry.action)
    }
    .configurationDisplayName("Quick Action")
    .description("Write, dictate or capture. Long-press to choose which.")
    .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
  }
}

/// The same three actions as controls: offered in Control Centre, as Lock
/// Screen buttons, and on the Action button. `OpenURLIntent` carries the URL
/// through, so a control reaches the app saying what a widget would have said.
@available(iOS 18.0, *)
struct WriteNoteControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    // The kind this control shipped with, kept for the same reason the
    // widget's is.
    StaticControlConfiguration(kind: "com.kapybara.kapynotes.write-control") {
      ControlWidgetButton(action: OpenURLIntent(QuickAction.write.url)) {
        Label(QuickAction.write.title, systemImage: QuickAction.write.symbol)
      }
    }
    .displayName("Write")
    .description(QuickAction.write.summary)
  }
}

@available(iOS 18.0, *)
struct DictateControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "com.kapybara.kapynotes.dictate-control") {
      ControlWidgetButton(action: OpenURLIntent(QuickAction.dictate.url)) {
        Label(QuickAction.dictate.title, systemImage: QuickAction.dictate.symbol)
      }
    }
    .displayName("Dictate")
    .description(QuickAction.dictate.summary)
  }
}

@available(iOS 18.0, *)
struct CaptureControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "com.kapybara.kapynotes.capture-control") {
      ControlWidgetButton(action: OpenURLIntent(QuickAction.capture.url)) {
        Label(QuickAction.capture.title, systemImage: QuickAction.capture.symbol)
      }
    }
    .displayName("Capture")
    .description(QuickAction.capture.summary)
  }
}
