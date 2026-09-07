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
    HStack(spacing: 10) {
      ForEach(QuickAction.allCases, id: \.self) { action in
        Link(destination: action.url) {
          QuickActionTile(action: action)
        }
      }
    }
    .foregroundStyle(ink)
    .containerBackground(paper, for: .widget)
  }
}

/// One column. It fills its share of the row so that the whole of it is the
/// tap target, not just the glyph and the word in the middle of it.
struct QuickActionTile: View {
  let action: QuickAction

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: action.symbol)
        .font(.system(size: 26, weight: .regular))
      Text(action.title)
        .font(.system(size: 14, weight: .semibold, design: .rounded))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
  }
}
