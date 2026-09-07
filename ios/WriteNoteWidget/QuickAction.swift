import AppIntents
import SwiftUI
import UIKit

/// The three things a tap on a widget can ask the app for.
///
/// Each is a URL and nothing else. The widget knows no note, holds no text,
/// and reads no store: it says which of three doors the user came through and
/// lets the app decide what is behind it. That is what keeps every widget
/// here free to draw once and never refresh, and keeps a locked phone from
/// showing anybody's writing.
enum QuickAction: String, CaseIterable {
  case write
  case dictate
  case capture

  /// The word on the widget, and the name of the action everywhere else.
  var title: LocalizedStringResource {
    switch self {
    case .write: return "Write"
    case .dictate: return "Dictate"
    case .capture: return "Capture"
    }
  }

  /// What the widget gallery, the Lock Screen and Control Centre say it does.
  var summary: LocalizedStringResource {
    switch self {
    case .write: return "Carry on the note you were writing, ready to type."
    case .dictate: return "Carry on that note, and start talking into it."
    case .capture: return "Carry on that note, and add a picture to it."
    }
  }

  /// SF Symbols, which is what a Lock Screen tint and Control Centre both
  /// expect to be handed.
  var symbol: String {
    switch self {
    case .write: return "square.and.pencil"
    case .dictate: return "mic"
    case .capture: return "camera"
    }
  }

  /// What the app is opened on. The host is the whole message — see
  /// QuickCapture.swift in the Runner target, which turns it back into a
  /// `LaunchIntent` for Dart.
  var url: URL {
    URL(string: "kapynotes://\(rawValue)")!
  }
}

/// The paper and ink of the editor these open onto, so a tap looks like the
/// app unfolding rather than replacing something else. Matches
/// InstantCaptureApp in lib/ui/instant_capture.dart.
let paper = Color(
  uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(red: 0.141, green: 0.125, blue: 0.094, alpha: 1)
      : UIColor(red: 0.969, green: 0.941, blue: 0.871, alpha: 1)
  })

let ink = Color(
  uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(red: 0.929, green: 0.886, blue: 0.792, alpha: 1)
      : UIColor(red: 0.149, green: 0.212, blue: 0.290, alpha: 1)
  })

/// The same three, as something the widget editor can offer in a menu.
///
/// A separate type from [QuickAction] only because `AppEnum` drags display
/// representations and a localisation story in with it, and the widget's own
/// drawing code wants none of that.
enum QuickActionChoice: String, AppEnum {
  case write
  case dictate
  case capture

  static var typeDisplayRepresentation: TypeDisplayRepresentation = "Action"

  static var caseDisplayRepresentations: [QuickActionChoice: DisplayRepresentation] = [
    .write: DisplayRepresentation(
      title: "Write", subtitle: "Carry on the note you were writing.",
      image: .init(systemName: "square.and.pencil")),
    .dictate: DisplayRepresentation(
      title: "Dictate", subtitle: "Carry on that note, and start talking.",
      image: .init(systemName: "mic")),
    .capture: DisplayRepresentation(
      title: "Capture", subtitle: "Carry on that note, and add a picture.",
      image: .init(systemName: "camera")),
  ]

  var action: QuickAction { QuickAction(rawValue: rawValue) ?? .write }
}

/// What the user edits when they long-press the square widget and choose
/// **Edit Widget**.
///
/// The default is Write, which is what the widget did before it could be
/// configured at all — so a widget already on somebody's Home Screen keeps
/// doing exactly what they put it there to do.
struct SelectQuickActionIntent: WidgetConfigurationIntent {
  static var title: LocalizedStringResource = "Quick Action"
  static var description = IntentDescription("Choose what one tap does.")

  @Parameter(title: "Action", default: .write)
  var action: QuickActionChoice

  init() {}

  init(action: QuickActionChoice) {
    self.action = action
  }
}
