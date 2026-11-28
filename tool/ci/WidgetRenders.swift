import SwiftUI
import UIKit

/// Draws the widgets in ios/WriteNoteWidget, every size in light and dark and
/// laid out as the Widgets · v2 boards lay them out, so that a reviewer can
/// hold each render against its board. tool/ci/ios_widget_renders.sh builds
/// this together with the widgets' own source and runs it on a simulator:
///
///   WidgetRenders <output directory> <the extension's Info.plist>
///
/// The views are the widgets' own. What iOS adds around a widget is drawn
/// here to match it: the container in the widget's background, with the Home
/// Screen's corners and 16 pt content margins (none on the medium widget,
/// which turns them off), and on the Lock Screen, which tints everything
/// from the wallpaper, white on the board's wallpaper colour.
///
/// It exits non-zero when a glyph, a font or a link isn't what the extension
/// ships, or when a render fails.
@main
struct WidgetRenders {
  @MainActor static func main() {
    let arguments = CommandLine.arguments
    let out = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let extensionInfo = URL(fileURLWithPath: arguments[2])

    checkFonts(listedIn: extensionInfo)
    for action in QuickAction.allCases {
      let glyph = UIImage(named: action.glyph)
      check(glyph != nil, "No \(action.glyph) glyph in the asset catalog")
      check(glyph?.renderingMode == .alwaysTemplate, "\(action.glyph) is not a template image")
    }
    check(
      QuickAction.allCases.map(\.url.absoluteString)
        == ["kapynotes://write", "kapynotes://dictate", "kapynotes://capture"],
      "The widgets no longer open kapynotes://write, dictate and capture, in that order")
    check(String(localized: QuickAction.lastNote) == "Last note", "The widgets don't say Last note")

    for scheme in [ColorScheme.light, .dark] {
      let mode = scheme == .dark ? "dark" : "light"
      for action in QuickAction.allCases {
        save(small(action), scheme, "small-\(action.rawValue)-\(mode)", to: out)
      }
      save(medium, scheme, "medium-\(mode)", to: out)
      save(homeBoard(scheme), scheme, "ios-\(mode)", to: out)
    }
    for action in QuickAction.allCases {
      save(onWallpaper(circular(action)), .dark, "lockscreen-circular-\(action.rawValue)", to: out)
      save(onWallpaper(rectangular(action)), .dark, "lockscreen-rectangular-\(action.rawValue)", to: out)
    }
    save(lockBoard, .dark, "ios-lockscreen", to: out)

    // A recording's Live Activity, as "Recording away from the app" (1DX9-1)
    // draws it: the Lock Screen's card in each state and appearance, and the
    // Dynamic Island's three sizes, around the extension's own views.
    for glyph in ["Mic01", "Pause", "Play", "Stop"] {
      check(UIImage(named: glyph)?.renderingMode == .alwaysTemplate, "\(glyph) is not a template glyph")
    }
    let recording = RecordingAttributes.ContentState(
      startedAt: Date().addingTimeInterval(-42), elapsed: 42, paused: false, interrupted: false)
    let paused = RecordingAttributes.ContentState(
      startedAt: Date(), elapsed: 65, paused: true, interrupted: false)
    let interrupted = RecordingAttributes.ContentState(
      startedAt: Date(), elapsed: 65, paused: false, interrupted: true)
    for scheme in [ColorScheme.light, .dark] {
      let mode = scheme == .dark ? "dark" : "light"
      save(lockCard(recording), scheme, "recording-lockscreen-\(mode)", to: out)
      save(lockCard(paused), scheme, "recording-lockscreen-paused-\(mode)", to: out)
      save(lockCard(interrupted), scheme, "recording-lockscreen-interrupted-\(mode)", to: out)
    }
    save(compactIsland(recording), .dark, "recording-island-compact", to: out)
    save(compactIsland(paused), .dark, "recording-island-compact-paused", to: out)
    save(minimalIsland(recording), .dark, "recording-island-minimal", to: out)
    save(expandedIsland(recording), .dark, "recording-island-expanded", to: out)
    save(expandedIsland(paused), .dark, "recording-island-expanded-paused", to: out)

    guard failures.isEmpty else {
      failures.forEach { print("FAIL: \($0)") }
      exit(1)
    }
    print("Rendered every widget to \(out.path)")
  }

  @MainActor private static var failures: [String] = []

  @MainActor private static func check(_ condition: Bool, _ failure: String) {
    if !condition { failures.append(failure) }
  }

  /// The widgets draw with the system face, so the extension bundles none.
  @MainActor private static func checkFonts(listedIn info: URL) {
    let listed = (NSDictionary(contentsOf: info)?["UIAppFonts"] as? [String]) ?? []
    check(listed.isEmpty, "UIAppFonts lists \(listed); the widgets use the system face")
  }

  @MainActor private static func save(
    _ content: some View, _ scheme: ColorScheme, _ name: String, to out: URL
  ) {
    let renderer = ImageRenderer(content: content.environment(\.colorScheme, scheme))
    renderer.scale = 2
    guard let png = renderer.uiImage?.pngData() else {
      check(false, "\(name) didn't render")
      return
    }
    do {
      try png.write(to: out.appendingPathComponent("\(name).png"))
    } catch {
      check(false, "\(name): \(error.localizedDescription)")
    }
  }

  private static func small(_ action: QuickAction) -> some View {
    onHomeScreen(QuickActionSmall(action: action), width: 170, margins: 16)
  }

  private static var medium: some View {
    onHomeScreen(QuickActionsView(), width: 364, margins: 0)
  }

  private static func onHomeScreen(_ widget: some View, width: CGFloat, margins: CGFloat)
    -> some View
  {
    widget
      .padding(margins)
      .frame(width: width, height: 170)
      .background(widgetBackground)
      .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
  }

  private static func circular(_ action: QuickAction) -> some View {
    QuickActionCircular(action: action).frame(width: 76, height: 76)
  }

  private static func rectangular(_ action: QuickAction) -> some View {
    QuickActionRectangular(action: action).frame(width: 172, height: 76)
  }

  private static func onWallpaper(_ widget: some View) -> some View {
    widget.foregroundStyle(.white).background(lockScreenWallpaper)
  }

  /// The boards' own layout: the three square widgets, Write, Dictate and
  /// Capture, over the medium one, where each caption leaves room above.
  private static func homeBoard(_ scheme: ColorScheme) -> some View {
    ZStack(alignment: .topLeading) {
      scheme == .dark ? rgb(0x0F0E0C) : rgb(0xD8D2C4)
      HStack(spacing: 22) {
        ForEach(QuickAction.allCases, id: \.self) { small($0) }
      }
      .offset(x: 32, y: 56)
      medium.offset(x: 32, y: 278)
    }
    .frame(width: 618, height: 480)
  }

  private static var lockBoard: some View {
    ZStack(alignment: .topLeading) {
      lockScreenWallpaper
      HStack(spacing: 18) {
        ForEach(QuickAction.allCases, id: \.self) { circular($0) }
        rectangular(.write)
      }
      .foregroundStyle(.white)
      .offset(x: 32, y: 72)
    }
    .frame(width: 540, height: 180)
  }

  private static let lockScreenWallpaper = rgb(0x3A3F36)

  /// The Lock Screen's Live Activity: as wide as it is on an iPhone 17, in
  /// the background the activity asks for, with the system's corners.
  private static func lockCard(_ state: RecordingAttributes.ContentState) -> some View {
    onWallpaper(
      RecordingCard(state: state)
        .frame(width: 361)
        .background(widgetBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(16))
  }

  /// The island is black on any wallpaper; drawn on the board's dark ground.
  private static func onIslandGround(_ island: some View) -> some View {
    island.padding(16).background(rgb(0x2A2620))
  }

  private static func compactIsland(_ state: RecordingAttributes.ContentState) -> some View {
    onIslandGround(
      HStack {
        RecordingMic(state: state, size: 18)
        Spacer()
        RecordingIslandTime(state: state, size: 15).frame(width: 44, alignment: .trailing)
      }
      .padding(.horizontal, 14)
      .frame(width: 250, height: 37)
      .background(Capsule().fill(.black)))
  }

  private static func minimalIsland(_ state: RecordingAttributes.ContentState) -> some View {
    onIslandGround(
      RecordingMic(state: state, size: 18)
        .frame(width: 37, height: 37)
        .background(Circle().fill(.black)))
  }

  private static func expandedIsland(_ state: RecordingAttributes.ContentState) -> some View {
    onIslandGround(
      VStack(spacing: 14) {
        HStack {
          RecordingIslandStatus(state: state)
          Spacer()
          RecordingIslandTime(state: state, size: 28)
        }
        RecordingIslandFooter(state: state)
      }
      .padding(EdgeInsets(top: 18, leading: 16, bottom: 18, trailing: 22))
      .frame(width: 371)
      .background(RoundedRectangle(cornerRadius: 44, style: .continuous).fill(.black)))
  }

  private static func rgb(_ hex: UInt32) -> Color {
    Color(
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255)
  }
}
