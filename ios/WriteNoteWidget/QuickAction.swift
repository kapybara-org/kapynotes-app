import AppIntents
import SwiftUI
import UIKit
import WidgetKit

/// The three things a tap on a widget can ask the app for.
///
/// Each is a URL and nothing else. The widget knows no note, holds no text,
/// and reads no store: it says which of three doors the user came through and
/// lets the app decide what is behind it. That is what keeps every widget
/// here free to draw once and never refresh, and keeps a locked phone from
/// showing anybody's writing.
@available(iOS 17.0, *)
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

  /// What every action works on, under its name on the square and
  /// rectangular widgets. Each one carries on the note being written, which
  /// is also why Write keeps the pen: in the app, + makes a new note.
  static let lastNote: LocalizedStringResource = "Last note"

  /// What the widget gallery, the Lock Screen and Control Centre say it does.
  var summary: LocalizedStringResource {
    switch self {
    case .write: return "Carry on the note you were writing, ready to type."
    case .dictate: return "Carry on that note, and start talking into it."
    case .capture: return "Carry on that note, and add a picture to it."
    }
  }

  /// SF Symbols, for the controls: Control Centre, the Lock Screen's buttons
  /// and the Action button draw these themselves.
  var symbol: String {
    switch self {
    case .write: return "square.and.pencil"
    case .dictate: return "mic"
    case .capture: return "camera"
    }
  }

  /// The app's own glyph for it, a template image in this extension's asset
  /// catalog, drawn in whatever colour the widget gives it.
  var glyph: String {
    switch self {
    case .write: return "PencilEdit02"
    case .dictate: return "Mic01"
    case .capture: return "Camera"
    }
  }

  /// What the app is opened on. The host is the whole message — see
  /// QuickCapture.swift in the Runner target, which turns it back into a
  /// `LaunchIntent` for Dart.
  var url: URL {
    URL(string: "kapynotes://\(rawValue)")!
  }
}

/// Phone · v2's colours, light and dark, so a tap looks like the app it opens
/// unfolding rather than something else replacing it.
let widgetBackground = dynamicColor(light: 0xFCFAF4, dark: 0x23201C)
let widgetText = dynamicColor(light: 0x2A2620, dark: 0xE2DCCF)
let widgetTextSecondary = dynamicColor(light: 0x6F695C, dark: 0xA29A8A)
/// The round sage button: Write's, and the one on every single-action widget.
let widgetPrimary = dynamicColor(light: 0x56703C, dark: 0x7D9468)
let widgetOnPrimary = dynamicColor(light: 0xFCFAF4, dark: 0x1C1A17)
/// The quieter disc Dictate and Capture sit on beside Write.
let widgetTonal = dynamicColor(light: 0xE6ECDB, dark: 0x2E3828)
let widgetOnTonal = dynamicColor(light: 0x445A2F, dark: 0xC2D6AC)

func dynamicColor(light: UInt32, dark: UInt32) -> Color {
  Color(
    uiColor: UIColor { traits in
      let rgb = traits.userInterfaceStyle == .dark ? dark : light
      return UIColor(
        red: CGFloat((rgb >> 16) & 0xFF) / 255,
        green: CGFloat((rgb >> 8) & 0xFF) / 255,
        blue: CGFloat(rgb & 0xFF) / 255,
        alpha: 1)
    })
}

/// Figtree, the app's own face. The extension carries its own two weights,
/// listed under UIAppFonts. Fixed sizes, because every line is drawn to fit
/// the widget's own size.
enum Figtree {
  static func semibold(_ size: CGFloat) -> Font { .custom("Figtree-SemiBold", fixedSize: size) }
  static func regular(_ size: CGFloat) -> Font { .custom("Figtree-Regular", fixedSize: size) }
}

/// One action's round button: one disc per tap, with nothing boxed around it.
/// In a tinted Home Screen the disc takes the tint and the glyph stays light.
@available(iOS 17.0, *)
struct QuickActionDisc: View {
  let action: QuickAction
  let fill: Color
  let ink: Color

  var body: some View {
    Circle()
      .fill(fill)
      .widgetAccentable()
      .frame(width: 56, height: 56)
      .overlay {
        Image(decorative: action.glyph)
          .renderingMode(.template)
          .resizable()
          .frame(width: 26, height: 26)
          .foregroundStyle(ink)
      }
  }
}

/// The same three, as something the widget editor can offer in a menu.
///
/// A separate type from [QuickAction] only because `AppEnum` drags display
/// representations and a localisation story in with it, and the widget's own
/// drawing code wants none of that.
@available(iOS 17.0, *)
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
@available(iOS 17.0, *)
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
