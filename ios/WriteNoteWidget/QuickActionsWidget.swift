import SwiftUI
import WidgetKit

/// The wide widget: all three actions at once, side by side.
///
/// Three tap targets on one widget rather than three widgets on the Home
/// Screen. Each column is a `Link`, which is how a widget offers more than
/// the single destination `widgetURL` allows, and each one opens the app on
/// exactly the URL the square widget would have opened it on.
struct QuickActionsEntry: TimelineEntry {
  let date: Date
}

struct QuickActionsProvider: TimelineProvider {
  func placeholder(in context: Context) -> QuickActionsEntry {
    QuickActionsEntry(date: .now)
  }

  func getSnapshot(in context: Context, completion: @escaping (QuickActionsEntry) -> Void) {
    completion(QuickActionsEntry(date: .now))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<QuickActionsEntry>) -> Void)
  {
    completion(Timeline(entries: [QuickActionsEntry(date: .now)], policy: .never))
  }
}

struct QuickActionsView: View {
  var body: some View {
    HStack(spacing: 0) {
      ForEach(QuickAction.allCases, id: \.self) { action in
        Link(destination: action.url) {
          QuickActionTile(action: action)
        }
      }
    }
    .containerBackground(widgetBackground, for: .widget)
  }
}

/// One column: a full-height third of the widget, edge to edge, so that the
/// whole of it is the tap target and not just the disc and the word in the
/// middle of it. Write sits on the primary disc, the other two on the tonal.
struct QuickActionTile: View {
  let action: QuickAction

  var body: some View {
    let primary = action == .write
    VStack(spacing: 10) {
      QuickActionDisc(
        action: action,
        fill: primary ? widgetPrimary : widgetTonal,
        ink: primary ? widgetOnPrimary : widgetOnTonal)
      Text(action.title)
        .font(Figtree.semibold(15))
        .foregroundStyle(widgetText)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(height: 20)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
  }
}

struct QuickActionsWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: "com.kapybara.kapynotes.quick-actions",
      provider: QuickActionsProvider()
    ) { _ in
      QuickActionsView()
    }
    .configurationDisplayName("Write, Dictate, Capture")
    .description("All three, one tap each, into the note you were writing.")
    .supportedFamilies([.systemMedium])
    .contentMarginsDisabled()
  }
}
